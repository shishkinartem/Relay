#ifndef RELAY_RECORDER_TYPES_H_
#define RELAY_RECORDER_TYPES_H_

#include <windows.h>

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

namespace relay {

// Mirrors RecorderErrorCode in recorder_platform_interface. The enumerator name
// is what crosses the channel as PlatformException.code, so the spelling here is
// part of the contract.
enum class RecorderErrorCode {
  kPermissionDenied,
  kSourceUnavailable,
  kSourceClosed,
  kCameraUnavailable,
  kMicrophoneUnavailable,
  kSystemAudioUnavailable,
  kCaptureFailed,
  kEncodingFailed,
  kDiskFull,
  kFinalizationFailed,
  kInvalidState,
  kUnsupported,
  kUnknown,
};

const char* ErrorCodeName(RecorderErrorCode code);

struct RecorderError {
  RecorderErrorCode code = RecorderErrorCode::kUnknown;
  std::string message;
  std::string details;
  // False degrades the session (an optional input dropped out); true ends it.
  bool fatal = true;
};

// Mirrors PlatformRecorderState.
enum class SessionState {
  kIdle,
  kPreparing,
  kPrepared,
  kRecording,
  kPaused,
  kStopping,
  kFinalizing,
  kFinalized,
  kFailed,
};

const char* SessionStateName(SessionState state);

enum class CaptureSourceType { kDisplay, kWindow };

enum class PipCorner { kTopLeft, kTopRight, kBottomLeft, kBottomRight };

PipCorner PipCornerFromName(const std::string& name);

// Camera picture-in-picture geometry. Every value is configuration pushed from
// Dart; the compositor must not hard-code any of it (spec 7, 28).
struct CameraOverlayConfig {
  double width_ratio = 0.16;
  // The tile's shape when the camera's own shape is unknown, or when
  // follows_source_aspect_ratio is off.
  double aspect_ratio = 16.0 / 9.0;
  // Give the tile the camera's own shape. A differently shaped tile can only be
  // filled by cropping the frame or stretching it; taking the camera's shape
  // removes the choice (spec 7).
  bool follows_source_aspect_ratio = true;
  double corner_radius = 0.0;
  double margin_ratio = 0.01;
  PipCorner corner = PipCorner::kBottomRight;
  bool mirror_preview = true;
  bool mirror_output = false;
};

enum class AspectRatioPolicy { kContainWithinPreset, kLetterboxIntoReferenceCanvas };

// Only one policy exists; spec 4.4/30.3 is still open.
enum class GeometryChangePolicy { kFixedCanvasLetterbox };

struct CompositionConfig {
  AspectRatioPolicy aspect_policy = AspectRatioPolicy::kContainWithinPreset;
  GeometryChangePolicy geometry_policy = GeometryChangePolicy::kFixedCanvasLetterbox;
};

struct RecordingConfig {
  std::string source_id;
  CaptureSourceType source_type = CaptureSourceType::kDisplay;
  uint32_t source_width = 0;
  uint32_t source_height = 0;
  std::string recording_id;
  std::wstring output_directory;
  std::string quality;
  uint32_t target_height = 720;
  uint32_t frame_rate = 30;
  bool camera_enabled = false;
  bool microphone_enabled = true;
  bool system_audio_enabled = true;
  bool show_cursor = true;
  CameraOverlayConfig camera;
  CompositionConfig composition;

  std::wstring PartPath() const;
  std::wstring FinalPath() const;
};

struct RectD {
  double x = 0;
  double y = 0;
  double width = 0;
  double height = 0;
};

// Pure geometry, shared by the compositor and the preview placement so the
// picture-in-picture the user sees matches the one in the file.
// source_aspect_ratio is the camera's own width/height; 0 means unknown, in
// which case the configured fallback aspect ratio is used.
RectD ResolvePipRect(const CameraOverlayConfig& config, double canvas_width,
                     double canvas_height, double source_aspect_ratio = 0);

// Largest centred rectangle of the source aspect ratio that fits the canvas.
// Produces the letterbox/pillarbox bars required by fixedCanvasLetterbox.
RectD LetterboxRect(double source_width, double source_height,
                    double canvas_width, double canvas_height);

// Encoded canvas for a source under a quality preset, mirroring
// VideoCompositionConfiguration.resolveCanvasSize in Dart. Even dimensions:
// H.264 4:2:0 chroma subsampling requires it.
void ResolveCanvasSize(const CompositionConfig& composition, uint32_t source_width,
                       uint32_t source_height, uint32_t target_height,
                       uint32_t* out_width, uint32_t* out_height);

std::wstring Widen(const std::string& utf8);
std::string Narrow(const std::wstring& wide);
std::string HResultToString(HRESULT hr);
std::wstring JoinPath(const std::wstring& directory, const std::wstring& leaf);

// Monotonic clock. QueryPerformanceCounter only: wall-clock time is never used
// for media timing (spec 8, 22).
//
// Everything downstream works in 100 ns units since boot, which is the base
// Direct3D11CaptureFrame::SystemRelativeTime and the WASAPI QPC positions
// already report, so video and audio share one timeline without conversion.
int64_t QpcNow();
int64_t QpcFrequency();
int64_t QpcTo100ns(int64_t qpc_ticks);
int64_t Now100ns();

// Session timeline. Paused intervals are subtracted, so the encoded duration
// equals the elapsed time the control strip shows (spec 9, design 1g).
class SessionClock {
 public:
  void Start(int64_t now_100ns);
  void Pause(int64_t now_100ns);
  void Resume(int64_t now_100ns);
  void Stop(int64_t now_100ns);
  bool running() const;
  bool paused() const;
  // Media time in 100 ns units, or -1 while paused/stopped: samples captured
  // during a paused interval have no place on the output timeline.
  int64_t MediaTime100ns(int64_t capture_100ns) const;
  int64_t ElapsedMs() const;

