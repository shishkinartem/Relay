#include "recording_session.h"

#include <algorithm>
#include <chrono>

namespace relay {

namespace {

// 20 ms of audio per encoder write: small enough to interleave tightly with
// video, large enough to keep the sink writer call rate sane.
constexpr size_t kAudioBlockFrames = kMixSampleRate / 50;
// How far behind the session clock the audio drain may run when the endpoints
// deliver nothing: half a second of silence written late costs nothing, a track
// that stops advancing would desynchronize the file. Raised from 200 ms when
// the ceiling moved to the slowest endpoint rather than the fastest — the floor
// must sit below the margin the drain now keeps, or it becomes the binding
// constraint and reintroduces the holes it exists to prevent.
constexpr int64_t kAudioCaptureLagFrames = static_cast<int64_t>(kMixSampleRate) / 2;
// The margin the drain keeps behind the slowest endpoint's write head. Matches
// AudioMixer.swift's 250 ms on macOS, which is the platform that sounds right.
constexpr int64_t kAudioDrainLatencyFrames = static_cast<int64_t>(kMixSampleRate) / 4;
constexpr int64_t kTickIntervalMs = 250;
constexpr int64_t kStatsEveryTicks = 4;
// How long a swap waits for the replacement device to open before giving up and
// leaving the incumbent running (spec 33.2). Long enough for a camera that has
// to spin up its sensor, short enough that a user who clicked a dead device is
// told so rather than left watching a menu.
constexpr std::chrono::milliseconds kDeviceOpenTimeout{3000};

// Marks one input as mid-swap for as long as it is in scope. Nested swaps of
// one input cannot happen: SelectInputDevice serializes them all behind
// `teardown_mutex_`.
class SwapWindow {
 public:
  explicit SwapWindow(std::atomic<bool>& flag) : flag_(flag) { flag_.store(true); }
  ~SwapWindow() { flag_.store(false); }

  SwapWindow(const SwapWindow&) = delete;
  SwapWindow& operator=(const SwapWindow&) = delete;

 private:
  std::atomic<bool>& flag_;
};

int64_t WallClockMs() {
  FILETIME file_time{};
  ::GetSystemTimeAsFileTime(&file_time);
  ULARGE_INTEGER value{};
  value.LowPart = file_time.dwLowDateTime;
  value.HighPart = file_time.dwHighDateTime;
  // Unix epoch in 100 ns units. Used for file metadata only, never for media
  // timing.
  constexpr int64_t kEpochDelta = 116444736000000000LL;
  return (static_cast<int64_t>(value.QuadPart) - kEpochDelta) / 10000LL;
}

uint64_t FileSizeOf(const std::wstring& path) {
  WIN32_FILE_ATTRIBUTE_DATA data{};
  if (::GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data) == FALSE) {
    return 0;
  }
  ULARGE_INTEGER size{};
  size.LowPart = data.nFileSizeLow;
  size.HighPart = data.nFileSizeHigh;
  return size.QuadPart;
}

}  // namespace

RecordingSession::RecordingSession(SessionEvents events) : events_(std::move(events)) {}

RecordingSession::~RecordingSession() {
  Abort();
  // Abort() releases the hold, but it returns early when it has already run
  // once, and a Start() that raced it could have taken one after that. A
  // std::thread still joinable here terminates the process.
  HoldSystemAwake(false);
}

void RecordingSession::SetExcludedWindows(std::vector<HWND> windows) {
  std::lock_guard<std::mutex> lock(mutex_);
  excluded_windows_ = std::move(windows);
}

SessionState RecordingSession::state() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return state_;
}

ResourceCensus RecordingSession::DebugCensus() const {
  ResourceCensus census;
  census.capture_streams = capture_.is_running() ? 1 : 0;
  {
    std::lock_guard<std::mutex> lock(camera_mutex_);
    census.camera_sessions = camera_ ? 1 : 0;
  }
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    // The capture is counted only while it is actually capturing: an input the
    // user switched off holds no endpoint, and one whose device died released
    // its own. Read from the object rather than from a flag beside it, like
    // every other row here.
    census.microphone_sessions = microphone_ && microphone_->running() ? 1 : 0;
  }
  census.writers = writer_.is_open() ? 1 : 0;
  census.compositors = compositor_.is_initialized() ? 1 : 0;
  census.session_timers = timers_.load() ? 1 : 0;
  {
    std::lock_guard<std::mutex> lock(awake_mutex_);
    census.power_assertions = awake_taken_ ? 1 : 0;
  }
  return census;
}

bool RecordingSession::has_camera_frames() const {
  return camera_frames_seen_.load();
}

double RecordingSession::camera_aspect_ratio() const {
  const uint32_t width = camera_frame_width();
  const uint32_t height = camera_frame_height();
  // 16:9 rather than square when nothing has been captured yet: the preview is
  // placed before the first frame arrives, and a square placeholder would put
  // it where the composited picture-in-picture is not.
  return height == 0 ? 16.0 / 9.0
                     : static_cast<double>(width) / static_cast<double>(height);
}

uint32_t RecordingSession::camera_frame_width() const {
  std::lock_guard<std::mutex> lock(camera_mutex_);
  return camera_ ? camera_->width() : 0;
}

uint32_t RecordingSession::camera_frame_height() const {
  std::lock_guard<std::mutex> lock(camera_mutex_);
  return camera_ ? camera_->height() : 0;
}

uint32_t RecordingSession::canvas_width() const {
  return compositor_.canvas_width();
}

uint32_t RecordingSession::canvas_height() const {
  return compositor_.canvas_height();
}

RectD RecordingSession::pip_rect() const {
  return camera_pip_draw().dest;
}

PipDraw RecordingSession::camera_pip_draw() const {
  // The camera's own frame size rather than the compositor's last frame: the
  // reader reports it as soon as the stream opens, and the preview is placed
  // before a single frame has been composed.
  return compositor_.CameraPipDraw(camera_frame_width(), camera_frame_height());
}

std::string RecordingSession::LiveDeviceId(MediaDeviceKind kind) const {
  std::lock_guard<std::mutex> lock(devices_mutex_);
  switch (kind) {
    case MediaDeviceKind::kCamera:
      return live_camera_device_id_;
    case MediaDeviceKind::kSystemAudio:
      return live_system_audio_device_id_;
    case MediaDeviceKind::kMicrophone:
      break;
  }
  return live_microphone_device_id_;
}

void RecordingSession::SetLiveDeviceId(MediaDeviceKind kind,
                                       const std::string& device_id) {
  std::lock_guard<std::mutex> lock(devices_mutex_);
  switch (kind) {
    case MediaDeviceKind::kCamera:
      live_camera_device_id_ = device_id;
      return;
    case MediaDeviceKind::kSystemAudio:
      live_system_audio_device_id_ = device_id;
      return;
    case MediaDeviceKind::kMicrophone:
      break;
  }
  live_microphone_device_id_ = device_id;
}

void RecordingSession::SetCameraOverlay(const CameraOverlayConfig& camera) {
  config_.camera = camera;
  compositor_.SetCameraOverlay(camera);
}

