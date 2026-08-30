#ifndef RELAY_RECORDING_SESSION_H_
#define RELAY_RECORDING_SESSION_H_

#include <windows.h>
#include <winrt/base.h>

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "audio_capture.h"
#include "audio_mixer.h"
#include "camera_capture.h"
#include "capture_engine.h"
#include "media_writer.h"
#include "recorder_types.h"
#include "video_compositor.h"

namespace relay {

struct SessionStats {
  uint64_t captured_frames = 0;
  uint64_t encoded_frames = 0;
  uint64_t dropped_frames = 0;
  uint64_t audio_discontinuities = 0;
  double av_drift_ms = 0;
  std::string encoder_name;
  bool hardware_encoding = false;
};

// The contract's recording-file map, before marshalling.
struct RecordingResult {
  std::wstring path;
  std::string recording_id;
  uint64_t size_bytes = 0;
  int64_t duration_ms = 0;
  int64_t created_at_ms = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t frame_rate = 0;
  bool has_audio = true;
  bool has_camera = false;
};

// Callbacks are raised from capture, encode and timer threads. The plugin
// marshals them onto the Flutter platform thread; nothing here touches a
// channel.
struct SessionEvents {
  std::function<void(SessionState)> on_state;
  std::function<void(int64_t elapsed_ms)> on_tick;
  std::function<void(const SessionStats&)> on_stats;
  std::function<void(bool microphone, bool camera, bool system_audio)> on_inputs;
  std::function<void(const RecorderError&)> on_error;
  std::function<void(const uint8_t* bgra, uint32_t width, uint32_t height,
                     uint32_t stride)>
      on_camera_preview;
};

// Owns the capture/composite/encode pipeline and the session state machine
// (spec 19, 20).
//
// State: idle -> preparing -> prepared -> recording <-> paused -> stopping ->
// finalizing -> finalized, with failed reachable from anywhere. Stop() and
// Abort() are idempotent, so a double click or a repeated native callback
// cannot corrupt the output (recording.md "Idempotency/race safety").
class RecordingSession {
 public:
  explicit RecordingSession(SessionEvents events);
  ~RecordingSession();

  RecordingSession(const RecordingSession&) = delete;
  RecordingSession& operator=(const RecordingSession&) = delete;

  // Windows this process must keep out of the capture. Verified — and repaired
  // — before capture starts, because with a display source the display
  // affinity is the only thing keeping the overlays out of the file (spec 6).
  void SetExcludedWindows(std::vector<HWND> windows);

  // The accumulator the plugin's input meter drains. Owned by the plugin,
  // which outlives every session, and filled only while the microphone capture
  // is running: the meter reads the live level from here rather than opening a
  // second handle on a microphone this session already holds (spec 33.2). Set
  // before Prepare.
  void SetMicrophoneLevelMeter(LevelAccumulator* meter);

  bool Prepare(const RecordingConfig& config, RecorderError* error);
  bool Start(RecorderError* error);
  bool Pause(RecorderError* error);
  bool Resume(RecorderError* error);
  bool Stop(RecordingResult* result, RecorderError* error);
  void Abort();

  bool SetMicrophoneEnabled(bool enabled, RecorderError* error);
  bool SetCameraEnabled(bool enabled, RecorderError* error);
  bool SetSystemAudioEnabled(bool enabled, RecorderError* error);

  // Re-points the tile mid-session (spec 33.5). Applied between frames, for the
  // next frame; the encoder canvas never changes, so the file keeps one
  // continuous video track (spec 11).
  void SetCameraOverlay(const CameraOverlayConfig& camera);

  // Swaps the device one input is using, without restarting the session
  // (spec 33.2).
  //
  // The new device is opened, and only once it is really open is the old one
  // closed — so a device that will not open leaves the previous one running and
  // is reported as a non-fatal error rather than costing the user their audio
  // or their camera. `device_id` empty is the platform default. Answering false
  // never ends the recording.
  //
  // Blocks for as long as the new device takes to open, so it belongs on the
  // plugin's serial worker rather than on the thread drawing the UI.
  bool SelectInputDevice(MediaDeviceKind kind, const std::string& device_id,
                         RecorderError* error);

  SessionState state() const;
  bool has_camera_frames() const;
  double camera_aspect_ratio() const;
  uint32_t camera_frame_width() const;
  uint32_t camera_frame_height() const;
  uint32_t canvas_width() const;
  uint32_t canvas_height() const;
  RectD pip_rect() const;
  // What the compositor will draw the tile as, for the camera it currently
  // holds. The preview window's frame, crop and mask all come from here, which
  // is what keeps it the same object as the tile (design 1p).
  PipDraw camera_pip_draw() const;

  // Finalizes an orphaned `.part` artefact into a playable file. Returns false
  // when nothing recoverable is in it. Never deletes the artefact (spec 18).
  static bool RecoverArtifact(const std::wstring& artifact_path, RecordingResult* result);

 private:
  struct QueuedFrame {
    winrt::com_ptr<ID3D11Texture2D> canvas;
    int64_t timestamp_100ns = 0;
  };

