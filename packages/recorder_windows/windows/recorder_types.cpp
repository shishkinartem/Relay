#include "recorder_types.h"

#include <algorithm>
#include <sstream>

namespace relay {

namespace {

constexpr UINT kRunWorkMessage = WM_APP + 0x41;
constexpr wchar_t kDispatcherClassName[] = L"RelayRecorderDispatcherWindow";

uint32_t EvenAtLeast2(double value) {
  const int rounded = static_cast<int>(value + 0.5);
  const int clamped = (std::max)(2, rounded);
  return static_cast<uint32_t>((clamped % 2 == 0) ? clamped : clamped - 1);
}

}  // namespace

const char* ErrorCodeName(RecorderErrorCode code) {
  switch (code) {
    case RecorderErrorCode::kPermissionDenied:
      return "permissionDenied";
    case RecorderErrorCode::kSourceUnavailable:
      return "sourceUnavailable";
    case RecorderErrorCode::kSourceClosed:
      return "sourceClosed";
    case RecorderErrorCode::kCameraUnavailable:
      return "cameraUnavailable";
    case RecorderErrorCode::kMicrophoneUnavailable:
      return "microphoneUnavailable";
    case RecorderErrorCode::kSystemAudioUnavailable:
      return "systemAudioUnavailable";
    case RecorderErrorCode::kCaptureFailed:
      return "captureFailed";
    case RecorderErrorCode::kEncodingFailed:
      return "encodingFailed";
    case RecorderErrorCode::kDiskFull:
      return "diskFull";
    case RecorderErrorCode::kFinalizationFailed:
      return "finalizationFailed";
    case RecorderErrorCode::kInvalidState:
      return "invalidState";
    case RecorderErrorCode::kUnsupported:
      return "unsupported";
    case RecorderErrorCode::kUnknown:
      break;
  }
  return "unknown";
}

const char* SessionStateName(SessionState state) {
  switch (state) {
    case SessionState::kIdle:
      return "idle";
    case SessionState::kPreparing:
      return "preparing";
    case SessionState::kPrepared:
      return "prepared";
    case SessionState::kRecording:
      return "recording";
    case SessionState::kPaused:
      return "paused";
    case SessionState::kStopping:
      return "stopping";
    case SessionState::kFinalizing:
      return "finalizing";
    case SessionState::kFinalized:
      return "finalized";
    case SessionState::kFailed:
      break;
  }
  return "failed";
}

PipCorner PipCornerFromName(const std::string& name) {
  if (name == "topLeft") {
    return PipCorner::kTopLeft;
  }
  if (name == "topRight") {
    return PipCorner::kTopRight;
  }
  if (name == "bottomLeft") {
    return PipCorner::kBottomLeft;
  }
  return PipCorner::kBottomRight;
}

std::wstring RecordingConfig::PartPath() const {
  return JoinPath(output_directory, L"recording-" + Widen(recording_id) + L".part");
}

std::wstring RecordingConfig::FinalPath() const {
  return JoinPath(output_directory, L"recording-" + Widen(recording_id) + L".mp4");
}

RectD ResolvePipRect(const CameraOverlayConfig& config, double canvas_width,
                     double canvas_height, double source_aspect_ratio) {
  const double aspect =
      config.follows_source_aspect_ratio && source_aspect_ratio > 0
          ? source_aspect_ratio
          : config.aspect_ratio;
  RectD rect;
  rect.width = canvas_width * config.width_ratio;
  // A non-positive fallback is a malformed configuration, not a shape. This
  // used to produce a square tile here and a 0.0001-ratio sliver in
  // CameraOverlayConfiguration.effectiveAspectRatio on macOS, so the same bad
  // input drew a different picture-in-picture on each platform. Both now fall
  // back to the default 16:9.
  const double effective = aspect > 0 ? aspect : 16.0 / 9.0;
  rect.height = rect.width / effective;
  const double margin = canvas_width * config.margin_ratio;
  switch (config.corner) {
    case PipCorner::kTopLeft:
      rect.x = margin;
      rect.y = margin;
      break;
    case PipCorner::kTopRight:
      rect.x = canvas_width - margin - rect.width;
      rect.y = margin;
      break;
    case PipCorner::kBottomLeft:
      rect.x = margin;
      rect.y = canvas_height - margin - rect.height;
      break;
    case PipCorner::kBottomRight:
      rect.x = canvas_width - margin - rect.width;
      rect.y = canvas_height - margin - rect.height;
      break;
  }
  return rect;
}

RectD LetterboxRect(double source_width, double source_height, double canvas_width,
                    double canvas_height) {
  RectD rect;
  if (source_width <= 0 || source_height <= 0) {
    rect.width = canvas_width;
    rect.height = canvas_height;
    return rect;
  }
  const double scale =
      (std::min)(canvas_width / source_width, canvas_height / source_height);
  rect.width = source_width * scale;
  rect.height = source_height * scale;
  rect.x = (canvas_width - rect.width) / 2.0;
  rect.y = (canvas_height - rect.height) / 2.0;
  return rect;
}

void ResolveCanvasSize(const CompositionConfig& composition, uint32_t source_width,
                       uint32_t source_height, uint32_t target_height,
                       uint32_t* out_width, uint32_t* out_height) {
  const double box_height = static_cast<double>(target_height);
  const double box_width = box_height * 16.0 / 9.0;
  if (source_width == 0 || source_height == 0 ||
      composition.aspect_policy == AspectRatioPolicy::kLetterboxIntoReferenceCanvas) {
    *out_width = EvenAtLeast2(box_width);
    *out_height = EvenAtLeast2(box_height);
    return;
  }
  const double scale = (std::min)(box_width / source_width, box_height / source_height);
  // Never upscale a source smaller than the preset box: it would spend bitrate
  // on invented pixels.
  const double applied = (std::min)(scale, 1.0);
  *out_width = EvenAtLeast2(source_width * applied);
  *out_height = EvenAtLeast2(source_height * applied);
}

std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int size = ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                         static_cast<int>(utf8.size()), nullptr, 0);
  if (size <= 0) {
    return std::wstring();
  }
  std::wstring result(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        result.data(), size);
  return result;
}

