#include "recording_session.h"

#include <algorithm>
#include <chrono>

namespace relay {

namespace {

// 20 ms of audio per encoder write: small enough to interleave tightly with
// video, large enough to keep the sink writer call rate sane.
constexpr size_t kAudioBlockFrames = kMixSampleRate / 50;
// How far behind the session clock the audio drain may run when the endpoints
// deliver nothing: 200 ms of silence written late costs nothing, a track that
// stops advancing would desynchronize the file.
constexpr int64_t kAudioCaptureLagFrames = static_cast<int64_t>(kMixSampleRate) / 5;
constexpr int64_t kTickIntervalMs = 250;
constexpr int64_t kStatsEveryTicks = 4;

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

bool RecordingSession::has_camera_frames() const {
  return camera_frames_seen_.load();
}

double RecordingSession::camera_aspect_ratio() const {
  return camera_.aspect_ratio();
}

RectD RecordingSession::pip_rect() const {
  return compositor_.pip_rect();
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

  mixer_.SetMicrophoneEnabled(config.microphone_enabled);
  mixer_.SetSystemAudioEnabled(config.system_audio_enabled);
  microphone_ring_.Reset();
  system_audio_ring_.Reset();
  audio_position_frames_ = 0;
  composition_failures_.store(0);
  backpressure_drops_.store(0);
  fatal_error_.store(false);
  camera_frames_seen_.store(false);
  last_accepted_frame_100ns_.store(-1);
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
  const auto input_error = [this](const RecorderError& failure) {
    OnPipelineError(failure);
  };
  microphone_ = std::make_unique<AudioCapture>(AudioCapture::Kind::kMicrophone,
                                              &microphone_ring_, microphone_meter_);
  microphone_->SetDeviceId(config_.microphone_device_id);
  system_audio_ =
      std::make_unique<AudioCapture>(AudioCapture::Kind::kSystemAudio, &system_audio_ring_);
  system_audio_->SetDeviceId(config_.system_audio_device_id);
  std::string audio_error;
  if (!microphone_->Start(&clock_, input_error, &audio_error)) {
    RecorderError failure;
    failure.code = RecorderErrorCode::kMicrophoneUnavailable;
    failure.message = audio_error;
    failure.fatal = false;
    OnPipelineError(failure);
  }
  if (!system_audio_->Start(&clock_, input_error, &audio_error)) {
    RecorderError failure;
    failure.code = RecorderErrorCode::kSystemAudioUnavailable;
    failure.message = audio_error;
    failure.fatal = false;
    OnPipelineError(failure);
  }

  if (config_.camera_enabled) {
    std::string camera_error;
    camera_.SetDeviceId(config_.camera_device_id);
    if (!camera_.Start(
            capture_.device(), &compositor_,
            [this](const uint8_t* pixels, uint32_t width, uint32_t height,
                   uint32_t stride) {
              camera_frames_seen_.store(true);
              if (events_.on_camera_preview) {
                events_.on_camera_preview(pixels, width, height, stride);
              }
            },
            input_error, &camera_error)) {
      RecorderError failure;
      failure.code = RecorderErrorCode::kCameraUnavailable;
      failure.message = camera_error;
      failure.fatal = false;
      OnPipelineError(failure);
    }
  }

  SetState(SessionState::kRecording);
  EmitInputs();
  return true;
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
  // The stream keeps running; only its contribution to the mix changes, so the
  // toggle never restarts the session (spec 8).
  mixer_.SetMicrophoneEnabled(enabled);
  EmitInputs();
  return true;
}

bool RecordingSession::SetSystemAudioEnabled(bool enabled, RecorderError* /*error*/) {
  mixer_.SetSystemAudioEnabled(enabled);
  EmitInputs();
  return true;
}

bool RecordingSession::SetCameraEnabled(bool enabled, RecorderError* error) {
  compositor_.SetCameraEnabled(enabled);
  if (enabled && !camera_.running() && capture_.device() != nullptr) {
    std::string camera_error;
    camera_.SetDeviceId(config_.camera_device_id);
    if (!camera_.Start(
            capture_.device(), &compositor_,
            [this](const uint8_t* pixels, uint32_t width, uint32_t height,
                   uint32_t stride) {
              camera_frames_seen_.store(true);
              if (events_.on_camera_preview) {
                events_.on_camera_preview(pixels, width, height, stride);
              }
            },
            [this](const RecorderError& failure) { OnPipelineError(failure); },
            &camera_error)) {
      compositor_.SetCameraEnabled(false);
      error->code = RecorderErrorCode::kCameraUnavailable;
      error->message = camera_error;
      error->fatal = false;
      EmitInputs();
      return false;
    }
  } else if (!enabled && camera_.running()) {
    camera_.Stop();
    camera_frames_seen_.store(false);
  }
  EmitInputs();
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
  // The gate keeps a tolerance because the source ticks on its own vblank, not
  // on ours: two vblanks of a 60.1 Hz panel are 332,778 ticks, just short of
  // the 333,333 a 30 fps recording asks for. Without the tolerance that frame
  // is rejected and the next accepted one is three vblanks away, so the file
  // is encoded at 20 fps while everything downstream still claims 30.
  const int64_t minimum_interval =
      10000000LL / static_cast<int64_t>(config_.frame_rate == 0 ? 30 : config_.frame_rate);
  const int64_t accept_interval = minimum_interval - minimum_interval / 10;
  const int64_t previous = last_accepted_frame_100ns_.load();
  if (previous >= 0 && media_100ns - previous < accept_interval) {
    return;
  }

  // Composing hands out the next canvas of a fixed pool, so a frame that the
  // queue cannot take must be dropped before it is composed — otherwise the
  // blit lands in the canvas the encoder is still reading.
  if (video_queue_.full()) {
    backpressure_drops_.fetch_add(1);
    return;
  }
  last_accepted_frame_100ns_.store(media_100ns);

  QueuedFrame queued;
  std::string detail;
  if (!compositor_.Compose(frame.texture, frame.width, frame.height, &queued.canvas,
                           &detail)) {
    composition_failures_.fetch_add(1);
    RecorderError failure;
    failure.code = RecorderErrorCode::kCaptureFailed;
    failure.message = "A frame could not be composed.";
    failure.details = detail;
    failure.fatal = false;
    if (events_.on_error) {
      events_.on_error(failure);
    }
    return;
  }
  queued.timestamp_100ns = media_100ns;

  // No file I/O on this thread: the encoder thread owns the sink writer
  // (spec 22). This is the only producer and the queue had room a moment ago —
  // only Pop runs concurrently — so the push cannot displace a frame the
  // encoder still needs. A queue closed by a concurrent stop counts its own
  // drop.
  video_queue_.Push(std::move(queued));
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
    // track at the block rate. The ceiling is therefore what was actually
    // captured, with a bounded tolerance so two endpoints that deliver nothing
    // at all (a silent loopback, a microphone that failed to open) cannot stop
    // the audio track from advancing.
    const int64_t captured_frames =
        (std::max)(microphone_ring_.write_end(), system_audio_ring_.write_end());
    ceiling_frames = (std::min)(
        ceiling_frames,
        (std::max)(captured_frames, ceiling_frames - kAudioCaptureLagFrames));
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
  const int64_t frame_duration_100ns =
      10000000LL / static_cast<int64_t>(config_.frame_rate == 0 ? 30 : config_.frame_rate);
  while (encoding_.load()) {
    DrainAudio(false);
    QueuedFrame frame;
    if (!video_queue_.Pop(&frame, std::chrono::milliseconds(5))) {
      continue;
    }
    RecorderError error;
    if (!writer_.WriteVideoFrame(frame.canvas.get(), frame.timestamp_100ns,
                                 frame_duration_100ns, &error)) {
      OnPipelineError(error);
      return;  // stops encoding; the artefact is left for stop/abort to handle
    }
  }

  // Drain whatever the capture side already handed over before finalizing.
  QueuedFrame frame;
  while (video_queue_.TryPop(&frame)) {
    RecorderError error;
    if (!writer_.WriteVideoFrame(frame.canvas.get(), frame.timestamp_100ns,
                                 frame_duration_100ns, &error)) {
      break;
    }
  }
  DrainAudio(true);
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
                         backpressure_drops_.load();
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
  camera_.Stop();
  if (microphone_) {
    microphone_->Stop();
    microphone_.reset();
  }
  if (system_audio_) {
    system_audio_->Stop();
    system_audio_.reset();
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
  MediaProbe probe;
  if (!MediaWriter::Probe(artifact_path, &probe) || !probe.readable) {
    return false;
  }

  std::wstring recovered = artifact_path;
  const size_t dot = recovered.find_last_of(L'.');
  if (dot != std::wstring::npos) {
    recovered = recovered.substr(0, dot);
  }
  recovered += L".mp4";
  // Copy, never move: recovery must not consume the artefact it read (spec 18).
  if (::CopyFileW(artifact_path.c_str(), recovered.c_str(), FALSE) == FALSE &&
      ::GetLastError() != ERROR_FILE_EXISTS) {
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