  void SetState(SessionState state);
  void OnCapturedFrame(const CaptureEngine::Frame& frame);
  void OnPipelineError(const RecorderError& error);
  // Starts a camera on `device_id`, wired to this session's compositor and
  // preview. Shared by prepare-time start, the runtime toggle and the swap, so
  // all three open a camera the same way.
  std::unique_ptr<CameraCapture> StartCamera(const std::string& device_id,
                                             std::string* error);
  bool SwapCamera(const std::string& device_id, RecorderError* error);
  bool SwapAudio(MediaDeviceKind kind, const std::string& device_id,
                 RecorderError* error);
  void EncodeLoop();
  void TimerLoop();
  void DrainAudio(bool flush);
  void StopInputs();
  void HoldSystemAwake(bool hold);
  void SystemAwakeLoop();
  void EmitInputs();
  SessionStats CollectStats() const;

  SessionEvents events_;
  RecordingConfig config_;

  mutable std::mutex mutex_;
  // Serializes the whole stop/abort teardown sequence — the thread joins *and*
  // the MediaWriter call that follows them. Both can arrive from different
  // threads: joining one std::thread twice is undefined, and an abort that
  // reached `writer_.Abort()` while a stop was inside `writer_.Finalize()`
  // would close the sink writer under a finish that has not renamed
  // `recording-<id>.part` yet, stranding the recording (spec 18).
  std::mutex teardown_mutex_;
  SessionState state_ = SessionState::kIdle;
  RecordingResult result_;
  bool result_ready_ = false;
  std::vector<HWND> excluded_windows_;

  SessionClock clock_;
  CaptureEngine capture_;
  VideoCompositor compositor_;
  // Held by pointer, not by value, because a swap opens the replacement before
  // it closes the incumbent: for a moment two captures exist, both feeding the
  // compositor's latest-wins slot, and the loser is destroyed when the swap
  // returns (spec 33.2). Null whenever no camera is running.
  //
  // Guarded by its own mutex rather than by `mutex_`: it is written on the
  // serial worker (a swap) and read on the platform thread (the preview's
  // geometry), and `mutex_` is held across state callbacks that reach both.
  // Never held while a capture is stopped — that joins a thread which can be
  // inside a preview or error callback of its own.
  mutable std::mutex camera_mutex_;
  std::unique_ptr<CameraCapture> camera_;

  // What the live capture is using now, which is not the same thing as what the
  // session was prepared with: a swap changes it (spec 33.2). Its own lock
  // because the serial worker writes it during a swap while the platform thread
  // reads it to restart a camera that was toggled off and on.
  mutable std::mutex devices_mutex_;
  std::string live_camera_device_id_;
  std::string live_microphone_device_id_;
  std::string live_system_audio_device_id_;

  // The device `kind` is capturing from, empty for the platform default.
  std::string LiveDeviceId(MediaDeviceKind kind) const;
  void SetLiveDeviceId(MediaDeviceKind kind, const std::string& device_id);
  MediaWriter writer_;

  // 3 s per source at 48 kHz stereo (~1.1 MB each): long enough to absorb an
  // encoder stall, short enough that memory cannot creep.
  static constexpr size_t kAudioRingFrames = kMixSampleRate * 3;
  AudioRingBuffer microphone_ring_{kAudioRingFrames};
  AudioRingBuffer system_audio_ring_{kAudioRingFrames};
  AudioMixer mixer_{&microphone_ring_, &system_audio_ring_};
  std::unique_ptr<AudioCapture> microphone_;
  LevelAccumulator* microphone_meter_ = nullptr;
  std::unique_ptr<AudioCapture> system_audio_;

  // Composed frames waiting for the encoder. Capacity 2, and a frame arriving
  // at a full queue is dropped *before* it is composed: composing hands out
  // the next canvas of the compositor's 3-texture pool, so 2 queued + 1 being
  // encoded already accounts for the whole pool and one more compose would
  // blit into the canvas the encoder is reading. Drops are counted and
  // reported as droppedFrames (spec 22).
  static constexpr size_t kVideoQueueCapacity = 2;
  BoundedQueue<QueuedFrame> video_queue_{kVideoQueueCapacity};
  std::atomic<uint64_t> backpressure_drops_{0};

  std::thread encode_thread_;
  std::thread timer_thread_;
  std::atomic<bool> encoding_{false};
  std::atomic<bool> timers_{false};

  // The idle-sleep hold, on a thread of its own because the state it sets is
  // per-thread and the callers are not one thread (HoldSystemAwake).
  // `awake_held_` is what the session wants and `awake_taken_` is what that
  // thread has done about it; `awake_thread_` is joinable exactly while
  // `awake_held_` is true. All three are read and written only under
  // `awake_mutex_`.
  std::mutex awake_mutex_;
  std::condition_variable awake_cv_;
  std::thread awake_thread_;
  bool awake_held_ = false;
  bool awake_taken_ = false;

  std::atomic<bool> aborted_{false};
  std::atomic<bool> fatal_error_{false};
  std::atomic<uint64_t> composition_failures_{0};
  std::atomic<bool> camera_frames_seen_{false};
  std::atomic<int64_t> last_accepted_frame_100ns_{-1};

  int64_t audio_position_frames_ = 0;
  std::vector<float> audio_block_;
};

}  // namespace relay

#endif  // RELAY_RECORDING_SESSION_H_
