#include "recorder_windows_plugin.h"

#include <flutter/event_stream_handler_functions.h>
#include <flutter/standard_method_codec.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/base.h>

#include <cstdlib>
#include <sstream>
#include <utility>
#include <variant>

#include "permissions.h"

namespace relay {

namespace {

constexpr char kRecorderChannel[] = "relay/recorder";
constexpr char kRecorderEventsChannel[] = "relay/recorder/events";
constexpr char kOverlayChannel[] = "relay/overlay";
constexpr char kOverlayEventsChannel[] = "relay/overlay/events";

// Windows 10, version 2004 (build 19041): the first build where
// SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE) keeps a window out of a
// capture instead of blacking it out. Below it the control strip cannot be kept
// out of a display recording, which is a hard product invariant (spec 6), so
// recording is reported as unsupported rather than silently wrong.
// See capture_engine.h for the full API-floor derivation; spec 30.9 is open.
constexpr DWORD kMinimumBuild = 19041;

const flutter::EncodableValue* Find(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(std::string(key)));
  return it == map.end() ? nullptr : &it->second;
}

bool BoolAt(const flutter::EncodableMap& map, const char* key, bool fallback) {
  const flutter::EncodableValue* value = Find(map, key);
  if (value == nullptr) {
    return fallback;
  }
  const auto* flag = std::get_if<bool>(value);
  return flag == nullptr ? fallback : *flag;
}

std::string StringAt(const flutter::EncodableMap& map, const char* key) {
  const flutter::EncodableValue* value = Find(map, key);
  if (value == nullptr) {
    return std::string();
  }
  const auto* text = std::get_if<std::string>(value);
  return text == nullptr ? std::string() : *text;
}

int64_t IntAt(const flutter::EncodableMap& map, const char* key, int64_t fallback) {
  const flutter::EncodableValue* value = Find(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* small = std::get_if<int32_t>(value)) {
    return *small;
  }
  if (const auto* big = std::get_if<int64_t>(value)) {
    return *big;
  }
  if (const auto* real = std::get_if<double>(value)) {
    return static_cast<int64_t>(*real);
  }
  return fallback;
}

double DoubleAt(const flutter::EncodableMap& map, const char* key, double fallback) {
  const flutter::EncodableValue* value = Find(map, key);
  if (value == nullptr) {
    return fallback;
  }
  if (const auto* real = std::get_if<double>(value)) {
    return *real;
  }
  if (const auto* small = std::get_if<int32_t>(value)) {
    return static_cast<double>(*small);
  }
  if (const auto* big = std::get_if<int64_t>(value)) {
    return static_cast<double>(*big);
  }
  return fallback;
}

const flutter::EncodableMap* MapAt(const flutter::EncodableMap& map, const char* key) {
  const flutter::EncodableValue* value = Find(map, key);
  return value == nullptr ? nullptr : std::get_if<flutter::EncodableMap>(value);
}

// Device presence, not consent: the capabilities map says what this machine
// can do and the permission report says whether the user allowed it. Both
// probes only enumerate — they never open a device — so neither raises a
// privacy prompt. Both need an initialized apartment, so they run on the
// serial worker with the rest of the COM work.
bool HasCameraDevice() {
  if (FAILED(::MFStartup(MF_VERSION, MFSTARTUP_LITE))) {
    return false;
  }
  bool present = false;
  winrt::com_ptr<IMFAttributes> attributes;
  if (SUCCEEDED(::MFCreateAttributes(attributes.put(), 1))) {
    attributes->SetGUID(MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                        MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID);
    IMFActivate** devices = nullptr;
    UINT32 count = 0;
    if (SUCCEEDED(::MFEnumDeviceSources(attributes.get(), &devices, &count))) {
      present = count > 0;
      if (devices != nullptr) {
        for (UINT32 i = 0; i < count; ++i) {
          devices[i]->Release();
        }
        ::CoTaskMemFree(devices);
      }
    }
  }
  ::MFShutdown();
  return present;
}

bool HasMicrophoneDevice() {
  winrt::com_ptr<IMMDeviceEnumerator> enumerator;
  if (FAILED(::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                CLSCTX_INPROC_SERVER, __uuidof(IMMDeviceEnumerator),
                                enumerator.put_void()))) {
    return false;
  }
  winrt::com_ptr<IMMDevice> device;
  return SUCCEEDED(
      enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, device.put()));
}

// The states in which a recording exists that a second `prepare` must not
// silently destroy.
bool IsSessionLive(SessionState state) {
  switch (state) {
    case SessionState::kPreparing:
    case SessionState::kRecording:
    case SessionState::kPaused:
    case SessionState::kStopping:
    case SessionState::kFinalizing:
      return true;
    case SessionState::kIdle:
    case SessionState::kPrepared:
    case SessionState::kFinalized:
    case SessionState::kFailed:
      break;
  }
  return false;
}