void RecordingSession::SetState(SessionState state) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ == state) {
      return;
    }
    state_ = state;
  }
  if (events_.on_state) {
    events_.on_state(state);
  }
}

// What the session is recording, read from the two objects that decide it and
// never from the configuration it was asked for. An input that failed to open
// or died mid-session has had its flag cleared beside the error (OnInputLost),
// so this is the achieved state — which is what the control strip needs in
// order to show a dropped input as unavailable rather than merely off
// (docs/adr/2026-08-23-optional-inputs-degrade-instead-of-blocking.md).
void RecordingSession::EmitInputs() {
  if (events_.on_inputs) {
    events_.on_inputs(mixer_.microphone_enabled(), compositor_.camera_enabled(),
                      mixer_.system_audio_enabled());
  }
}

void RecordingSession::SetMicrophoneLevelMeter(LevelAccumulator* meter) {
  microphone_meter_ = meter;
}

void RecordingSession::OnPipelineError(const RecorderError& error) {
  if (events_.on_error) {
    events_.on_error(error);
  }
  if (!error.fatal) {
    return;
  }
  // Reported, not torn down here. This runs on a capture, camera, audio or
  // encoder thread, and those threads cannot join themselves; teardown belongs
  // to the application's stop/abort/dispose, which a fatal error always
  // triggers (RecorderErrorCode.isRecoverableDuringSession is false for these).
  // The `.part` artefact stays on disk either way (spec 18, 19).
  fatal_error_.store(true);
  encoding_.store(false);
  SetState(SessionState::kFailed);
}

bool RecordingSession::Prepare(const RecordingConfig& config, RecorderError* error) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ != SessionState::kIdle && state_ != SessionState::kFinalized &&
        state_ != SessionState::kFailed) {
      error->code = RecorderErrorCode::kInvalidState;
      error->message = "A recording is already in progress.";
      return false;
    }
    result_ready_ = false;
    result_ = RecordingResult();
  }
  config_ = config;
  aborted_.store(false);
  SetState(SessionState::kPreparing);

  std::string detail;
  if (!capture_.Open(config.source_id, config.source_type, &detail)) {
    error->code = RecorderErrorCode::kSourceUnavailable;
    error->message = detail;
    SetState(SessionState::kFailed);
    return false;
  }

  uint32_t canvas_width = 0;
  uint32_t canvas_height = 0;
  const uint32_t source_width =
      capture_.content_width() > 0 ? capture_.content_width() : config.source_width;
  const uint32_t source_height =
      capture_.content_height() > 0 ? capture_.content_height() : config.source_height;
  ResolveCanvasSize(config.composition, source_width, source_height, config.target_height,
                    &canvas_width, &canvas_height);

  if (!compositor_.Initialize(capture_.device(), capture_.context(), canvas_width,
                              canvas_height, config.camera, &detail)) {
    error->code = RecorderErrorCode::kCaptureFailed;
    error->message = detail;
    SetState(SessionState::kFailed);
    return false;
  }
  compositor_.SetCameraEnabled(config.camera_enabled);

  ::CreateDirectoryW(config.output_directory.c_str(), nullptr);

  MediaWriter::Config writer_config;
  writer_config.part_path = config.PartPath();
  writer_config.final_path = config.FinalPath();
  writer_config.width = canvas_width;
  writer_config.height = canvas_height;
  writer_config.frame_rate = config.frame_rate;
  writer_config.has_audio = true;  // the track exists even if both inputs are off
  if (!writer_.Open(writer_config, capture_.device(), error)) {
    SetState(SessionState::kFailed);
    return false;
  }

  // What this session is about to open, which is what a later swap compares
  // against and re-points from.
  SetLiveDeviceId(MediaDeviceKind::kCamera, config.camera_device_id);
  SetLiveDeviceId(MediaDeviceKind::kMicrophone, config.microphone_device_id);
  SetLiveDeviceId(MediaDeviceKind::kSystemAudio, config.system_audio_device_id);

  mixer_.SetMicrophoneEnabled(config.microphone_enabled);
  mixer_.SetSystemAudioEnabled(config.system_audio_enabled);
  microphone_ring_.Reset();
  system_audio_ring_.Reset();
  audio_position_frames_ = 0;
  composition_failures_.store(0);
  backpressure_drops_.store(0);
  fatal_error_.store(false);
  camera_drop_reported_.store(false);
  recompose_failure_reported_.store(false);
  camera_frames_seen_.store(false);
  stale_frame_drops_.store(0);
  next_frame_due_100ns_.store(-1);
  last_written_video_100ns_ = -1;
  last_encoded_canvas_ = nullptr;
  // Re-arms the queue: Stop() and Abort() close it, and a session prepared
  // again from kFinalized/kFailed would otherwise refuse every frame.
  video_queue_.Reopen();

  SetState(SessionState::kPrepared);
  return true;
}

bool RecordingSession::Start(RecorderError* error) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ == SessionState::kRecording) {
      return true;  // idempotent
    }
    if (state_ != SessionState::kPrepared) {
      error->code = RecorderErrorCode::kInvalidState;
      error->message = "Start was called before the session was prepared.";
      return false;
    }
  }

  // Every application-owned always-on-top window must be non-capturable before
  // a single frame is captured. With a display source this is the only
  // mechanism keeping the overlays out of the file (spec 6).
  {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const HWND window : excluded_windows_) {
      if (window == nullptr || ::IsWindow(window) == FALSE) {
        continue;
      }
      DWORD affinity = 0;
      if (::GetWindowDisplayAffinity(window, &affinity) == FALSE ||
          affinity != WDA_EXCLUDEFROMCAPTURE) {
        ::SetWindowDisplayAffinity(window, WDA_EXCLUDEFROMCAPTURE);
      }
    }
  }

  HoldSystemAwake(true);
  clock_.Start(Now100ns());
  encoding_.store(true);
  encode_thread_ = std::thread(&RecordingSession::EncodeLoop, this);
  timers_.store(true);
  timer_thread_ = std::thread(&RecordingSession::TimerLoop, this);

  std::string detail;
  if (!capture_.Start(
          config_.show_cursor,
          [this](const CaptureEngine::Frame& frame) { OnCapturedFrame(frame); },
          [this](const RecorderError& failure) { OnPipelineError(failure); }, &detail)) {
    encoding_.store(false);
    timers_.store(false);
    if (encode_thread_.joinable()) {
      encode_thread_.join();
    }
    if (timer_thread_.joinable()) {
      timer_thread_.join();
    }
    HoldSystemAwake(false);
    error->code = RecorderErrorCode::kCaptureFailed;
    error->message = detail;
    SetState(SessionState::kFailed);
    return false;
  }

  // Audio and camera are optional inputs: a failure degrades the session and is
  // reported as a non-fatal event, it never blocks the video track (spec 23).
  //
  // Every one of those failures also clears the flag its input is announced
  // from, so the EmitInputs at the end of this function reports what the
  // session achieved rather than what it was asked for. Without that the last
  // word the control strip heard was the configured value, and an input that
  // never opened went on showing as ON for the whole recording — the strip must
  // show a dropped input as unavailable
  // (docs/adr/2026-08-23-optional-inputs-degrade-instead-of-blocking.md).
  ReportMissingAudioTrack();
  StartAudioInput(MediaDeviceKind::kMicrophone);
  StartAudioInput(MediaDeviceKind::kSystemAudio);

  // The compositor's flag, not the configuration's: it is the one the camera is
  // announced from, and the one a toggle between Prepare and Start moves.
  if (compositor_.camera_enabled()) {
    std::string camera_error;
    std::unique_ptr<CameraCapture> camera =
        StartCamera(LiveDeviceId(MediaDeviceKind::kCamera), &camera_error);
    if (!camera) {
      RecorderError failure;
      failure.code = RecorderErrorCode::kCameraUnavailable;
      failure.message = camera_error;
      failure.fatal = false;
      OnPipelineError(failure);
      OnInputLost(MediaDeviceKind::kCamera);
    } else {
      std::lock_guard<std::mutex> lock(camera_mutex_);
      camera_ = std::move(camera);
    }
  }

  SetState(SessionState::kRecording);
  EmitInputs();
  return true;
}

