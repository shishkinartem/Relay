#ifndef RELAY_AUDIO_CAPTURE_H_
#define RELAY_AUDIO_CAPTURE_H_

#include <windows.h>

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <winrt/base.h>

#include <atomic>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include "audio_mixer.h"
#include "recorder_types.h"

namespace relay {

// WASAPI capture for one logical audio source.
//
// System audio is a loopback capture on the default render endpoint;
// the microphone is an event-driven capture on the default capture endpoint.
// The two stay separate until the mixer (spec 8, media-pipeline "Audio").
class AudioCapture {
 public:
  enum class Kind { kMicrophone, kSystemAudio };

  using ErrorHandler = std::function<void(const RecorderError&)>;

  AudioCapture(Kind kind, AudioRingBuffer* sink);
  ~AudioCapture();

  AudioCapture(const AudioCapture&) = delete;
  AudioCapture& operator=(const AudioCapture&) = delete;

  // `clock` places every packet on the session timeline; packets captured while
  // the session is paused are discarded rather than queued.
  bool Start(const SessionClock* clock, ErrorHandler on_error, std::string* error);

  // Idempotent.
  void Stop();

  bool running() const { return running_.load(); }
  Kind kind() const { return kind_; }

 private:
  void CaptureThread();
  bool OpenEndpoint(std::string* error);
  void CloseEndpoint();
  void ReportFailure(const std::string& message, HRESULT hr);

  const Kind kind_;
  AudioRingBuffer* const sink_;
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
};

}  // namespace relay

#endif  // RELAY_AUDIO_CAPTURE_H_