DWORD WindowsBuildNumber() {
  HKEY key = nullptr;
  DWORD build = 0;
  if (::RegOpenKeyExW(HKEY_LOCAL_MACHINE,
                      L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", 0,
                      KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) {
    return build;
  }
  wchar_t buffer[32]{};
  DWORD size = sizeof(buffer);
  DWORD type = 0;
  if (::RegQueryValueExW(key, L"CurrentBuildNumber", nullptr, &type,
                         reinterpret_cast<LPBYTE>(buffer), &size) == ERROR_SUCCESS &&
      type == REG_SZ) {
    build = static_cast<DWORD>(::_wtoi(buffer));
  }
  ::RegCloseKey(key);
  return build;
}

std::string WindowsVersionString() {
  HKEY key = nullptr;
  if (::RegOpenKeyExW(HKEY_LOCAL_MACHINE,
                      L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", 0,
                      KEY_QUERY_VALUE, &key) != ERROR_SUCCESS) {
    return std::string();
  }
  const auto read_dword = [&key](const wchar_t* name) -> DWORD {
    DWORD value = 0;
    DWORD size = sizeof(value);
    DWORD type = 0;
    if (::RegQueryValueExW(key, name, nullptr, &type, reinterpret_cast<LPBYTE>(&value),
                           &size) == ERROR_SUCCESS &&
        type == REG_DWORD) {
      return value;
    }
    return 0;
  };
  const DWORD major = read_dword(L"CurrentMajorVersionNumber");
  const DWORD minor = read_dword(L"CurrentMinorVersionNumber");
  ::RegCloseKey(key);
  std::ostringstream stream;
  stream << major << "." << minor << "." << WindowsBuildNumber();
  return stream.str();
}

flutter::EncodableValue SourceToValue(const CaptureSourceInfo& source) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("id")] = flutter::EncodableValue(source.id);
  map[flutter::EncodableValue("type")] = flutter::EncodableValue(
      source.type == CaptureSourceType::kDisplay ? "display" : "window");
  map[flutter::EncodableValue("title")] = flutter::EncodableValue(source.title);
  map[flutter::EncodableValue("subtitle")] = flutter::EncodableValue(source.subtitle);
  map[flutter::EncodableValue("pixelWidth")] =
      flutter::EncodableValue(static_cast<int32_t>(source.pixel_width));
  map[flutter::EncodableValue("pixelHeight")] =
      flutter::EncodableValue(static_cast<int32_t>(source.pixel_height));
  map[flutter::EncodableValue("isCurrentDisplay")] =
      flutter::EncodableValue(source.is_current_display);
  if (!source.thumbnail_png.empty()) {
    map[flutter::EncodableValue("thumbnail")] =
        flutter::EncodableValue(source.thumbnail_png);
  }
  return flutter::EncodableValue(std::move(map));
}

flutter::EncodableValue DeviceToValue(const MediaDeviceInfo& device) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("id")] = flutter::EncodableValue(device.id);
  map[flutter::EncodableValue("kind")] =
      flutter::EncodableValue(MediaDeviceKindName(device.kind));
  map[flutter::EncodableValue("label")] = flutter::EncodableValue(device.label);
  map[flutter::EncodableValue("isSystemDefault")] =
      flutter::EncodableValue(device.is_system_default);
  map[flutter::EncodableValue("isAvailable")] =
      flutter::EncodableValue(device.is_available);
  return flutter::EncodableValue(std::move(map));
}

flutter::EncodableValue KindNamesToValue(const std::vector<std::string>& names) {
  flutter::EncodableList list;
  for (const std::string& name : names) {
    list.push_back(flutter::EncodableValue(name));
  }
  return flutter::EncodableValue(std::move(list));
}

flutter::EncodableValue ResultToValue(const RecordingResult& result) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("path")] = flutter::EncodableValue(Narrow(result.path));
  map[flutter::EncodableValue("recordingId")] =
      flutter::EncodableValue(result.recording_id);
  map[flutter::EncodableValue("sizeBytes")] =
      flutter::EncodableValue(static_cast<int64_t>(result.size_bytes));
  map[flutter::EncodableValue("durationMs")] = flutter::EncodableValue(result.duration_ms);
  map[flutter::EncodableValue("createdAtMs")] =
      flutter::EncodableValue(result.created_at_ms);
  map[flutter::EncodableValue("width")] =
      flutter::EncodableValue(static_cast<int32_t>(result.width));
  map[flutter::EncodableValue("height")] =
      flutter::EncodableValue(static_cast<int32_t>(result.height));
  map[flutter::EncodableValue("frameRate")] =
      flutter::EncodableValue(static_cast<int32_t>(result.frame_rate));
  map[flutter::EncodableValue("hasAudio")] = flutter::EncodableValue(result.has_audio);
  map[flutter::EncodableValue("hasCamera")] = flutter::EncodableValue(result.has_camera);
  return flutter::EncodableValue(std::move(map));
}