// Says so when the file has no audio track to record into.
//
// `MediaWriter::Open` opens the file without an audio stream rather than
// refusing it when Media Foundation has no AAC encoder to give — the Windows
// editions docs/development/compatibility-matrix.md names — and every
// WriteAudioFrames after that returns true for a stream that does not exist.
// The user recorded with both audio inputs on, saw an ordinary Ready screen and
// got a silent file, and nothing was written to the log (spec 26).
//
// Reported under each enabled input's own code rather than once as
// `kEncodingFailed`, for two reasons. Only `microphoneUnavailable` and
// `systemAudioUnavailable` reach the application's degrade path and mark an
// input unavailable on the strip; and the shared contract classifies
// `encodingFailed` as an error a session cannot continue after
// (`RecorderErrorCode.isRecoverableDuringSession`), which this one plainly can
// — a recording with no sound is still a recording, which is what the degrade
// rule is for. The encoder's own HRESULT rides along in `details`, so §26's log
// carries the reason either way.
void RecordingSession::ReportMissingAudioTrack() {
  const std::string& detail = writer_.audio_stream_error();
  if (detail.empty()) {
    return;  // the file has an audio track, or none was asked for
  }
  const auto report = [this, &detail](MediaDeviceKind kind, RecorderErrorCode code) {
    RecorderError failure;
    failure.code = code;
    failure.message =
        "This computer cannot encode audio, so the recording will have no sound.";
    failure.details = detail;
    failure.fatal = false;
    OnPipelineError(failure);
    OnInputLost(kind);
  };
  // Only for an input that was switched on: an input the user turned off has
  // nothing to report and nothing to take off the strip (the ADR above).
  if (mixer_.microphone_enabled()) {
    report(MediaDeviceKind::kMicrophone, RecorderErrorCode::kMicrophoneUnavailable);
  }
  if (mixer_.system_audio_enabled()) {
    report(MediaDeviceKind::kSystemAudio, RecorderErrorCode::kSystemAudioUnavailable);
  }
}

void RecordingSession::StartAudioInput(MediaDeviceKind kind) {
  const bool microphone = kind == MediaDeviceKind::kMicrophone;
  // The open is guarded on the flag rather than made unconditional and filtered
  // at the mixer. An endpoint opened for an input the user switched off holds a
  // device nobody asked for and reports `microphoneUnavailable` for a
  // permission the session never needed — a user who deliberately turned the
  // microphone off and never granted microphone access used to get a degrade
  // event mid-session for it. macOS guards the open the same way
  // (RecordingSession.swift `prepare`).
  if (!(microphone ? mixer_.microphone_enabled() : mixer_.system_audio_enabled())) {
    return;
  }
  // And only while there is a session to record into. `prepared` counts —
  // that is where macOS opens the microphone (RecordingSession.swift
  // `prepare`) — but a toggle arriving after the recording stopped must open
  // nothing, or an endpoint would be held open past teardown (spec 19.1).
  const SessionState current = state();
  if (current != SessionState::kPrepared && current != SessionState::kRecording &&
      current != SessionState::kPaused) {
    return;
  }
  // Read before the lock is taken: a swap holds `devices_mutex_` of its own, and
  // one lock order through this file is the only one worth having.
  const std::string device_id = LiveDeviceId(kind);
  std::string detail;
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    std::unique_ptr<AudioCapture>& capture = microphone ? microphone_ : system_audio_;
    if (capture && capture->running()) {
      return;  // already capturing: a toggle never restarts a device (spec 8)
    }
    if (!capture) {
      capture = std::make_unique<AudioCapture>(
          microphone ? AudioCapture::Kind::kMicrophone : AudioCapture::Kind::kSystemAudio,
          microphone ? &microphone_ring_ : &system_audio_ring_,
          microphone ? microphone_meter_ : nullptr);
    }
    capture->SetDeviceId(device_id);
    // Held across the start because nothing in it blocks: AudioCapture::Start
    // returns as soon as its thread exists, and the endpoint is opened on that
    // thread. Whether it opened arrives later, at OnInputLost.
    if (capture->Start(&clock_,
                       [this](const RecorderError& failure) { OnPipelineError(failure); },
                       [this, kind] { OnInputLost(kind); }, &detail)) {
      return;
    }
  }
  RecorderError failure;
  failure.code = microphone ? RecorderErrorCode::kMicrophoneUnavailable
                            : RecorderErrorCode::kSystemAudioUnavailable;
  failure.message = detail;
  failure.fatal = false;
  OnPipelineError(failure);
  OnInputLost(kind);
}

std::atomic<bool>& RecordingSession::SwapFlag(MediaDeviceKind kind) {
  switch (kind) {
    case MediaDeviceKind::kCamera:
      return camera_swap_;
    case MediaDeviceKind::kSystemAudio:
      return system_audio_swap_;
    case MediaDeviceKind::kMicrophone:
      break;
  }
  return microphone_swap_;
}

// Raised from the failing capture's own thread, and from the arms of Start that
// never got one open.
//
// Nothing here takes a lock a teardown holds while joining that thread: the
// mixer's flags are atomics, and the compositor's sits behind the compositor's
// own mutex, which is never held across a join. `EmitInputs` posts to the
// platform thread rather than running on it.
void RecordingSession::OnInputLost(MediaDeviceKind kind) {
  if (SwapFlag(kind).load()) {
    return;  // a swap candidate, not the input being recorded (see SwapFlag)
  }
  switch (kind) {
    case MediaDeviceKind::kCamera:
      compositor_.SetCameraEnabled(false);
      break;
    case MediaDeviceKind::kSystemAudio:
      mixer_.SetSystemAudioEnabled(false);
      break;
    case MediaDeviceKind::kMicrophone:
      mixer_.SetMicrophoneEnabled(false);
      break;
  }
  EmitInputs();
}