std::string Narrow(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                         static_cast<int>(wide.size()), nullptr, 0,
                                         nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                        result.data(), size, nullptr, nullptr);
  return result;
}

std::string HResultToString(HRESULT hr) {
  std::ostringstream stream;
  stream << "0x" << std::hex << static_cast<unsigned long>(hr);
  return stream.str();
}

std::wstring JoinPath(const std::wstring& directory, const std::wstring& leaf) {
  if (directory.empty()) {
    return leaf;
  }
  const wchar_t last = directory.back();
  if (last == L'\\' || last == L'/') {
    return directory + leaf;
  }
  return directory + L"\\" + leaf;
}

int64_t QpcNow() {
  LARGE_INTEGER counter{};
  ::QueryPerformanceCounter(&counter);
  return counter.QuadPart;
}

int64_t QpcFrequency() {
  static const int64_t frequency = [] {
    LARGE_INTEGER value{};
    ::QueryPerformanceFrequency(&value);
    return value.QuadPart != 0 ? value.QuadPart : 1;
  }();
  return frequency;
}

int64_t QpcTo100ns(int64_t qpc_ticks) {
  const int64_t frequency = QpcFrequency();
  const int64_t whole = qpc_ticks / frequency;
  const int64_t remainder = qpc_ticks % frequency;
  return whole * 10000000LL + (remainder * 10000000LL) / frequency;
}

int64_t Now100ns() {
  return QpcTo100ns(QpcNow());
}

void SessionClock::Start(int64_t now_100ns) {
  std::lock_guard<std::mutex> lock(mutex_);
  running_ = true;
  paused_ = false;
  start_100ns_ = now_100ns;
  paused_total_100ns_ = 0;
  pause_started_100ns_ = 0;
  stopped_media_100ns_ = -1;
}

void SessionClock::Pause(int64_t now_100ns) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!running_ || paused_) {
    return;
  }
  paused_ = true;
  pause_started_100ns_ = now_100ns;
}

void SessionClock::Resume(int64_t now_100ns) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!running_ || !paused_) {
    return;
  }
  paused_total_100ns_ += now_100ns - pause_started_100ns_;
  paused_ = false;
  pause_started_100ns_ = 0;
}

void SessionClock::Stop(int64_t now_100ns) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!running_) {
    return;
  }
  if (paused_) {
    paused_total_100ns_ += now_100ns - pause_started_100ns_;
    paused_ = false;
  }
  const int64_t media = now_100ns - start_100ns_ - paused_total_100ns_;
  stopped_media_100ns_ = media < 0 ? 0 : media;
  running_ = false;
}

bool SessionClock::running() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return running_;
}

bool SessionClock::paused() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return paused_;
}

int64_t SessionClock::MediaTime100ns(int64_t capture_100ns) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!running_ || paused_) {
    return -1;
  }
  const int64_t media = capture_100ns - start_100ns_ - paused_total_100ns_;
  return media < 0 ? 0 : media;
}

int64_t SessionClock::ElapsedMs() const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!running_) {
    return stopped_media_100ns_ < 0 ? 0 : stopped_media_100ns_ / 10000LL;
  }
  const int64_t reference = paused_ ? pause_started_100ns_ : Now100ns();
  const int64_t media = reference - start_100ns_ - paused_total_100ns_;
  return media < 0 ? 0 : media / 10000LL;
}

PlatformDispatcher::PlatformDispatcher() {
  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = PlatformDispatcher::WindowProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kDispatcherClassName;
  ::RegisterClassExW(&window_class);

  window_ = ::CreateWindowExW(0, kDispatcherClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                              nullptr, window_class.hInstance, this);
}

PlatformDispatcher::~PlatformDispatcher() {
  Shutdown();
}

void PlatformDispatcher::Post(std::function<void()> work) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutting_down_ || window_ == nullptr) {
      return;
    }
    pending_.push_back(std::move(work));
  }
  ::PostMessageW(window_, kRunWorkMessage, 0, 0);
}

void PlatformDispatcher::Shutdown() {
  HWND window = nullptr;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (shutting_down_) {
      return;
    }
    shutting_down_ = true;
    pending_.clear();
    window = window_;
    window_ = nullptr;
  }
  if (window != nullptr) {
    ::DestroyWindow(window);
  }
}

void PlatformDispatcher::Drain() {
  std::vector<std::function<void()>> work;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    work.swap(pending_);
  }
  for (const std::function<void()>& item : work) {
    if (item) {
      item();
    }
  }
}

LRESULT CALLBACK PlatformDispatcher::WindowProc(HWND window, UINT message,
                                                WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  } else if (message == kRunWorkMessage) {
    auto* self = reinterpret_cast<PlatformDispatcher*>(
        ::GetWindowLongPtrW(window, GWLP_USERDATA));
    if (self != nullptr) {
      self->Drain();
    }
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace relay