RecordingConfig ConfigFromMap(const flutter::EncodableMap& map) {
  RecordingConfig config;
  config.source_id = StringAt(map, "sourceId");
  config.source_type = StringAt(map, "sourceType") == "window" ? CaptureSourceType::kWindow
                                                               : CaptureSourceType::kDisplay;
  config.source_width = static_cast<uint32_t>(IntAt(map, "sourceWidth", 0));
  config.source_height = static_cast<uint32_t>(IntAt(map, "sourceHeight", 0));
  config.recording_id = StringAt(map, "recordingId");
  config.output_directory = Widen(StringAt(map, "outputDirectoryPath"));
  config.quality = StringAt(map, "quality");
  config.target_height = static_cast<uint32_t>(IntAt(map, "targetHeight", 720));
  config.frame_rate = static_cast<uint32_t>(IntAt(map, "frameRate", 30));
  config.camera_enabled = BoolAt(map, "cameraEnabled", false);
  config.microphone_enabled = BoolAt(map, "microphoneEnabled", true);
  config.system_audio_enabled = BoolAt(map, "systemAudioEnabled", true);
  config.show_cursor = BoolAt(map, "showCursor", true);
  // Absent or null decodes to empty, which is the platform's own default: an
  // unconfigured session opens exactly the devices it always opened (spec 33.2).
  config.camera_device_id = StringAt(map, "cameraDeviceId");
  config.microphone_device_id = StringAt(map, "microphoneDeviceId");
  config.system_audio_device_id = StringAt(map, "systemAudioDeviceId");

  if (const flutter::EncodableMap* camera = MapAt(map, "cameraOverlay")) {
    config.camera.width_ratio = DoubleAt(*camera, "widthRatio", 0.16);
    config.camera.aspect_ratio = DoubleAt(*camera, "aspectRatio", 16.0 / 9.0);
    config.camera.follows_source_aspect_ratio =
        BoolAt(*camera, "followsSourceAspectRatio", true);
    config.camera.corner_radius = DoubleAt(*camera, "cornerRadius", 0.0);
    config.camera.margin_ratio = DoubleAt(*camera, "marginRatio", 0.01);
    config.camera.corner = PipCornerFromName(StringAt(*camera, "corner"));
    config.camera.mirror_preview = BoolAt(*camera, "mirrorPreview", true);
    config.camera.mirror_output = BoolAt(*camera, "mirrorOutput", false);
  }
  if (const flutter::EncodableMap* composition = MapAt(map, "composition")) {
    config.composition.aspect_policy =
        StringAt(*composition, "aspectRatioPolicy") == "letterboxIntoReferenceCanvas"
            ? AspectRatioPolicy::kLetterboxIntoReferenceCanvas
            : AspectRatioPolicy::kContainWithinPreset;
    config.composition.geometry_policy = GeometryChangePolicy::kFixedCanvasLetterbox;
  }
  return config;
}

}  // namespace

SerialWorker::SerialWorker() : thread_(&SerialWorker::Run, this) {}

SerialWorker::~SerialWorker() {
  Shutdown();
}

bool SerialWorker::Post(std::function<void()> work) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_ || queue_.size() >= kCapacity) {
      return false;
    }
    queue_.push_back(std::move(work));
  }
  cv_.notify_one();
  return true;
}

void SerialWorker::Shutdown() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_) {
      return;
    }
    running_ = false;
  }
  cv_.notify_all();
  if (thread_.joinable()) {
    thread_.join();
  }
}

void SerialWorker::Run() {
  // COM is per-thread, and every task posted here does COM work: WIC thumbnail
  // encoding, WinRT capture-item activation, Media Foundation readers and
  // writers. Without this they fail with CO_E_NOTINITIALIZED. Multi-threaded,
  // like the capture, camera and audio threads.
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  for (;;) {
    std::function<void()> work;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      cv_.wait(lock, [this] { return !running_ || !queue_.empty(); });
      if (!running_ && queue_.empty()) {
        break;
      }
      work = std::move(queue_.front());
      queue_.pop_front();
    }
    if (work) {
      work();
    }
  }
  if (SUCCEEDED(com)) {
    ::CoUninitialize();
  }
}

void RecorderWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  registrar->AddPlugin(std::make_unique<RecorderWindowsPlugin>(registrar));
}

RecorderWindowsPlugin::RecorderWindowsPlugin(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {
  try {
    winrt::init_apartment(winrt::apartment_type::single_threaded);
  } catch (const winrt::hresult_error&) {
    // The Flutter runner already initialized COM on this thread.
  }

  recorder_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), kRecorderChannel,
      &flutter::StandardMethodCodec::GetInstance());
  recorder_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleRecorderMethod(call, std::move(result));
      });

  overlay_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), kOverlayChannel,
      &flutter::StandardMethodCodec::GetInstance());
  overlay_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleOverlayMethod(call, std::move(result));
      });

  recorder_events_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), kRecorderEventsChannel,
      &flutter::StandardMethodCodec::GetInstance());
  recorder_events_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            std::lock_guard<std::mutex> lock(sink_mutex_);
            recorder_sink_ = std::move(events);
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            std::lock_guard<std::mutex> lock(sink_mutex_);
            recorder_sink_ = nullptr;
            return nullptr;
          }));

  overlay_events_ = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(), kOverlayEventsChannel,
      &flutter::StandardMethodCodec::GetInstance());
  overlay_events_->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue*,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            std::lock_guard<std::mutex> lock(sink_mutex_);
            overlay_sink_ = std::move(events);
            return nullptr;
          },
          [this](const flutter::EncodableValue*)
              -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {
            std::lock_guard<std::mutex> lock(sink_mutex_);
            overlay_sink_ = nullptr;
            return nullptr;
          }));

  overlays_.SetMainWindow(MainWindow());
  overlays_.SetCommandHandler(
      [this](const std::string& command) { EmitOverlayCommand(command); });

  // Configured once, before anything can start metering. The meter is not
  // running yet: nothing streams until Dart asks for a level (spec 33.2).
  meter_.Configure(&microphone_level_,
                   [this](MediaDeviceKind kind, const InputLevelSample& level) {
                     EmitInputLevel(kind, level);
                   });
}

RecorderWindowsPlugin::~RecorderWindowsPlugin() {
  // The worker first: a queued getInputDevices starts the endpoint watcher, and
  // stopping the watcher ahead of the queue that arms it would leave it
  // registered with a callback into an object that no longer exists.
  worker_.Shutdown();
  // Both hold a handler into this object — the meter on its own thread, the
  // watcher on one of its own — and both drop it before returning, so neither
  // can call back into anything torn down below.
  meter_.StopAll();
  device_watcher_.Stop();
  if (session_) {
    session_->Abort();
    session_.reset();
  }
  overlays_.DisposeAll();
  dispatcher_.Shutdown();
}