bool RecordingSession::Pause(RecorderError* error) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (state_ == SessionState::kPaused) {
    return true;
  }
  if (state_ != SessionState::kRecording) {
    error->code = RecorderErrorCode::kInvalidState;
    error->message = "Only an active recording can be paused.";
    return false;
  }
  state_ = SessionState::kPaused;
  // Capture keeps running; frames captured while paused carry no media time and
  // are discarded before the queue, so nothing accumulates (spec 9).
  clock_.Pause(Now100ns());
  if (events_.on_state) {
    events_.on_state(SessionState::kPaused);
  }
  return true;
}

bool RecordingSession::Resume(RecorderError* error) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (state_ == SessionState::kRecording) {
    return true;
  }
  if (state_ != SessionState::kPaused) {
    error->code = RecorderErrorCode::kInvalidState;
    error->message = "Only a paused recording can be resumed.";
    return false;
  }
  clock_.Resume(Now100ns());
  state_ = SessionState::kRecording;
  if (events_.on_state) {
    events_.on_state(SessionState::kRecording);
  }
  return true;
}

bool RecordingSession::SetMicrophoneEnabled(bool enabled, RecorderError* /*error*/) {
  // Switching it off keeps the stream running; only its contribution to the mix
  // changes, so the toggle never restarts a device mid-session (spec 8).
  //
  // Switching it *on* may have to open one, because an input that was off when
  // the session started was never opened for it (StartAudioInput). Nothing here
  // blocks the thread the UI is drawn on: the endpoint is opened on the
  // capture's own thread, and a failure arrives later at OnInputLost.
  mixer_.SetMicrophoneEnabled(enabled);
  if (enabled) {
    StartAudioInput(MediaDeviceKind::kMicrophone);
  }
  EmitInputs();
  return true;
}

bool RecordingSession::SetSystemAudioEnabled(bool enabled, RecorderError* /*error*/) {
  // The microphone's rule, for the same reasons. See SetMicrophoneEnabled.
  mixer_.SetSystemAudioEnabled(enabled);
  if (enabled) {
    StartAudioInput(MediaDeviceKind::kSystemAudio);
  }
  EmitInputs();
  return true;
}

std::unique_ptr<CameraCapture> RecordingSession::StartCamera(
    const std::string& device_id, std::string* error) {
  auto camera = std::make_unique<CameraCapture>();
  camera->SetDeviceId(device_id);
  if (!camera->Start(
          capture_.device(), &compositor_,
          [this](const uint8_t* pixels, uint32_t width, uint32_t height,
                 uint32_t stride) {
            // The preview is reached only by a frame the compositor already
            // holds (CameraCapture::PublishFrame), which is what makes this the
            // record of the camera reaching the *file* rather than the record
            // of it reaching a window: `hasCamera` describes the recording
            // (spec 19).
            camera_frames_seen_.store(true);
            if (events_.on_camera_preview) {
              events_.on_camera_preview(pixels, width, height, stride);
            }
          },
          [this](const RecorderError& failure) { OnPipelineError(failure); },
          [this] { OnInputLost(MediaDeviceKind::kCamera); }, error)) {
    return nullptr;
  }
  return camera;
}

bool RecordingSession::SetCameraEnabled(bool enabled, RecorderError* error) {
  compositor_.SetCameraEnabled(enabled);
  bool running = false;
  {
    std::lock_guard<std::mutex> lock(camera_mutex_);
    running = camera_ && camera_->running();
  }
  if (enabled && !running && capture_.device() != nullptr) {
    std::string camera_error;
    std::unique_ptr<CameraCapture> camera =
        StartCamera(LiveDeviceId(MediaDeviceKind::kCamera), &camera_error);
    if (!camera) {
      compositor_.SetCameraEnabled(false);
      error->code = RecorderErrorCode::kCameraUnavailable;
      error->message = camera_error;
      error->fatal = false;
      EmitInputs();
      return false;
    }
    std::unique_ptr<CameraCapture> previous;
    {
      std::lock_guard<std::mutex> lock(camera_mutex_);
      previous = std::move(camera_);
      camera_ = std::move(camera);
    }
    // A camera that had failed and self-exited is still an object holding a
    // device handle; stopped outside the lock, because stopping joins its
    // thread.
    if (previous) {
      previous->Stop();
    }
  } else if (!enabled && running) {
    std::unique_ptr<CameraCapture> previous;
    {
      std::lock_guard<std::mutex> lock(camera_mutex_);
      previous = std::move(camera_);
    }
    if (previous) {
      previous->Stop();
    }
    camera_frames_seen_.store(false);
  }
  EmitInputs();
  return true;
}

bool RecordingSession::SelectInputDevice(MediaDeviceKind kind,
                                         const std::string& device_id,
                                         RecorderError* error) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // Recording and paused, and nothing else: what the next recording opens is
    // the configuration's business, and a session being torn down has no live
    // capture to re-point.
    if (state_ != SessionState::kRecording && state_ != SessionState::kPaused) {
      return true;  // a no-op outside a session, never an error (spec 33.2)
    }
  }
  // The same lock a stop and an abort take, for the same reason they take it
  // past their joins: a swap holds two devices open at once, and a teardown
  // that ran through the middle of one would close the incumbent while the
  // replacement was still being waited on. The cost is a stop that waits out an
  // in-flight swap, bounded by kDeviceOpenTimeout.
  std::lock_guard<std::mutex> teardown(teardown_mutex_);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    // Read again under the teardown lock: the state can have moved on while
    // this call was waiting for it.
    if (state_ != SessionState::kRecording && state_ != SessionState::kPaused) {
      return true;
    }
  }
  switch (kind) {
    case MediaDeviceKind::kCamera:
      return SwapCamera(device_id, error);
    case MediaDeviceKind::kMicrophone:
    case MediaDeviceKind::kSystemAudio:
      return SwapAudio(kind, device_id, error);
  }
  return true;
}

bool RecordingSession::SwapCamera(const std::string& device_id,
                                  RecorderError* error) {
  if (LiveDeviceId(MediaDeviceKind::kCamera) == device_id) {
    return true;  // the device already selected: no-op, and no gap (spec 33.7)
  }
  bool running = false;
  {
    std::lock_guard<std::mutex> lock(camera_mutex_);
    running = camera_ && camera_->running();
  }
  if (!running || capture_.device() == nullptr) {
    // Nothing to re-point: the camera is off, and the id is what the next
    // SetCameraEnabled(true) will open.
    SetLiveDeviceId(MediaDeviceKind::kCamera, device_id);
    return true;
  }

  // Two cameras are open from here until this returns, and only one of them is
  // the camera the control strip is showing. A candidate that dies inside this
  // window must not take the incumbent's tile off the strip (see SwapFlag).
  const SwapWindow mid_swap(SwapFlag(MediaDeviceKind::kCamera));

  std::string detail;
  std::unique_ptr<CameraCapture> next = StartCamera(device_id, &detail);
  // The old camera is still delivering while this waits. Both write the
  // compositor's latest-wins slot for as long as the overlap lasts, which is a
  // frame or two of whichever arrives last — never a gap in the video.
  if (!next || !next->WaitUntilOpen(kDeviceOpenTimeout)) {
    if (next) {
      next->Stop();
    }
    error->code = RecorderErrorCode::kCameraUnavailable;
    error->message =
        "That camera could not be opened. The previous one is still recording.";
    error->details = detail;
    // Non-fatal, always: a device that will not open must never stop a
    // recording (spec 33.2).
    error->fatal = false;
    return false;
  }

  std::unique_ptr<CameraCapture> previous;
  {
    std::lock_guard<std::mutex> lock(camera_mutex_);
    previous = std::move(camera_);
    camera_ = std::move(next);
  }
  SetLiveDeviceId(MediaDeviceKind::kCamera, device_id);
  if (previous) {
    previous->Stop();
  }
  return true;
}