 private:
  mutable std::mutex mutex_;
  bool running_ = false;
  bool paused_ = false;
  int64_t start_100ns_ = 0;
  int64_t pause_started_100ns_ = 0;
  int64_t paused_total_100ns_ = 0;
  int64_t stopped_media_100ns_ = -1;
};

// Bounded producer/consumer queue with an explicit drop-oldest policy.
//
// Capacity is supplied by the owner and documented at each call site. When the
// queue is full the oldest element is discarded and the drop counter advances,
// so a slow consumer costs frames rather than memory (spec 22, media-pipeline
// "Backpressure").
template <typename T>
class BoundedQueue {
 public:
  explicit BoundedQueue(size_t capacity) : capacity_(capacity) {}

  // Returns false when an element had to be dropped to make room.
  bool Push(T value) {
    bool dropped = false;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (closed_) {
        // The element is lost exactly like an overflow drop, so it is counted
        // like one: a queue that swallows elements silently cannot be
        // diagnosed from the stats.
        ++dropped_;
        return false;
      }
      while (items_.size() >= capacity_) {
        items_.pop_front();
        ++dropped_;
        dropped = true;
      }
      items_.push_back(std::move(value));
    }
    cv_.notify_one();
    return !dropped;
  }

  bool Pop(T* out, std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (!cv_.wait_for(lock, timeout, [this] { return closed_ || !items_.empty(); })) {
      return false;
    }
    if (items_.empty()) {
      return false;
    }
    *out = std::move(items_.front());
    items_.pop_front();
    return true;
  }

  bool TryPop(T* out) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (items_.empty()) {
      return false;
    }
    *out = std::move(items_.front());
    items_.pop_front();
    return true;
  }

  void Close() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      closed_ = true;
    }
    cv_.notify_all();
  }

  void Clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    items_.clear();
  }

  // Re-arms a closed queue for a new session: Close() is permanent otherwise,
  // and every later Push would be refused. Empties the queue and resets the
  // per-session drop counter with it.
  void Reopen() {
    std::lock_guard<std::mutex> lock(mutex_);
    items_.clear();
    dropped_ = 0;
    closed_ = false;
  }

  size_t size() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return items_.size();
  }

  // Asked by a producer that has to allocate a resource before it can push, so
  // the resource is never committed to an element the queue cannot take.
  bool full() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return closed_ || items_.size() >= capacity_;
  }

  uint64_t dropped() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return dropped_;
  }

  bool closed() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return closed_;
  }

 private:
  mutable std::mutex mutex_;
  std::condition_variable cv_;
  std::deque<T> items_;
  const size_t capacity_;
  uint64_t dropped_ = 0;
  bool closed_ = false;
};

// Marshals work back onto the Flutter platform thread.
//
// Channel replies and event-sink pushes are only legal there, while capture,
// encoding and enumeration all run on worker threads. Backed by a message-only
// window created on the platform thread, so the existing Win32 message loop
// drains it.
class PlatformDispatcher {
 public:
  PlatformDispatcher();
  ~PlatformDispatcher();

  PlatformDispatcher(const PlatformDispatcher&) = delete;
  PlatformDispatcher& operator=(const PlatformDispatcher&) = delete;

  // Safe from any thread. Work posted after Shutdown() is discarded.
  void Post(std::function<void()> work);
  void Shutdown();

 private:
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  void Drain();

  HWND window_ = nullptr;
  std::mutex mutex_;
  std::vector<std::function<void()>> pending_;
  bool shutting_down_ = false;
};

}  // namespace relay

#endif  // RELAY_RECORDER_TYPES_H_