void RecorderWindowsPlugin::AlignPreviewToCamera(OverlayPlacement* placement) const {
  if (placement == nullptr || !placement->absolute) {
    return;
  }
  // Only the display-mode preview is the picture-in-picture; the window-mode
  // preview is a separate captioned object and keeps its own box.
  if (last_config_.source_type != CaptureSourceType::kDisplay ||
      !last_config_.camera.follows_source_aspect_ratio || !session_) {
    return;
  }
  const double aspect = session_->camera_aspect_ratio();
  if (aspect <= 0 || placement->width <= 0 || placement->height <= 0) {
    return;
  }
  const double corrected = placement->width / aspect;
  const bool pins_top = last_config_.camera.corner == PipCorner::kTopLeft ||
                        last_config_.camera.corner == PipCorner::kTopRight;
  if (!pins_top) {
    placement->y += placement->height - corrected;
  }
  placement->height = corrected;
}

HWND RecorderWindowsPlugin::MainWindow() const {
  if (registrar_ == nullptr || registrar_->GetView() == nullptr) {
    return nullptr;
  }
  const HWND view = registrar_->GetView()->GetNativeWindow();
  return view == nullptr ? nullptr : ::GetAncestor(view, GA_ROOT);
}

void RecorderWindowsPlugin::RunOnPlatformThread(std::function<void()> work) {
  dispatcher_.Post(std::move(work));
}

void RecorderWindowsPlugin::ReplySuccess(const MethodResultPtr& result,
                                         flutter::EncodableValue value) {
  RunOnPlatformThread([result, value = std::move(value)]() { result->Success(value); });
}

void RecorderWindowsPlugin::ReplyError(const MethodResultPtr& result,
                                       const RecorderError& error) {
  RunOnPlatformThread([result, error]() {
    result->Error(ErrorCodeName(error.code), error.message,
                  error.details.empty() ? flutter::EncodableValue()
                                        : flutter::EncodableValue(error.details));
  });
}

void RecorderWindowsPlugin::EmitRecorderEvent(flutter::EncodableMap event) {
  RunOnPlatformThread([this, event = std::move(event)]() {
    std::lock_guard<std::mutex> lock(sink_mutex_);
    if (recorder_sink_) {
      recorder_sink_->Success(flutter::EncodableValue(event));
    }
  });
}

void RecorderWindowsPlugin::EmitOverlayCommand(const std::string& command) {
  RunOnPlatformThread([this, command]() {
    std::lock_guard<std::mutex> lock(sink_mutex_);
    if (overlay_sink_) {
      overlay_sink_->Success(flutter::EncodableValue(command));
    }
  });
}

void RecorderWindowsPlugin::EmitInputLevel(MediaDeviceKind kind,
                                           const InputLevelSample& level) {
  flutter::EncodableMap event;
  event[flutter::EncodableValue("type")] = flutter::EncodableValue("inputLevel");
  event[flutter::EncodableValue("kind")] =
      flutter::EncodableValue(MediaDeviceKindName(kind));
  // Linear amplitude in [0, 1] — never decibels, and never a buffer: raw media
  // stays native and only the measurement crosses the channel (spec 3, 33.2).
  event[flutter::EncodableValue("peak")] = flutter::EncodableValue(level.peak);
  event[flutter::EncodableValue("rms")] = flutter::EncodableValue(level.rms);
  // Not EmitRecorderEvent: a level raised on the meter thread a moment before
  // the stop that answers inline on this one would otherwise still reach the
  // sink after that reply. Nothing is emitted when nothing is metering
  // (spec 33.2).
  RunOnPlatformThread([this, kind, event = std::move(event)]() {
    if (!meter_.IsMetering(kind)) {
      return;
    }
    std::lock_guard<std::mutex> lock(sink_mutex_);
    if (recorder_sink_) {
      recorder_sink_->Success(flutter::EncodableValue(event));
    }
  });
}

void RecorderWindowsPlugin::EmitDevicesChanged() {
  flutter::EncodableMap event;
  event[flutter::EncodableValue("type")] = flutter::EncodableValue("devicesChanged");
  EmitRecorderEvent(std::move(event));
}