bool RecordingSession::SwapAudio(MediaDeviceKind kind,
                                 const std::string& device_id,
                                 RecorderError* error) {
  const bool microphone = kind == MediaDeviceKind::kMicrophone;
  if (LiveDeviceId(kind) == device_id) {
    return true;  // no-op, and no gap in the audio (spec 33.7)
  }
  bool have_capture = false;
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    have_capture = static_cast<bool>(microphone ? microphone_ : system_audio_);
  }
  if (!have_capture) {
    // The input was never opened — it is switched off, or its endpoint never
    // came up. The id is what the next open uses, whether that is this input
    // being switched back on or the next session (StartAudioInput).
    SetLiveDeviceId(kind, device_id);
    return true;
  }

  // Two endpoints are open from here until this returns, and only one of them
  // is the input the control strip is showing. A candidate that dies inside
  // this window must not take the incumbent off the strip (see SwapFlag).
  const SwapWindow mid_swap(SwapFlag(kind));

  auto next = std::make_unique<AudioCapture>(
      microphone ? AudioCapture::Kind::kMicrophone : AudioCapture::Kind::kSystemAudio,
      microphone ? &microphone_ring_ : &system_audio_ring_,
      microphone ? microphone_meter_ : nullptr);
  next->SetDeviceId(device_id);
  std::string detail;
  // Both endpoints run for the length of the handshake. They write the same
  // ring, which takes the first sample offered for any position on the
  // timeline and skips the rest, so the overlap is neither doubled nor lost —
  // and the timeline is monotonic, so what a gap would leave is silence at a
  // known position rather than drift (spec 8).
  if (!next->Start(
          &clock_,
          [this](const RecorderError& failure) { OnPipelineError(failure); },
          [this, kind] { OnInputLost(kind); }, &detail) ||
      !next->WaitUntilOpen(kDeviceOpenTimeout)) {
    next->Stop();
    error->code = microphone ? RecorderErrorCode::kMicrophoneUnavailable
                             : RecorderErrorCode::kSystemAudioUnavailable;
    error->message = microphone
                         ? "That microphone could not be opened. The previous one "
                           "is still recording."
                         : "That audio output could not be opened. The previous "
                           "one is still recording.";
    error->details = detail;
    error->fatal = false;
    return false;
  }

  std::unique_ptr<AudioCapture> previous;
  {
    std::lock_guard<std::mutex> lock(audio_mutex_);
    std::unique_ptr<AudioCapture>& current = microphone ? microphone_ : system_audio_;
    previous = std::move(current);
    current = std::move(next);
  }
  SetLiveDeviceId(kind, device_id);
  if (previous) {
    // Outside the lock: stopping joins the capture thread, which can be inside
    // an error or lost callback of its own.
    previous->Stop();
  }
  if (microphone && microphone_meter_ != nullptr) {
    // The endpoint that just closed cleared the live flag on its way out, after
    // the replacement had already set it. Re-asserted here, where both are
    // settled, so the meter goes on reading the capture this session holds
    // rather than opening a second handle on it (spec 33.2).
    std::lock_guard<std::mutex> lock(audio_mutex_);
    microphone_meter_->SetLive(microphone_ && microphone_->running());
  }
  return true;
}

void RecordingSession::OnCapturedFrame(const CaptureEngine::Frame& frame) {
  const int64_t media_100ns = clock_.MediaTime100ns(frame.timestamp_100ns);
  if (media_100ns < 0) {
    return;  // paused, or the clock has not started: nothing to encode
  }

  // Frame-rate limiting. Windows.Graphics.Capture delivers on change at up to
  // the display refresh rate; the session encodes at the configured rate and
  // skips the rest. Skipped frames are not drops: nothing was lost from the
  // encoded timeline.
  //
  // The gate is a deadline the schedule advances by exactly one interval per
  // accepted frame, not a minimum gap since the frame before. A gap is what
  // this used to be, and on a 47-48 Hz panel it accepted every second frame and
  // encoded 24 fps into a file declaring 30 — NextFrameDeadline100ns carries
  // the arithmetic and the reason.
  const int64_t interval_100ns = FrameInterval100ns(config_.frame_rate);
  const int64_t due_100ns = next_frame_due_100ns_.load();
  if (!FrameIsDue(media_100ns, due_100ns)) {
    return;
  }

  QueuedFrame queued;
  std::string detail;
  bool camera_dropped = false;
  bool composed = false;
  {
    // From the look at the queue to the push, so the encoder's re-draw of a
    // held frame cannot take a canvas in between (composition_mutex_).
    std::lock_guard<std::mutex> lock(composition_mutex_);
    // Composing hands out the next canvas of a fixed pool, so a frame that the
    // queue cannot take must be dropped before it is composed — otherwise the
    // blit lands in the canvas the encoder is still reading. The deadline stays
    // where it is: the slot is still unfilled, and the next frame should take
    // it.
    if (video_queue_.full()) {
      backpressure_drops_.fetch_add(1);
      return;
    }
    next_frame_due_100ns_.store(
        NextFrameDeadline100ns(due_100ns, media_100ns, interval_100ns));

    composed = compositor_.Compose(frame.texture, frame.width, frame.height,
                                   &queued.canvas, &detail, &camera_dropped);
    if (composed) {
      queued.timestamp_100ns = media_100ns;
      // No file I/O on this thread: the encoder thread owns the sink writer
      // (spec 22). This is the only producer and the queue had room a moment
      // ago — only Pop runs concurrently — so the push cannot displace a frame
      // the encoder still needs. A queue closed by a concurrent stop counts its
      // own drop.
      video_queue_.Push(std::move(queued));
    }
  }
  if (!composed) {
    const uint64_t failures = composition_failures_.fetch_add(1);
    // Reported once, not per frame. A fault that fails composition fails it for
    // every frame, and this handler runs on the capture thread at the frame
    // rate: the previous version posted 20-30 channel events a second at the
    // platform thread for the whole session, which is a diagnostic flood on the
    // one thread the entire UI is drawn on. The count still reaches the log
    // through `droppedFrames` in the stats tick.
    if (failures == 0 && events_.on_error) {
      RecorderError failure;
      failure.code = RecorderErrorCode::kCaptureFailed;
      failure.message = "A frame could not be composed.";
      failure.details = detail;
      failure.fatal = false;
      events_.on_error(failure);
    }
    return;
  }
  if (camera_dropped) {
    NoteCameraDropped(detail);
  }
}

