#ifndef RELAY_AUDIO_CAPTURE_H_
#define RELAY_AUDIO_CAPTURE_H_

#include <windows.h>

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <winrt/base.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "audio_mixer.h"
#include "recorder_types.h"

namespace relay {

// True when `format` carries IEEE float samples, which is what a shared-mode
// endpoint hands out on almost every machine. Named rather than local because
// the input meter's own tap converts its packets through the same resampler
// this capture does, and a second copy of this test is a second answer
// (input_devices.cpp).
bool WaveFormatIsFloat(const WAVEFORMATEX* format);

// WASAPI capture for one logical audio source.
//
// System audio is a loopback capture on the default render endpoint;
// the microphone is an event-driven capture on the default capture endpoint.
// The two stay separate until the mixer (spec 8, media-pipeline "Audio").
class AudioCapture {
 public:
  enum class Kind { kMicrophone, kSystemAudio };

  using ErrorHandler = std::function<void(const RecorderError&)>;

  // `meter` is the level accumulator the plugin's input meter drains while a
  // recording is under way, so a level never costs a second handle on a device
  // this capture already holds (spec 33.2). Null for a capture nothing meters.
  AudioCapture(Kind kind, AudioRingBuffer* sink, LevelAccumulator* meter = nullptr);
  ~AudioCapture();

  AudioCapture(const AudioCapture&) = delete;
  AudioCapture& operator=(const AudioCapture&) = delete;

  // `clock` places every packet on the session timeline; packets captured while
  // the session is paused are discarded rather than queued.
  bool Start(const SessionClock* clock, ErrorHandler on_error, std::string* error);

  // Waits for the capture thread to settle on whether it has a running stream,
  // and reports what it settled on. False on a timeout as well as on a failure.
  //
  // Start() returns as soon as the thread exists, so a swap that must leave the
  // previous endpoint running until the new one is really open has no other way
  // to know (spec 33.2). Safe to call more than once.
  bool WaitUntilOpen(std::chrono::milliseconds timeout);

  // Idempotent.
  void Stop();

  // The endpoint to open, or empty for the platform's own default — which is
  // exactly what this capture opened before device selection existed. Set
  // before Start; an id that no longer resolves falls back to the default and
  // reports a non-fatal error rather than failing the recording (spec 33.2).
  void SetDeviceId(std::string id);

  bool running() const { return running_.load(); }
  Kind kind() const { return kind_; }

 private:
  void CaptureThread();
  bool OpenEndpoint(std::string* error);
  void CloseEndpoint();
  void ReportFailure(const std::string& message, HRESULT hr);
  void ReportFallback();
  // Releases whoever is waiting in WaitUntilOpen with the answer.
  void SettleOpen(bool opened);

  const Kind kind_;
  AudioRingBuffer* const sink_;
  LevelAccumulator* const meter_;
  std::string device_id_;
  const SessionClock* clock_ = nullptr;
  ErrorHandler on_error_;

  winrt::com_ptr<IMMDevice> device_;
  winrt::com_ptr<IAudioClient> client_;
  winrt::com_ptr<IAudioCaptureClient> capture_;
  WAVEFORMATEX* mix_format_ = nullptr;  // CoTaskMemFree owned by this object
  AudioResampler resampler_;
  std::vector<float> converted_;

  HANDLE ready_event_ = nullptr;
  HANDLE stop_event_ = nullptr;
  std::thread thread_;
  std::atomic<bool> running_{false};

  // Whether the capture thread has decided it has a running stream, and what it
  // decided. Written once per run by that thread, read by whoever is waiting on
  // the handshake above.
  std::mutex open_mutex_;
  std::condition_variable open_cv_;
  bool open_settled_ = false;
  bool opened_ = false;
};

}  // namespace relay

#endif  // RELAY_AUDIO_CAPTURE_H_