void RecorderWindowsPlugin::WireSessionEvents() {
  SessionEvents events;
  events.on_state = [this](SessionState state) {
    flutter::EncodableMap event;
    event[flutter::EncodableValue("type")] = flutter::EncodableValue("state");
    event[flutter::EncodableValue("state")] =
        flutter::EncodableValue(SessionStateName(state));
    EmitRecorderEvent(std::move(event));
  };
  events.on_tick = [this](int64_t elapsed_ms) {
    flutter::EncodableMap event;
    event[flutter::EncodableValue("type")] = flutter::EncodableValue("tick");
    event[flutter::EncodableValue("elapsedMs")] = flutter::EncodableValue(elapsed_ms);
    EmitRecorderEvent(std::move(event));
  };
  events.on_stats = [this](const SessionStats& stats) {
    flutter::EncodableMap event;
    event[flutter::EncodableValue("type")] = flutter::EncodableValue("stats");
    event[flutter::EncodableValue("capturedFrames")] =
        flutter::EncodableValue(static_cast<int64_t>(stats.captured_frames));
    event[flutter::EncodableValue("encodedFrames")] =
        flutter::EncodableValue(static_cast<int64_t>(stats.encoded_frames));
    event[flutter::EncodableValue("droppedFrames")] =
        flutter::EncodableValue(static_cast<int64_t>(stats.dropped_frames));
    event[flutter::EncodableValue("audioDiscontinuities")] =
        flutter::EncodableValue(static_cast<int64_t>(stats.audio_discontinuities));
    event[flutter::EncodableValue("avDriftMs")] =
        flutter::EncodableValue(stats.av_drift_ms);
    event[flutter::EncodableValue("encoderName")] =
        flutter::EncodableValue(stats.encoder_name);
    event[flutter::EncodableValue("hardwareEncoding")] =
        flutter::EncodableValue(stats.hardware_encoding);
    EmitRecorderEvent(std::move(event));
  };
  events.on_inputs = [this](bool microphone, bool camera, bool system_audio) {
    flutter::EncodableMap event;
    event[flutter::EncodableValue("type")] = flutter::EncodableValue("inputChanged");
    event[flutter::EncodableValue("microphoneEnabled")] =
        flutter::EncodableValue(microphone);
    event[flutter::EncodableValue("cameraEnabled")] = flutter::EncodableValue(camera);
    event[flutter::EncodableValue("systemAudioEnabled")] =
        flutter::EncodableValue(system_audio);
    EmitRecorderEvent(std::move(event));
  };
  events.on_error = [this](const RecorderError& error) {
    flutter::EncodableMap event;
    event[flutter::EncodableValue("type")] = flutter::EncodableValue("error");
    event[flutter::EncodableValue("code")] =
        flutter::EncodableValue(ErrorCodeName(error.code));
    event[flutter::EncodableValue("message")] = flutter::EncodableValue(error.message);
    if (!error.details.empty()) {
      event[flutter::EncodableValue("details")] = flutter::EncodableValue(error.details);
    }
    event[flutter::EncodableValue("fatal")] = flutter::EncodableValue(error.fatal);
    EmitRecorderEvent(std::move(event));
  };
  events.on_camera_preview = [this](const uint8_t* pixels, uint32_t width,
                                    uint32_t height, uint32_t stride) {
    // Raw frames never cross a channel: the preview reaches Dart as a texture
    // registered on the preview engine (media-pipeline "Principle").
    overlays_.PushCameraPreviewFrame(pixels, width, height, stride);
  };
  session_ = std::make_shared<RecordingSession>(std::move(events));
}

// Runs on the serial worker: the camera and microphone probes are COM calls.
flutter::EncodableMap RecorderWindowsPlugin::Capabilities() const {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("qualities")] = flutter::EncodableValue(
      flutter::EncodableList{flutter::EncodableValue("hd720"),
                             flutter::EncodableValue("fullHd1080")});
  map[flutter::EncodableValue("frameRates")] = flutter::EncodableValue(
      flutter::EncodableList{flutter::EncodableValue(30), flutter::EncodableValue(60)});
  map[flutter::EncodableValue("sourceTypes")] = flutter::EncodableValue(
      flutter::EncodableList{flutter::EncodableValue("display"),
                             flutter::EncodableValue("window")});
  // What the machine has, not what the platform implements: the UI derives the
  // camera and microphone toggles from these, and a toggle offered on a
  // machine with no such device only fails once the recording is under way
  // (spec 20).
  map[flutter::EncodableValue("supportsCamera")] =
      flutter::EncodableValue(HasCameraDevice());
  map[flutter::EncodableValue("supportsMicrophone")] =
      flutter::EncodableValue(HasMicrophoneDevice());
  map[flutter::EncodableValue("supportsSystemAudio")] = flutter::EncodableValue(true);
  map[flutter::EncodableValue("supportsPause")] = flutter::EncodableValue(true);
  // Which inputs offer a *choice* of device, and which can report a level. All
  // three are selectable here: WASAPI loopback is per render endpoint, so
  // "which output am I recording?" has a real answer on Windows that it does
  // not have on macOS (spec 33.2).
  map[flutter::EncodableValue("selectableDeviceKinds")] =
      KindNamesToValue(SelectableDeviceKindNames());
  map[flutter::EncodableValue("meterableDeviceKinds")] =
      KindNamesToValue(MeterableDeviceKindNames());
  map[flutter::EncodableValue("supportsCursorCapture")] = flutter::EncodableValue(true);
  map[flutter::EncodableValue("supportsHardwareEncoding")] = flutter::EncodableValue(true);
  // Windows applies capture consent to the running process, so nothing has to
  // be reopened for a permission to take effect, and the launcher never changes
  // who the consent belongs to.
  map[flutter::EncodableValue("screenRecordingNeedsRelaunch")] = flutter::EncodableValue(false);
  map[flutter::EncodableValue("screenRecordingLaunchedByThisApp")] =
      flutter::EncodableValue(true);
  map[flutter::EncodableValue("platformName")] = flutter::EncodableValue("Windows");
  map[flutter::EncodableValue("platformVersion")] =
      flutter::EncodableValue(WindowsVersionString());

  std::string unsupported;
  const DWORD build = WindowsBuildNumber();
  if (build != 0 && build < kMinimumBuild) {
    unsupported =
        "Relay needs Windows 10 version 2004 or newer: older builds cannot keep "
        "the recorder overlay out of the recording.";
  } else {
    bool capture_supported = false;
    try {
      capture_supported =
          winrt::Windows::Graphics::Capture::GraphicsCaptureSession::IsSupported();
    } catch (const winrt::hresult_error&) {
      capture_supported = false;
    }
    if (!capture_supported) {
      unsupported = "Screen capture is not available on this system.";
    }
  }
  map[flutter::EncodableValue("unsupportedReason")] =
      unsupported.empty() ? flutter::EncodableValue()
                          : flutter::EncodableValue(unsupported);
  return map;
}