// The screen was composed; only the tile was left out. Reported once, as a
// degraded input rather than a capture failure, because that is what the user
// sees: a recording that is fine except that the camera is not in it.
void RecordingSession::NoteCameraDropped(const std::string& detail) {
  if (camera_drop_reported_.exchange(true) || !events_.on_error) {
    return;
  }
  RecorderError degraded;
  degraded.code = RecorderErrorCode::kCameraUnavailable;
  degraded.message =
      "The camera could not be drawn into the recording. The screen is still "
      "being recorded.";
  degraded.details = detail;
  degraded.fatal = false;
  events_.on_error(degraded);
}

void RecordingSession::DrainAudio(bool flush) {
  const int64_t ceiling_100ns =
      flush ? clock_.ElapsedMs() * 10000LL : clock_.MediaTime100ns(Now100ns());
  if (ceiling_100ns < 0) {
    return;  // paused
  }
  int64_t ceiling_frames =
      (ceiling_100ns * static_cast<int64_t>(kMixSampleRate)) / 10000000LL;
  if (!flush) {
    // The rings are filled from WASAPI packet timestamps, so what they hold
    // always lags the current instant by at least one device period. Encoding
    // up to `now` would write the tail of every block as silence and never
    // revisit it — audio_position_frames_ only moves forward — which chops the
    // track at the block rate.
    //
    // The ceiling is therefore the SLOWEST enabled endpoint's head, less a
    // margin. Taking the fastest, as this did, meant the microphone was
    // routinely read past its own head whenever the loopback ran ahead of it —
    // the two endpoints are timestamped by different clocks and one is always
    // ahead — and every one of those reads became zeros the real samples could
    // never replace. That is the crackle the first Windows recording had.
    //
    // A source that is disabled or has never delivered contributes no head, so
    // a microphone that failed to open cannot stall the track; a source that
    // stalls after starting is bounded by the floor inside the helper.
    int64_t heads[2] = {0, 0};
    size_t head_count = 0;
    if (mixer_.microphone_enabled() && microphone_ring_.started()) {
      heads[head_count++] = microphone_ring_.write_end();
    }
    if (mixer_.system_audio_enabled() && system_audio_ring_.started()) {
      heads[head_count++] = system_audio_ring_.write_end();
    }
    ceiling_frames =
        AudioDrainCeilingFrames(ceiling_frames, heads, head_count,
                                kAudioDrainLatencyFrames, kAudioCaptureLagFrames);
  }
  while (audio_position_frames_ + static_cast<int64_t>(kAudioBlockFrames) <=
         ceiling_frames) {
    mixer_.Mix(audio_position_frames_, kAudioBlockFrames, &audio_block_);
    const int64_t timestamp_100ns =
        (audio_position_frames_ * 10000000LL) / static_cast<int64_t>(kMixSampleRate);
    RecorderError error;
    if (!writer_.WriteAudioFrames(audio_block_.data(), kAudioBlockFrames,
                                  timestamp_100ns, &error)) {
      OnPipelineError(error);
      return;
    }
    audio_position_frames_ += static_cast<int64_t>(kAudioBlockFrames);
  }
}

void RecordingSession::EncodeLoop() {
  const int64_t interval_100ns = FrameInterval100ns(config_.frame_rate);
  while (encoding_.load()) {
    DrainAudio(false);
    QueuedFrame frame;
    if (!video_queue_.Pop(&frame, std::chrono::milliseconds(5))) {
      // Nothing was captured for the length of that wait. For a window source
      // that is the ordinary state, not a fault: hold the last picture on the
      // timeline rather than let the video clock stand still (spec 22).
      if (!RepeatLastComposedFrame(interval_100ns)) {
        return;  // stops encoding; the artefact is left for stop/abort to handle
      }
      continue;
    }
    // Never an instant the file already carries. The capture thread claims its
    // deadline before it composes, so a capture thread descheduled for longer
    // than the repeat's grace can hand over a frame whose slot a repeat has
    // filled in the meantime, and a sink writer is entitled to refuse a sample
    // that goes backwards. What that frame shows is on screen already.
    if (frame.timestamp_100ns <= last_written_video_100ns_) {
      stale_frame_drops_.fetch_add(1);
      continue;
    }
    RecorderError error;
    if (!writer_.WriteVideoFrame(frame.canvas.get(), frame.timestamp_100ns, &error)) {
      OnPipelineError(error);
      return;  // stops encoding; the artefact is left for stop/abort to handle
    }
    last_written_video_100ns_ = frame.timestamp_100ns;
    // Held after the write rather than before it, so a canvas the encoder
    // refused is never the one a repeat publishes.
    last_encoded_canvas_ = frame.canvas;
  }

  // Drain whatever the capture side already handed over before finalizing.
  QueuedFrame frame;
  while (video_queue_.TryPop(&frame)) {
    if (frame.timestamp_100ns <= last_written_video_100ns_) {
      stale_frame_drops_.fetch_add(1);
      continue;
    }
    RecorderError error;
    if (!writer_.WriteVideoFrame(frame.canvas.get(), frame.timestamp_100ns, &error)) {
      break;
    }
    last_written_video_100ns_ = frame.timestamp_100ns;
  }
  DrainAudio(true);
}

