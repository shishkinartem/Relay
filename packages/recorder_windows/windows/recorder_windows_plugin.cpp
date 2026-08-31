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

// The cameraOverlay map (spec 33.5), read the same way wherever it arrives: on
// `prepare` for the session that is about to start, and on `setCameraOverlay`
// for the one that is already running.
//
// `positionX` and `positionY` are always present and either both null — the
// tile is on its corner — or both numbers. Half a position is no position: a
// tile placed on one axis and cornered on the other is a shape nobody asked
// for, and Dart drops the same shape on the way in.
CameraOverlayConfig CameraOverlayFromMap(const flutter::EncodableMap& map) {
  CameraOverlayConfig camera;
  camera.preset = CameraPipPresetFromName(StringAt(map, "preset"));
  camera.width_ratio = DoubleAt(map, "widthRatio", kCameraPresetWidthCap);
  camera.aspect_ratio = DoubleAt(map, "aspectRatio", 16.0 / 9.0);
  camera.follows_source_aspect_ratio =
      BoolAt(map, "followsSourceAspectRatio", true);
  camera.corner_radius_ratio = DoubleAt(map, "cornerRadiusRatio", 0.0);
  camera.margin_ratio = DoubleAt(map, "marginRatio", 0.01);
  camera.corner = PipCornerFromName(StringAt(map, "corner"));
  camera.fit = CameraPipFitFromName(StringAt(map, "fit"));
  const flutter::EncodableValue* x = Find(map, "positionX");
  const flutter::EncodableValue* y = Find(map, "positionY");
  // A null crosses the channel as std::monostate, which is how a key that is
  // always present says it holds nothing.
  const bool has_x = x != nullptr && std::get_if<std::monostate>(x) == nullptr;
  const bool has_y = y != nullptr && std::get_if<std::monostate>(y) == nullptr;
  camera.has_position = has_x && has_y;
  if (camera.has_position) {
    camera.position_x = DoubleAt(map, "positionX", 0);
    camera.position_y = DoubleAt(map, "positionY", 0);
  }
  camera.mirror_preview = BoolAt(map, "mirrorPreview", true);
  camera.mirror_output = BoolAt(map, "mirrorOutput", false);
  return camera;
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
    config.camera = CameraOverlayFromMap(*camera);
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
  // The anchor an overlay command carries is the overlay layer's own business —
  // it decides where the menu opens — so nothing but the bare name crosses the
  // event channel (spec 33.4).
  overlays_.SetCommandHandler(
      [this](const std::string& command, std::optional<double>) {
        EmitOverlayCommand(command);
      });
  overlays_.SetMenuSelectionHandler(
      [this](const flutter::EncodableMap& choice) { EmitMenuChoice(choice); });
  overlays_.SetMenuDismissHandler([this](bool host_initiated) {
    // A menu the host closed behind the application's back has to be reported:
    // the application is what draws the chevron, and a window it still believes
    // is open makes the next press on that chevron the toggle that closes it
    // (spec 33.4). A close the application asked for, or one that follows a
    // choice already on its way to it, tells it nothing it does not know.
    //
    // Taken rather than read, so a display change every overlay window sees is
    // still one dismissal.
    const std::optional<MediaDeviceKind> kind =
        std::exchange(open_menu_kind_, std::nullopt);
    if (host_initiated && kind.has_value()) {
      EmitMenuDismissal(*kind);
    }
    // Deferred to a later turn of the platform thread's loop, always: the
    // request comes from inside the menu engine's own channel callback, or from
    // a window procedure, and closing the window there would free the stack
    // that is running (overlay_windows.h).
    RunOnPlatformThread([this]() { overlays_.HideInputMenu(); });
  });
  overlays_.SetCameraMovedHandler([this](double x, double y) {
    CameraOverlayConfig moved = last_config_.camera;
    moved.has_position = true;
    moved.position_x = x;
    moved.position_y = y;
    // The window is already where the drag left it, and it was put there by the
    // same arithmetic; re-placing it would be a second move for nothing.
    ApplyCameraOverlay(moved, /*from_preview=*/true);
    // And the application is told, because the configuration it pushes on the
    // next preset change is built from the position *it* holds (spec 33.5).
    // This used to be pulled instead, at teardown, by `cameraPreviewPosition` —
    // which reports the window's rectangle whether the user dragged it there or
    // the corner rule put it there, so a session that never touched the tile
    // still stored a free position and the corner stopped being consulted.
    EmitCameraPreviewMoved(x, y);
  });

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

HMONITOR RecorderWindowsPlugin::RecordedDisplay() const {
  if (last_config_.source_type != CaptureSourceType::kDisplay) {
    return nullptr;
  }
  // The same reader getAvailableSources' ids go through, which answers null for
  // a handle that no longer names a live monitor.
  return ParseMonitorSourceId(last_config_.source_id);
}

void RecorderWindowsPlugin::AlignPreviewToCamera(OverlayPlacement* placement) const {
  if (placement == nullptr || !placement->absolute) {
    return;
  }
  // Only the display-mode preview is the picture-in-picture; the window-mode
  // preview is a separate captioned object and keeps its own box (design 1e).
  if (last_config_.source_type != CaptureSourceType::kDisplay || !session_) {
    return;
  }
  const uint32_t canvas_width = session_->canvas_width();
  const uint32_t canvas_height = session_->canvas_height();
  const PipDraw tile = session_->camera_pip_draw();
  if (canvas_width == 0 || canvas_height == 0 || tile.dest.width <= 0 ||
      tile.dest.height <= 0) {
    return;
  }
  // The display being *recorded*, which is the one the canvas covers — not
  // whichever display the main window happens to sit on. On a desktop whose
  // monitors have different resolutions the two disagree, and measuring the
  // tile against the wrong one placed and sized the preview at the wrong
  // scale. UpdatePreviewGeometry resolves the same display, from the same call,
  // and bails out the same way when it cannot be named: without a rectangle to
  // measure against the preview is not the tile, so it stays where it is.
  const HMONITOR monitor = RecordedDisplay();
  if (monitor == nullptr) {
    return;
  }
  const DisplayInfo display = CaptureSourceEnumerator::DescribeMonitor(monitor);
  if (display.logical_width <= 0 || display.logical_height <= 0) {
    return;
  }
  // The tile, in canvas pixels, expressed in the logical points an absolute
  // placement is resolved in. Not the aspect ratio alone: the width is capped
  // by the camera's own pixels and the height by the crop, and taking the
  // rectangle whole is what makes the window and the file the same object
  // (design 1p, spec 33.5).
  const double to_points_x = display.logical_width / static_cast<double>(canvas_width);
  const double to_points_y =
      display.logical_height / static_cast<double>(canvas_height);
  placement->x = tile.dest.x * to_points_x;
  placement->y = tile.dest.y * to_points_y;
  placement->width = tile.dest.width * to_points_x;
  placement->height = tile.dest.height * to_points_y;
}

void RecorderWindowsPlugin::UpdatePreviewGeometry() {
  CameraPreviewGeometry geometry;
  geometry.camera = last_config_.camera;
  geometry.is_tile = last_config_.source_type == CaptureSourceType::kDisplay;
  if (session_) {
    geometry.canvas_width = session_->canvas_width();
    geometry.canvas_height = session_->canvas_height();
    geometry.frame_width = session_->camera_frame_width();
    geometry.frame_height = session_->camera_frame_height();
  }
  // Where that canvas lands on screen: the display being recorded, not whichever
  // display the window has been dragged towards. A drag measured against any
  // other rectangle would let the tile leave the recording.
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  const HMONITOR monitor = RecordedDisplay();
  if (monitor != nullptr && ::GetMonitorInfoW(monitor, &info) != FALSE) {
    geometry.canvas_bounds = info.rcMonitor;
  } else {
    // The recorded display cannot be named any more. Without a rectangle to
    // measure against, the preview is not the tile: it stays where it is and
    // reports no position, which is the null cameraPreviewPosition answers with.
    geometry.is_tile = false;
  }
  if (geometry.canvas_width <= 0 || geometry.canvas_height <= 0) {
    geometry.is_tile = false;
  }
  // Kept as well as pushed: the state the preview is told to draw has to be
  // resolved from the same `is_tile` its frames are cropped by, or the shape
  // reported and the picture pushed disagree.
  preview_geometry_ = geometry;
  overlays_.SetCameraPreviewGeometry(geometry);
}

CameraPreviewDraw RecorderWindowsPlugin::PreviewDraw() const {
  return ResolveCameraPreviewDraw(
      preview_geometry_.camera, preview_geometry_.is_tile,
      session_ ? session_->camera_pip_draw() : PipDraw(),
      preview_geometry_.frame_width, preview_geometry_.frame_height);
}

void RecorderWindowsPlugin::RefreshCameraPreview(bool reposition) {
  UpdatePreviewGeometry();
  if (reposition) {
    // A preset, a swapped camera or a camera that has just reported its real
    // frame size all change the tile's size, so the window that stands for it
    // has to follow — re-clamped around where it already was (spec 33.7,
    // "Preset changed mid-drag"). Only a preview that is already on screen:
    // MoveCameraPreview answers false when there is none, and nothing here may
    // open one.
    OverlayPlacement placement;
    placement.absolute = true;
    AlignPreviewToCamera(&placement);
    if (placement.width > 0 && placement.height > 0) {
      overlays_.MoveCameraPreview(placement);
    }
  }
  overlays_.UpdateCameraPreview(
      last_config_.camera.mirror_preview,
      last_config_.source_type == CaptureSourceType::kDisplay, PreviewDraw());
}

void RecorderWindowsPlugin::ApplyCameraOverlay(const CameraOverlayConfig& camera,
                                               bool from_preview) {
  last_config_.camera = camera;
  if (session_) {
    // Between frames, for the next frame. The canvas is untouched, so the file
    // keeps one continuous video track (spec 11, 33.5).
    session_->SetCameraOverlay(camera);
  }
  // The window is already where a drag left it, and it was put there by the
  // same arithmetic; re-placing it would be a second move for nothing.
  RefreshCameraPreview(/*reposition=*/!from_preview);
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

void RecorderWindowsPlugin::EmitMenuChoice(flutter::EncodableMap choice) {
  // Forwarded as the menu engine sent it. A device row carries `deviceId` and
  // `off`, a shape preset carries `preset` and a placement row carries `corner`
  // — and which of them this is belongs to the application (spec 33.5). Unpacking them here would mean
  // teaching the host a field every time the camera sheet grows one; Dart
  // defaults every key it does not find.
  //
  // The one field the host owns is `dismissed`: a choice is never one, and
  // stating it keeps the two shapes this channel emits identical in outline.
  choice[flutter::EncodableValue("dismissed")] = flutter::EncodableValue(false);
  EmitOverlayMap(std::move(choice));
}

void RecorderWindowsPlugin::EmitMenuDismissal(MediaDeviceKind kind) {
  flutter::EncodableMap dismissal;
  dismissal[flutter::EncodableValue("kind")] =
      flutter::EncodableValue(std::string(MediaDeviceKindName(kind)));
  // No device, because nothing was chosen: this applies nothing and exists only
  // so the application stops believing the window is still open (spec 33.4).
  // Present and null rather than missing, on the same terms as a choice's:
  // Dart reads one shape.
  dismissal[flutter::EncodableValue("deviceId")] = flutter::EncodableValue();
  dismissal[flutter::EncodableValue("off")] = flutter::EncodableValue(false);
  dismissal[flutter::EncodableValue("dismissed")] = flutter::EncodableValue(true);
  EmitOverlayMap(std::move(dismissal));
}

void RecorderWindowsPlugin::EmitCameraPreviewMoved(double x, double y) {
  flutter::EncodableMap moved;
  // Named by `event` rather than by `kind`: an input-menu choice is the map
  // this channel already carries, and Dart decodes both by shape. A map with a
  // `kind` is a choice; this one is not, and must never grow one.
  moved[flutter::EncodableValue("event")] =
      flutter::EncodableValue(std::string("cameraPreviewMoved"));
  moved[flutter::EncodableValue("x")] = flutter::EncodableValue(x);
  moved[flutter::EncodableValue("y")] = flutter::EncodableValue(y);
  EmitOverlayMap(std::move(moved));
}

void RecorderWindowsPlugin::EmitOverlayMap(flutter::EncodableMap map) {
  RunOnPlatformThread([this, map = std::move(map)]() {
    std::lock_guard<std::mutex> lock(sink_mutex_);
    if (overlay_sink_) {
      // A map beside the bare command names this channel already emits. Dart
      // decodes by shape, so a command must never become a map, and a map must
      // never become a string. Which map it is, the two shapes tell apart
      // between themselves: a `kind` is an input-menu choice, an `event` is
      // everything else.
      overlay_sink_->Success(flutter::EncodableValue(map));
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
    // The tile takes the camera's own shape, and that shape is not known when
    // the preview is placed: the device may not have opened yet, so the window
    // was sized from the configured fallback — 16:9 for a camera that turns out
    // to be 4:3 or square. In display mode the preview *is* the
    // picture-in-picture (design 1p), so a window that keeps the fallback shape
    // is a window that disagrees with the file.
    //
    // Once per resolution, never per frame: a camera that opened, a camera
    // swapped for another, or a reader that renegotiated its format mid-stream
    // are the three ways this value changes, and everything below draws or
    // moves a window and belongs on the platform thread.
    const uint64_t size = (static_cast<uint64_t>(width) << 32) | height;
    if (preview_frame_size_.exchange(size) == size) {
      return;
    }
    RunOnPlatformThread([this]() { RefreshCameraPreview(/*reposition=*/true); });
  };
  // A new session is a new camera and a new canvas, so the size the last one
  // settled on says nothing about this one.
  preview_frame_size_.store(0);
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

  if (method == "selectInputDevice") {
    MediaDeviceKind kind = MediaDeviceKind::kMicrophone;
    if (arguments == nullptr ||
        !MediaDeviceKindFromName(StringAt(*arguments, "kind"), &kind)) {
      reject(RecorderErrorCode::kUnknown, "An input device kind is required.");
      return;
    }
    if (!session_) {
      // Outside a session this is a no-op, not an error: what the next
      // recording opens is the configuration's business (spec 33.2).
      shared->Success();
      return;
    }
    // Absent or null is the platform default, the same meaning a null id has on
    // the recording configuration.
    const std::string device_id = StringAt(*arguments, "deviceId");
    // Dropped, not queued (spec 6, 33.7): the worker is serial, so a second
    // swap posted while the first is still opening a device would run after it
    // rather than be discarded. The gate is here, where the request arrives.
    if (swapping_device_.exchange(true)) {
      busy();
      return;
    }
    const std::shared_ptr<RecordingSession> session = session_;
    if (!worker_.Post([this, shared, session, kind, device_id]() {
          RecorderError error;
          const bool ok = session->SelectInputDevice(kind, device_id, &error);
          swapping_device_.store(false);
          if (ok) {
            if (kind == MediaDeviceKind::kCamera) {
              // A camera of another shape gives the tile another shape, and in
              // display mode the preview *is* the tile (design 1p). Only on
              // success — a device that would not open leaves the previous one
              // running, and the tile with it — and only for the camera, which
              // is the one device that has a shape at all.
              //
              // The new camera's frame size is not known yet: Start() returns
              // as soon as the capture thread exists. This re-places the window
              // from what is known now, and the first frame at a new resolution
              // re-places it again (on_camera_preview) — the two compose rather
              // than each half-fixing it.
              RunOnPlatformThread(
                  [this]() { RefreshCameraPreview(/*reposition=*/true); });
            }
            ReplySuccess(shared, flutter::EncodableValue());
            return;
          }
          // A device that will not open leaves the previous one running, so the
          // recording is untouched and the report is non-fatal by construction.
          ReplyError(shared, error);
        })) {
      swapping_device_.store(false);
      busy();
    }
    return;
  }

  if (method == "setCameraOverlay") {
    if (arguments == nullptr) {
      reject(RecorderErrorCode::kUnknown, "A camera overlay configuration is required.");
      return;
    }
    // A no-op outside a session for the compositor, but the configuration is
    // still recorded: the preview may be on screen before the first frame is,
    // and it is placed from exactly this.
    ApplyCameraOverlay(CameraOverlayFromMap(*arguments), /*from_preview=*/false);
    shared->Success();
    return;
  }

  if (method == "cameraPreviewPosition") {
    double x = 0;
    double y = 0;
    if (!overlays_.CameraPreviewPosition(&x, &y)) {
      // Null: there is no preview, or it is not the tile. In window mode the
      // preview is a separate captioned object, so dragging it moves the
      // preview and nothing else (design 1e, spec 33.5).
      shared->Success();
      return;
    }
    flutter::EncodableMap position;
    position[flutter::EncodableValue("x")] = flutter::EncodableValue(x);
    position[flutter::EncodableValue("y")] = flutter::EncodableValue(y);
    shared->Success(flutter::EncodableValue(std::move(position)));
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
    if (!session_) {
      shared->Success();
      return;
    }
    // On the worker, and not only because `Abort()` joins the capture, encode
    // and timer threads while the platform thread is the one drawing the UI.
    // The worker is serial, so posting the abort is what *orders* it: an abort
    // raised while a `stop` is still finalizing runs after that stop rather
    // than closing the writer out from under it and stranding the finished
    // recording as a `.part` (spec 18). The session is kept — dropping it is
    // `releaseSession`.
    const std::shared_ptr<RecordingSession> session = session_;
    if (!worker_.Post([this, shared, session]() {
          session->Abort();
          ReplySuccess(shared, flutter::EncodableValue());
        })) {
      busy();
    }
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
        // A different camera is a differently shaped tile, and the preview is
        // that tile: its geometry, its crop and its mask all move with it
        // (design 1p). The camera it turns on has not reported a frame size
        // yet; the first frame at a new resolution re-places the window again.
        RefreshCameraPreview(/*reposition=*/true);
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
    // A live or still-finalizing session is not a recording the user has moved
    // on from, so this is refused rather than honoured: releasing one would
    // abort a capture that is still running — or one whose file is still being
    // written out — and orphan its `.part`. Ordering is no longer the reason;
    // `RecordingSession::teardown_mutex_` now covers the writer call too, so
    // an abort cannot overtake a finalize whichever thread raises it.
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
    // Nothing may keep a device open, or keep emitting, past dispose. Both are
    // platform-thread objects and both are closed here rather than queued:
    // the metering tap holds a real microphone, and the watcher would keep
    // posting `devicesChanged` at a Dart side that is going away.
    meter_.StopAll();
    device_watcher_.Stop();
    // Nothing is left to hear a dismissal, and DisposeAll below takes the menu
    // down with everything else.
    open_menu_kind_.reset();
    const std::shared_ptr<RecordingSession> session = std::move(session_);
    // The overlays are platform-thread objects (HWNDs), so they come down here
    // rather than on the worker — and immediately, so the control strip does
    // not float over the desktop for the length of a finalize the closing
    // window is still waiting on. Nothing the queued teardown does needs them:
    // `Abort()` never reads the exclusion set, and a camera-preview frame that
    // beats it out of the pipeline finds `camera_preview_` already null under
    // `OverlayWindows`' own lock.
    overlays_.DisposeAll();
    if (!session) {
      shared->Success();
      return;
    }
    // Same worker, same reason as `abort`, and this is the path that actually
    // bites: `RecorderViewModel.dispose` fires this without awaiting an
    // outstanding stop, so closing the window during finalization is an
    // ordinary user action rather than a race they have to provoke.
    if (!worker_.Post([this, shared, session]() {
          session->Abort();
          ReplySuccess(shared, flutter::EncodableValue());
        })) {
      // A full queue answers every other call with an error, but dispose is
      // the platform going away and cannot be refused. Tearing down here still
      // waits for an in-flight finalize — `teardown_mutex_` holds that line —
      // at the cost of blocking this thread until it is done.
      session->Abort();
      shared->Success();
    }
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
      // The configuration Dart resolved its guess from, adopted before the
      // frame is resolved: the preview is the tile, and the tile is described by
      // exactly this (spec 33.5).
      if (const flutter::EncodableMap* camera = MapAt(*arguments, "cameraOverlay")) {
        last_config_.camera = CameraOverlayFromMap(*camera);
        if (session_) {
          session_->SetCameraOverlay(last_config_.camera);
        }
      }
      UpdatePreviewGeometry();
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
          BoolAt(*arguments, "matchesCompositedPip", false), PreviewDraw());
    }
    result->Success();
    return;
  }
  if (method == "showInputMenu" || method == "updateInputMenu") {
    if (arguments == nullptr) {
      fail("An input menu state is required.");
      return;
    }
    if (method == "updateInputMenu") {
      // The whole argument map is the state here; on `showInputMenu` it sits
      // under `state`, beside the placement.
      overlays_.UpdateInputMenu(*arguments);
      result->Success();
      return;
    }
    const flutter::EncodableMap* state = MapAt(*arguments, "state");
    std::string error;
    if (!overlays_.ShowInputMenu(OverlayPlacement::FromMap(*arguments),
                                 state == nullptr ? flutter::EncodableMap() : *state,
                                 &error)) {
      fail(error);
      return;
    }
    // The third overlay reaches the exclusion set the moment it exists, even
    // mid-session. A menu in the recording is the one unacceptable outcome
    // (spec 6, 33.4).
    if (session_) {
      session_->SetExcludedWindows(overlays_.ExcludedWindows());
    }
    // Which input this sheet belongs to, so a dismissal the host raises can
    // name it. A kind this build cannot read leaves it unset rather than
    // guessing: Dart drops a selection whose kind does not decode, so a
    // dismissal filed under the wrong input would be worse than none.
    MediaDeviceKind kind = MediaDeviceKind::kMicrophone;
    open_menu_kind_.reset();
    if (state != nullptr && MediaDeviceKindFromName(StringAt(*state, "kind"), &kind)) {
      open_menu_kind_ = kind;
    }
    result->Success();
    return;
  }
  if (method == "hideInputMenu") {
    // The application asked for this one, so there is nothing to report back to
    // it (spec 33.4).
    open_menu_kind_.reset();
    overlays_.HideInputMenu();
    result->Success();
    return;
  }
  if (method == "nudgeControlStrip") {
    if (arguments == nullptr) {
      fail("A displacement is required.");
      return;
    }
    overlays_.NudgeControlStrip(DoubleAt(*arguments, "dx", 0),
                                DoubleAt(*arguments, "dy", 0));
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
    // The menu hangs off the strip and comes down with it, and the application
    // asked for that too, so no dismissal is reported (spec 33.4).
    open_menu_kind_.reset();
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