void RecorderWindowsPlugin::HandleRecorderMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const MethodResultPtr shared = std::move(result);
  const std::string& method = call.method_name();
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());

  const auto reject = [this, shared](RecorderErrorCode code, std::string message) {
    RecorderError error;
    error.code = code;
    error.message = std::move(message);
    ReplyError(shared, error);
  };
  const auto busy = [reject]() {
    reject(RecorderErrorCode::kUnknown,
           "The recorder is busy with an earlier request. Try again.");
  };

  if (disposed_ && method != "dispose") {
    reject(RecorderErrorCode::kInvalidState, "The recorder has been disposed.");
    return;
  }

  if (method == "getCapabilities") {
    // Device probing is COM work: it belongs on the worker, which has an
    // apartment and is not the thread drawing the UI.
    if (!worker_.Post([this, shared]() {
          ReplySuccess(shared, flutter::EncodableValue(Capabilities()));
        })) {
      busy();
    }
    return;
  }

  if (method == "getCurrentDisplay") {
    const DisplayInfo display = CaptureSourceEnumerator::CurrentDisplay(MainWindow());
    flutter::EncodableMap map;
    map[flutter::EncodableValue("id")] = flutter::EncodableValue(display.id);
    map[flutter::EncodableValue("logicalWidth")] =
        flutter::EncodableValue(display.logical_width);
    map[flutter::EncodableValue("logicalHeight")] =
        flutter::EncodableValue(display.logical_height);
    map[flutter::EncodableValue("pixelWidth")] =
        flutter::EncodableValue(static_cast<int32_t>(display.pixel_width));
    map[flutter::EncodableValue("pixelHeight")] =
        flutter::EncodableValue(static_cast<int32_t>(display.pixel_height));
    map[flutter::EncodableValue("scaleFactor")] =
        flutter::EncodableValue(display.scale_factor);
    shared->Success(flutter::EncodableValue(map));
    return;
  }

  if (method == "getAvailableSources") {
    const bool refresh =
        arguments == nullptr ? true : BoolAt(*arguments, "refreshThumbnails", true);
    const HWND main_window = MainWindow();
    if (!worker_.Post([this, shared, refresh, main_window]() {
          const std::vector<CaptureSourceInfo> sources =
              enumerator_.Enumerate(refresh, main_window);
          flutter::EncodableList list;
          for (const CaptureSourceInfo& source : sources) {
            list.push_back(SourceToValue(source));
          }
          ReplySuccess(shared, flutter::EncodableValue(std::move(list)));
        })) {
      busy();
    }
    return;
  }

  if (method == "getInputDevices") {
    MediaDeviceKind kind = MediaDeviceKind::kMicrophone;
    if (arguments == nullptr ||
        !MediaDeviceKindFromName(StringAt(*arguments, "kind"), &kind)) {
      reject(RecorderErrorCode::kUnknown, "An input device kind is required.");
      return;
    }
    // Enumerating audio endpoints and camera sources is COM work: it belongs on
    // the worker, which has an apartment. An empty list is a legitimate answer
    // — no camera is attached — and is not an error (spec 33.2).
    if (!worker_.Post([this, shared, kind]() {
          if (disposed_.load()) {
            // Queued before dispose and drained after it. Nothing may re-arm
            // the watcher, or open a device, past dispose — and a channel call
            // is still owed an answer.
            RecorderError error;
            error.code = RecorderErrorCode::kInvalidState;
            error.message = "The recorder has been disposed.";
            ReplyError(shared, error);
            return;
          }
          // Watching begins with the first enumeration: nothing watches a list
          // nobody has asked for.
          device_watcher_.Start([this]() {
            // The meter first: an endpoint change can have moved the default
            // out from under the tap, and a bar reading the microphone that
            // used to be the default is worse than one that skips a tick
            // (spec 33.2).
            meter_.NotifyDeviceListChanged();
            EmitDevicesChanged();
          });
          flutter::EncodableList list;
          for (const MediaDeviceInfo& device : EnumerateInputDevices(kind)) {
            list.push_back(DeviceToValue(device));
          }
          ReplySuccess(shared, flutter::EncodableValue(std::move(list)));
        })) {
      busy();
    }
    return;
  }

  if (method == "startInputMetering" || method == "stopInputMetering") {
    MediaDeviceKind kind = MediaDeviceKind::kMicrophone;
    if (arguments == nullptr ||
        !MediaDeviceKindFromName(StringAt(*arguments, "kind"), &kind)) {
      reject(RecorderErrorCode::kUnknown, "An input device kind is required.");
      return;
    }
    // Reference counted inside the meter, which also makes a start for a kind
    // that reports no level a silent no-op and a stop with nothing running a
    // no-op rather than an error. Both are cheap — no device is touched on this
    // thread, and neither waits for the meter's own — so they answer inline
    // (spec 33.2).
    if (method == "startInputMetering") {
      // The device the bar sits under. Absent or null is the platform default,
      // the same meaning a null id has on the recording configuration; a start
      // naming a different device re-points the tap rather than opening a
      // second one.
      meter_.Start(kind, arguments == nullptr ? std::string()
                                              : StringAt(*arguments, "deviceId"));
    } else {
      meter_.Stop(kind);
    }
    shared->Success();
    return;
  }

  if (method == "checkPermissions") {
    if (!worker_.Post([this, shared]() {
          flutter::EncodableMap report;
          report[flutter::EncodableValue("screenRecording")] = flutter::EncodableValue(
              PermissionStatusName(Permissions::Check(PermissionKind::kScreenRecording)));
          report[flutter::EncodableValue("microphone")] = flutter::EncodableValue(
              PermissionStatusName(Permissions::Check(PermissionKind::kMicrophone)));
          report[flutter::EncodableValue("camera")] = flutter::EncodableValue(
              PermissionStatusName(Permissions::Check(PermissionKind::kCamera)));
          ReplySuccess(shared, flutter::EncodableValue(std::move(report)));
        })) {
      busy();
    }
    return;
  }

  // Declared by the shared contract, unreachable here: this platform reports
  // `screenRecordingNeedsRelaunch` false and never blocks on a permission it
  // could only apply to a fresh process, so no screen offers either action.
  // Answered rather than left unimplemented — a contract method that reaches
  // the default branch would surface an untyped MissingPluginException.
  if (method == "relaunchApplication" || method == "quitApplication") {
    shared->Success();
    return;
  }

  if (method == "requestPermission" || method == "openPermissionSettings") {
    PermissionKind kind = PermissionKind::kScreenRecording;
    if (arguments == nullptr ||
        !PermissionKindFromName(StringAt(*arguments, "kind"), &kind)) {
      reject(RecorderErrorCode::kUnknown, "A permission kind is required.");
      return;
    }
    if (method == "openPermissionSettings") {
      Permissions::OpenSettings(kind);
      shared->Success();
      return;
    }
    if (!worker_.Post([this, shared, kind]() {
          ReplySuccess(shared, flutter::EncodableValue(
                                   PermissionStatusName(Permissions::Request(kind))));
        })) {
      busy();
    }
    return;
  }

  if (method == "prepare") {
    if (arguments == nullptr) {
      reject(RecorderErrorCode::kUnknown, "A recording configuration is required.");
      return;
    }
    const RecordingConfig config = ConfigFromMap(*arguments);
    if (config.recording_id.empty() || config.output_directory.empty()) {
      reject(RecorderErrorCode::kUnknown,
             "The recording configuration is incomplete.");
      return;
    }
    // A live recording is never replaced silently. The plugin builds a fresh
    // session per prepare, so RecordingSession's own guard would never see the
    // second call: it would abort the running session, orphan its `.part` and
    // answer success (contract: invalidState).
    if (session_ && IsSessionLive(session_->state())) {
      reject(RecorderErrorCode::kInvalidState, "A recording is already in progress.");
      return;
    }
    last_config_ = config;
    // Tearing the previous session down joins the capture, encode, timer,
    // camera and audio threads, so it runs on the worker — ahead of the
    // prepare it precedes, because the worker is serial — and not on the
    // thread drawing the UI.
    const std::shared_ptr<RecordingSession> previous = std::move(session_);
    WireSessionEvents();
    session_->SetMicrophoneLevelMeter(&microphone_level_);
    session_->SetExcludedWindows(overlays_.ExcludedWindows());
    const std::shared_ptr<RecordingSession> session = session_;
    if (!worker_.Post([this, shared, config, session, previous]() {
          if (previous) {
            previous->Abort();
          }
          RecorderError error;
          if (session->Prepare(config, &error)) {
            ReplySuccess(shared, flutter::EncodableValue());
          } else {
            ReplyError(shared, error);
          }
        })) {
      busy();
    }
    return;
  }

  if (method == "stop") {
    if (!session_) {
      reject(RecorderErrorCode::kInvalidState, "There is no recording to stop.");
      return;
    }
    const std::shared_ptr<RecordingSession> session = session_;
    if (!worker_.Post([this, shared, session]() {
          RecordingResult finished;
          RecorderError error;
          if (session->Stop(&finished, &error)) {
            ReplySuccess(shared, ResultToValue(finished));
          } else {
            ReplyError(shared, error);
          }
        })) {
      busy();
    }
    return;
  }

  if (method == "recoverArtifact") {
    const std::wstring path =
        arguments == nullptr ? std::wstring() : Widen(StringAt(*arguments, "path"));
    if (path.empty()) {
      reject(RecorderErrorCode::kUnknown, "An artifact path is required.");
      return;
    }
    if (!worker_.Post([this, shared, path]() {
          RecordingResult recovered;
          if (RecordingSession::RecoverArtifact(path, &recovered)) {
            ReplySuccess(shared, ResultToValue(recovered));
          } else {
            ReplySuccess(shared, flutter::EncodableValue());
          }
        })) {
      busy();
    }
    return;
  }

  // The remaining commands are cheap state transitions and answer inline.
  RecorderError error;
  if (method == "start") {
    if (!session_) {
      reject(RecorderErrorCode::kInvalidState, "Start was called before prepare.");
      return;
    }
    session_->SetExcludedWindows(overlays_.ExcludedWindows());
    if (!session_->Start(&error)) {
      ReplyError(shared, error);
      return;
    }
    shared->Success();
    return;
  }
  if (method == "pause" || method == "resume") {
    if (!session_) {
      reject(RecorderErrorCode::kInvalidState, "There is no recording to control.");
      return;
    }
    const bool ok =
        method == "pause" ? session_->Pause(&error) : session_->Resume(&error);
    if (!ok) {
      ReplyError(shared, error);
      return;
    }
    shared->Success();
    return;
  }
  if (method == "abort") {
    if (session_) {
      session_->Abort();
    }
    shared->Success();
    return;
  }
  if (method == "setMicrophoneEnabled" || method == "setCameraEnabled" ||
      method == "setSystemAudioEnabled") {
    if (!session_) {
      reject(RecorderErrorCode::kInvalidState, "There is no recording to change.");
      return;
    }
    const bool enabled = arguments != nullptr && BoolAt(*arguments, "enabled", false);
    bool ok = true;
    if (method == "setMicrophoneEnabled") {
      ok = session_->SetMicrophoneEnabled(enabled, &error);
    } else if (method == "setSystemAudioEnabled") {
      ok = session_->SetSystemAudioEnabled(enabled, &error);
    } else {
      ok = session_->SetCameraEnabled(enabled, &error);
      if (ok) {
        overlays_.UpdateCameraPreview(last_config_.camera.mirror_preview,
                                      last_config_.source_type ==
                                          CaptureSourceType::kDisplay,
                                      session_->camera_aspect_ratio());
      }
    }
    if (!ok) {
      ReplyError(shared, error);
      return;
    }
    shared->Success();
    return;
  }
  if (method == "releaseSession") {
    // The finished session, dropped when the user leaves the post-recording
    // screen.
    if (!session_) {
      shared->Success();
      return;
    }
    // A live or still-finalizing session is never released from under the
    // worker that owns its teardown: `Stop()` holds `teardown_mutex_` for its
    // own thread joins, and `writer_.Abort()` outside that mutex can win
    // `MediaWriter::mutex_` ahead of `Finalize()` and strand a finished
    // recording as a `.part`.
    if (IsSessionLive(session_->state())) {
      reject(RecorderErrorCode::kInvalidState,
             "A recording is still in progress.");
      return;
    }
    // On the worker, for the same reason `prepare` tears the previous session
    // down there: `Abort()` joins the capture, encode and timer threads, and
    // the platform thread is the one drawing the UI.
    const std::shared_ptr<RecordingSession> previous = std::move(session_);
    if (!worker_.Post([this, shared, previous]() {
          previous->Abort();
          ReplySuccess(shared, flutter::EncodableValue());
        })) {
      busy();
    }
    return;
  }
  if (method == "dispose") {
    disposed_ = true;
    // Nothing may keep a device open, or keep emitting, past dispose.
    meter_.StopAll();
    device_watcher_.Stop();
    if (session_) {
      session_->Abort();
      session_.reset();
    }
    overlays_.DisposeAll();
    shared->Success();
    return;
  }

  shared->NotImplemented();
}