// Windows.Graphics.Capture delivers a frame for a *window* only when its content
// changes, and a window nobody is typing in changes nothing for seconds at a
// time. Nothing else in this pipeline republishes anything, so the video track
// simply stopped advancing: the first Windows recording of a window encoded 75
// frames in 14.6 seconds — five a second in a file declaring thirty — and held
// single images for seconds while the audio ran on underneath (spec 10, 22).
//
// macOS is paced by ScreenCaptureKit's `minimumFrameInterval` and so has no
// decimation problem, but it is not known to be free of this one: it is handed
// an unchanged frame on every interval and drops it, because `isFrameComplete`
// in RecordingSession.swift encodes only `SCFrameStatus.complete`. That is a
// question for that platform's own suite, not an assumption this one should be
// written around.
//
// Runs on the encoder thread, and only when the queue has just come up empty.
// Both halves matter. It is the thread that owns the sink writer, so no second
// writer appears; and an empty queue is the proof that the encoder is not
// behind, which is what keeps this from becoming an unbounded backlog under
// another name. The empty queue is also what makes the canvas safe to read: the
// compositor hands out the next texture of a three-deep pool per composed frame,
// and with the queue empty — looked at again under `composition_mutex_`, which
// the capture thread holds across its own compose and push — no canvas but the
// one last written is in use, so neither publishing it again nor re-drawing
// into the next one can land on a texture the encoder still needs.
//
// A repeat is not a captured frame and is deliberately not counted as one:
// `capturedFrames` goes on meaning frames Windows.Graphics.Capture delivered,
// which is the diagnostic that made this defect visible in the first place. In
// the log a working repeat reads as `encodedFrames` climbing while
// `capturedFrames` stands still.
//
// What is held is the *source*, not the whole canvas. Republishing the canvas
// held the camera tile along with the window, so the third Windows run recorded
// a camera that was live on screen and stuttering in the file: still for as
// long as the window under it was, stepping only when the window changed. The
// canvas is now drawn again from the compositor's copy of the last source frame
// whenever anything the tile is drawn from has moved on
// (VideoCompositor::Recompose), and published unchanged when nothing has, which
// with the camera off is always.
bool RecordingSession::RepeatLastComposedFrame(int64_t interval_100ns) {
  if (!last_encoded_canvas_) {
    return true;  // nothing composed yet: there is no picture to hold
  }
  const int64_t media_now_100ns = clock_.MediaTime100ns(Now100ns());
  if (media_now_100ns < 0) {
    return true;  // paused or stopped: the timeline is not advancing (spec 9)
  }
  const int64_t repeat_100ns = RepeatFrameTimestamp100ns(
      media_now_100ns, last_written_video_100ns_, interval_100ns);
  if (repeat_100ns < 0) {
    return true;  // the source is keeping up on its own
  }

  winrt::com_ptr<ID3D11Texture2D> canvas = last_encoded_canvas_;
  std::string detail;
  bool camera_dropped = false;
  VideoCompositor::RecomposeResult recomposed =
      VideoCompositor::RecomposeResult::kUnchanged;
  {
    std::lock_guard<std::mutex> lock(composition_mutex_);
    // The capture thread got a frame in after all: encode that instead. It is
    // also the condition the re-draw needs, because only with nothing queued
    // is the canvas it is about to take guaranteed not to be one still waiting
    // to be encoded (composition_mutex_).
    if (video_queue_.size() > 0) {
      return true;
    }
    winrt::com_ptr<ID3D11Texture2D> redrawn;
    recomposed = compositor_.Recompose(&redrawn, &detail, &camera_dropped);
    if (recomposed == VideoCompositor::RecomposeResult::kComposed) {
      canvas = std::move(redrawn);
    }
  }
  if (recomposed == VideoCompositor::RecomposeResult::kFailed &&
      !recompose_failure_reported_.exchange(true) && events_.on_error) {
    RecorderError failure;
    failure.code = RecorderErrorCode::kCaptureFailed;
    failure.message =
        "A held frame could not be redrawn with the camera, so the camera stays "
        "frozen in the recording while the source is unchanged.";
    failure.details = detail;
    failure.fatal = false;
    events_.on_error(failure);
  }
  if (camera_dropped) {
    NoteCameraDropped(detail);
  }

  RecorderError error;
  if (!writer_.WriteVideoFrame(canvas.get(), repeat_100ns, &error)) {
    OnPipelineError(error);
    return false;
  }
  last_written_video_100ns_ = repeat_100ns;
  last_encoded_canvas_ = std::move(canvas);
  return true;
}

void RecordingSession::TimerLoop() {
  int64_t ticks = 0;
  while (timers_.load()) {
    ::Sleep(static_cast<DWORD>(kTickIntervalMs));
    if (!timers_.load()) {
      break;
    }
    if (events_.on_tick) {
      events_.on_tick(clock_.ElapsedMs());
    }
    if (++ticks % kStatsEveryTicks == 0 && events_.on_stats) {
      events_.on_stats(CollectStats());
    }
  }
}

SessionStats RecordingSession::CollectStats() const {
  SessionStats stats;
  stats.captured_frames = capture_.captured_frames();
  stats.encoded_frames = writer_.encoded_video_frames();
  stats.dropped_frames = video_queue_.dropped() + composition_failures_.load() +
                         backpressure_drops_.load() + stale_frame_drops_.load();
  stats.audio_discontinuities =
      microphone_ring_.discontinuities() + system_audio_ring_.discontinuities();
  const int64_t video_100ns = writer_.last_video_timestamp_100ns();
  const int64_t audio_100ns = writer_.last_audio_timestamp_100ns();
  stats.av_drift_ms = static_cast<double>(video_100ns - audio_100ns) / 10000.0;
  stats.encoder_name = writer_.encoder_name();
  stats.hardware_encoding = writer_.hardware_encoding();
  return stats;
}

// The counterpart to macOS's `beginActivity` (RecordingSession.swift).
//
// Windows has no App Nap, so there is nothing to opt out of on the scheduling
// side; what it does have is idle sleep, and a machine that suspends halfway
// through a recording truncates the file. ES_SYSTEM_REQUIRED for the length of
// the session says "not while this is running".
//
// ES_DISPLAY_REQUIRED is deliberately not set: blanking the screen is the
// user's power policy, and a recorder should not override it behind their
// back. macOS makes the same choice for the same reason.
//
// The state is per *thread*, not per process, and it is dropped when that
// thread exits — so the hold gets a thread of its own, which does nothing but
// take it, wait, and drop it.
//
// The callers are not one thread and cannot be made into one: `start` runs
// `Start()` inline on the Flutter platform thread, while `stop` and the
// teardown behind `prepare`/`releaseSession` post `Stop()`/`Abort()` to the
// plugin's serial worker (recorder_windows_plugin.cpp). Setting the state on
// whichever thread happens to call would clear a hold the worker never had and
// leave the platform thread — which lives as long as the app — holding
// ES_SYSTEM_REQUIRED for the rest of the session, silently overriding the
// user's power policy long after the recording ended.
//
// Idempotent in both directions: every session exit runs through Stop or
// Abort, and a hold that was never taken must not be released.
void RecordingSession::HoldSystemAwake(bool hold) {
  std::unique_lock<std::mutex> lock(awake_mutex_);
  if (hold == awake_held_) {
    return;
  }
  if (hold) {
    awake_held_ = true;
    awake_taken_ = false;
    awake_thread_ = std::thread(&RecordingSession::SystemAwakeLoop, this);
    // Returns with the hold in effect rather than merely requested, so that
    // Start() cannot report a running recording the machine is still free to
    // suspend. The release is synchronous for the same reason: it joins.
    awake_cv_.wait(lock, [this] { return awake_taken_; });
    return;
  }
  awake_held_ = false;
  awake_cv_.notify_all();
  // Moved out under the lock and joined outside it: the hold thread needs the
  // same mutex to observe the release, and a second releaser must find nothing
  // left to join rather than join it twice.
  std::thread released = std::move(awake_thread_);
  lock.unlock();
  if (released.joinable()) {
    released.join();
  }
}

void RecordingSession::SystemAwakeLoop() {
  ::SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
  {
    std::unique_lock<std::mutex> lock(awake_mutex_);
    awake_taken_ = true;
    awake_cv_.notify_all();
    awake_cv_.wait(lock, [this] { return !awake_held_; });
  }
  // Windows would drop the state when this thread exits in a moment anyway;
  // clearing it explicitly is what makes the release observable to a caller
  // that joins.
  ::SetThreadExecutionState(ES_CONTINUOUS);
}

void RecordingSession::StopInputs() {
  capture_.Stop();
  std::unique_ptr<CameraCapture> camera;
  {
    std::lock_guard<std::mutex> lock(camera_mutex_);
    camera = std::move(camera_);
  }
  if (camera) {
    // Outside the lock: stopping joins the camera thread, which can be inside a
    // preview or error callback of its own.
    camera->Stop();
  }
  std::unique_ptr<AudioCapture> microphone;
  std::unique_ptr<AudioCapture> system_audio;
  {
    // Moved out under the lock and stopped outside it, on the same terms as the
    // camera: a stop joins a capture thread, and no lock this session hands to
    // that thread's callbacks may be held across the join.
    std::lock_guard<std::mutex> lock(audio_mutex_);
    microphone = std::move(microphone_);
    system_audio = std::move(system_audio_);
  }
  if (microphone) {
    microphone->Stop();
  }
  if (system_audio) {
    system_audio->Stop();
  }
}

bool RecordingSession::Stop(RecordingResult* result, RecorderError* error) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (result_ready_) {
      // Stopping an already-stopped session returns the same file rather than
      // failing (Recorder.stop contract).
      *result = result_;
      return true;
    }
    if (state_ == SessionState::kIdle || state_ == SessionState::kPreparing) {
      error->code = RecorderErrorCode::kInvalidState;
      error->message = "There is no recording to stop.";
      return false;
    }
    if (state_ == SessionState::kStopping || state_ == SessionState::kFinalizing) {
      error->code = RecorderErrorCode::kInvalidState;
      error->message = "The recording is already being finalized.";
      return false;
    }
    state_ = SessionState::kStopping;
  }
  if (events_.on_state) {
    events_.on_state(SessionState::kStopping);
  }

  // Held to the end of the call, not just around the joins. `Abort()` takes the
  // same lock, and it is `writer_.Abort()` — not the joins — that this has to
  // exclude: it closes the sink writer and shuts Media Foundation down, so an
  // abort that overtook the `Finalize()` below would leave a finished recording
  // stranded as `recording-<id>.part` (spec 18). Nothing under this lock blocks
  // on the platform thread: the state callbacks only post to it.
  std::lock_guard<std::mutex> teardown(teardown_mutex_);
  clock_.Stop(Now100ns());
  StopInputs();
  encoding_.store(false);
  if (encode_thread_.joinable()) {
    encode_thread_.join();
  }
  timers_.store(false);
  if (timer_thread_.joinable()) {
    timer_thread_.join();
  }
  video_queue_.Close();
  // Released with the encoder thread joined, and before the compositor is shut
  // down: the repeat holds a reference to one of the compositor's canvases, and
  // that texture must not outlive the pool it came from.
  last_encoded_canvas_ = nullptr;

  SetState(SessionState::kFinalizing);
  if (!writer_.Finalize(error)) {
    HoldSystemAwake(false);
    SetState(SessionState::kFailed);
    return false;
  }

  RecordingResult finished;
  finished.path = config_.FinalPath();
  finished.recording_id = config_.recording_id;
  finished.size_bytes = FileSizeOf(finished.path);
  finished.duration_ms = clock_.ElapsedMs();
  finished.created_at_ms = WallClockMs();
  finished.width = compositor_.canvas_width();
  finished.height = compositor_.canvas_height();
  finished.frame_rate = config_.frame_rate;
  finished.has_audio = writer_.encoded_audio_frames() > 0;
  finished.has_camera = camera_frames_seen_.load();

  compositor_.Shutdown();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    result_ = finished;
    result_ready_ = true;
  }
  *result = finished;
  HoldSystemAwake(false);
  SetState(SessionState::kFinalized);
  return true;
}

void RecordingSession::Abort() {
  if (aborted_.exchange(true)) {
    return;  // idempotent
  }
  // The other half of Stop()'s lock, and the reason that one reaches past the
  // joins: an abort arriving mid-stop — the window closing while a long
  // recording is still being written out — waits for the finalize here instead
  // of racing it to `MediaWriter::mutex_`. Whoever calls this is blocked for
  // the duration, which is why the plugin runs it on the serial worker rather
  // than on the platform thread.
  std::lock_guard<std::mutex> teardown(teardown_mutex_);
  clock_.Stop(Now100ns());
  StopInputs();
  encoding_.store(false);
  if (encode_thread_.joinable()) {
    encode_thread_.join();
  }
  timers_.store(false);
  if (timer_thread_.joinable()) {
    timer_thread_.join();
  }
  video_queue_.Close();
  video_queue_.Clear();
  last_encoded_canvas_ = nullptr;
  // No Finalize and no delete: the `.part` artefact stays on disk for startup
  // recovery (spec 18). After a stop that already finalized, `writer_` is
  // closed and the file renamed, so this lands as a no-op rather than an undo.
  writer_.Abort();
  compositor_.Shutdown();
  HoldSystemAwake(false);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (state_ != SessionState::kFailed && state_ != SessionState::kFinalized) {
      state_ = SessionState::kIdle;
    }
  }
}

bool RecordingSession::RecoverArtifact(const std::wstring& artifact_path,
                                       RecordingResult* result) {
  std::wstring recovered = artifact_path;
  const size_t dot = recovered.find_last_of(L'.');
  if (dot != std::wstring::npos) {
    recovered = recovered.substr(0, dot);
  }
  recovered += L".mp4";

  // Renamed, not copied. A successful recovery is a finalize, and spec 18/19
  // say the `.part` is "renamed by a successful finalize; kept by every other
  // exit" — which is also what the application assumes when it rescans after
  // one (artifact_recovery.dart). Copying left the artefact on disk, so the
  // recovery card came back on every launch and every recovered recording cost
  // twice its size. Renaming is not deleting, which is all §18 forbids.
  //
  // No MOVEFILE_REPLACE_EXISTING: an `.mp4` already at that name is a finished
  // recording this artefact has no business overwriting, and the move refuses
  // rather than TOCTOU-checking for it first. macOS refuses the same way
  // (RecorderMacosPlugin.swift `recover`).
  if (::MoveFileExW(artifact_path.c_str(), recovered.c_str(), 0) == FALSE) {
    return false;
  }
  // Probed under its final name, and put back untouched when nothing readable
  // is in it: Media Foundation resolves a byte-stream handler from the file's
  // extension, so an artefact still called `.part` is not the file the source
  // reader would be asked to open on the next launch. A failed recovery leaves
  // the artefact exactly where it was (spec 18).
  MediaProbe probe;
  if (!MediaWriter::Probe(recovered, &probe) || !probe.readable) {
    ::MoveFileExW(recovered.c_str(), artifact_path.c_str(), 0);
    return false;
  }

  std::wstring leaf = recovered;
  const size_t slash = leaf.find_last_of(L"\\/");
  if (slash != std::wstring::npos) {
    leaf = leaf.substr(slash + 1);
  }
  const std::wstring prefix = L"recording-";
  std::wstring recording_id;
  if (leaf.compare(0, prefix.size(), prefix) == 0) {
    recording_id = leaf.substr(prefix.size(), leaf.size() - prefix.size() - 4);
  }

  result->path = recovered;
  result->recording_id = Narrow(recording_id);
  result->size_bytes = FileSizeOf(recovered);
  result->duration_ms = probe.duration_ms;
  result->created_at_ms = WallClockMs();
  result->width = probe.width;
  result->height = probe.height;
  result->frame_rate = probe.frame_rate;
  result->has_audio = probe.has_audio;
  result->has_camera = false;
  return true;
}

}  // namespace relay