void RecorderWindowsPlugin::HandleOverlayMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());

  const auto fail = [&result](const std::string& message) {
    result->Error(ErrorCodeName(RecorderErrorCode::kUnknown), message);
  };

  if (method == "showControlStrip" || method == "showCameraPreview") {
    if (arguments == nullptr) {
      fail("A placement is required.");
      return;
    }
    OverlayPlacement placement = OverlayPlacement::FromMap(*arguments);
    if (method == "showCameraPreview") {
      AlignPreviewToCamera(&placement);
    }
    std::string error;
    const bool ok = method == "showControlStrip"
                        ? overlays_.ShowControlStrip(placement, &error)
                        : overlays_.ShowCameraPreview(placement, &error);
    if (!ok) {
      fail(error);
      return;
    }
    // A newly shown overlay must reach the exclusion set immediately, even
    // mid-session (spec 6).
    if (session_) {
      session_->SetExcludedWindows(overlays_.ExcludedWindows());
    }
    if (method == "showCameraPreview") {
      // The presentation mode is stated by Dart rather than inferred from the
      // placement: both modes send an absolute frame (spec 6).
      overlays_.UpdateCameraPreview(
          last_config_.camera.mirror_preview,
          BoolAt(*arguments, "matchesCompositedPip", false),
          session_ ? session_->camera_aspect_ratio() : 16.0 / 9.0);
    }
    result->Success();
    return;
  }
  if (method == "controlStripPosition") {
    std::string display_id;
    double x = 0;
    double y = 0;
    if (!overlays_.ControlStripPosition(&display_id, &x, &y)) {
      // Null, never a position of 0, 0: failing to read where the strip is is
      // not the user having moved it back, and Dart keeps what it had stored.
      result->Success();
      return;
    }
    flutter::EncodableMap position;
    position[flutter::EncodableValue("displayId")] =
        flutter::EncodableValue(display_id);
    position[flutter::EncodableValue("x")] = flutter::EncodableValue(x);
    position[flutter::EncodableValue("y")] = flutter::EncodableValue(y);
    result->Success(flutter::EncodableValue(std::move(position)));
    return;
  }
  if (method == "hideControlStrip") {
    overlays_.HideControlStrip();
    result->Success();
    return;
  }
  if (method == "hideCameraPreview") {
    overlays_.HideCameraPreview();
    result->Success();
    return;
  }
  if (method == "updateControlStrip") {
    overlays_.UpdateControlStrip(arguments == nullptr ? flutter::EncodableMap()
                                                      : *arguments);
    result->Success();
    return;
  }
  if (method == "setMainWindowVisible") {
    overlays_.SetMainWindowVisible(arguments != nullptr &&
                                   BoolAt(*arguments, "visible", true));
    result->Success();
    return;
  }
  if (method == "excludedWindowIds") {
    flutter::EncodableList ids;
    for (const std::string& id : overlays_.ExcludedWindowIds()) {
      ids.push_back(flutter::EncodableValue(id));
    }
    result->Success(flutter::EncodableValue(std::move(ids)));
    return;
  }
  result->NotImplemented();
}

}  // namespace relay
