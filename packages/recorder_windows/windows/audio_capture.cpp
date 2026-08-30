#include "audio_capture.h"

#include <avrt.h>
#include <mmreg.h>
#include <objbase.h>

#include <algorithm>
#include <utility>

namespace relay {

namespace {

// A loopback endpoint delivers nothing while the system is silent, so it is
// polled rather than waited on. 10 ms matches the default WASAPI period.
constexpr DWORD kLoopbackPollMs = 10;
constexpr DWORD kMicrophoneWaitMs = 200;
// 500 ms of endpoint buffer: enough to survive a scheduling hiccup, far too
// small to accumulate.
constexpr REFERENCE_TIME kBufferDuration = 5000000;

}  // namespace

bool WaveFormatIsFloat(const WAVEFORMATEX* format) {
  if (format == nullptr) {
    return false;
  }
  if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) {
    return true;
  }
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
      format->cbSize >= sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX)) {
    const auto* extensible = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT carries WAVE_FORMAT_IEEE_FLOAT in Data1;
    // comparing that avoids pulling in the kernel streaming headers.
    return extensible->SubFormat.Data1 == WAVE_FORMAT_IEEE_FLOAT;
  }
  return false;
}

AudioCapture::AudioCapture(Kind kind, AudioRingBuffer* sink, LevelAccumulator* meter)
    : kind_(kind), sink_(sink), meter_(meter) {}

AudioCapture::~AudioCapture() {
  Stop();
}

void AudioCapture::SetDeviceId(std::string id) {
  device_id_ = std::move(id);
}

bool AudioCapture::OpenEndpoint(std::string* error) {
  winrt::com_ptr<IMMDeviceEnumerator> enumerator;
  HRESULT hr = ::CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                  CLSCTX_INPROC_SERVER, __uuidof(IMMDeviceEnumerator),
                                  enumerator.put_void());
  if (FAILED(hr)) {
    *error = "The audio endpoint enumerator is unavailable (" + HResultToString(hr) + ").";
    return false;
  }
  const EDataFlow flow = kind_ == Kind::kSystemAudio ? eRender : eCapture;
  // A chosen endpoint that no longer resolves — unplugged between the last
  // enumeration and this recording — degrades to the default rather than
  // failing prepare: a wrong endpoint is a degraded recording, a refused
  // prepare is no recording at all (spec 33.2).
  bool fell_back = false;
  if (!device_id_.empty()) {
    DWORD state = 0;
    if (FAILED(enumerator->GetDevice(Widen(device_id_).c_str(), device_.put())) ||
        FAILED(device_->GetState(&state)) || state != DEVICE_STATE_ACTIVE) {
      device_ = nullptr;
      fell_back = true;
    }
  }
  if (!device_) {
    hr = enumerator->GetDefaultAudioEndpoint(flow, eConsole, device_.put());
    if (FAILED(hr)) {
      *error = kind_ == Kind::kSystemAudio
                   ? "No audio output device is available to record."
                   : "No microphone is available.";
      return false;
    }
  }
  if (fell_back) {
    ReportFallback();
  }
  hr = device_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, client_.put_void());
  if (FAILED(hr)) {
    *error = "The audio device could not be activated (" + HResultToString(hr) + ").";
    return false;
  }
  hr = client_->GetMixFormat(&mix_format_);
  if (FAILED(hr) || mix_format_ == nullptr) {
    *error = "The audio device format could not be read (" + HResultToString(hr) + ").";
    return false;
  }

  DWORD flags = 0;
  if (kind_ == Kind::kSystemAudio) {
    flags |= AUDCLNT_STREAMFLAGS_LOOPBACK;
  } else {
    flags |= AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
  }
  hr = client_->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, kBufferDuration, 0,
                           mix_format_, nullptr);
  if (FAILED(hr)) {
    *error = hr == E_ACCESSDENIED
                 ? "Microphone access is blocked by Windows privacy settings."
                 : "The audio stream could not be opened (" + HResultToString(hr) + ").";
    return false;
  }
  if (kind_ == Kind::kMicrophone) {
    ready_event_ = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (ready_event_ == nullptr || FAILED(client_->SetEventHandle(ready_event_))) {
      *error = "The microphone stream could not be armed.";
      return false;
    }
  }
  hr = client_->GetService(__uuidof(IAudioCaptureClient), capture_.put_void());
  if (FAILED(hr)) {
    *error = "The audio capture client is unavailable (" + HResultToString(hr) + ").";
    return false;
  }

  resampler_.Configure(mix_format_->nSamplesPerSec, mix_format_->nChannels,
                       WaveFormatIsFloat(mix_format_), mix_format_->wBitsPerSample);
  return true;
}

void AudioCapture::CloseEndpoint() {
  if (client_) {
    client_->Stop();
  }
  capture_ = nullptr;
  client_ = nullptr;
  device_ = nullptr;
  if (mix_format_ != nullptr) {
    ::CoTaskMemFree(mix_format_);
    mix_format_ = nullptr;
  }
  if (ready_event_ != nullptr) {
    ::CloseHandle(ready_event_);
    ready_event_ = nullptr;
  }
}

bool AudioCapture::Start(const SessionClock* clock, ErrorHandler on_error,
                         std::string* error) {
  if (running_.load()) {
    return true;
  }
  clock_ = clock;
  on_error_ = std::move(on_error);
  stop_event_ = ::CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (stop_event_ == nullptr) {
    *error = "The audio capture thread could not be created.";
    return false;
  }
  running_.store(true);
  thread_ = std::thread(&AudioCapture::CaptureThread, this);
  return true;
}

void AudioCapture::Stop() {
  if (stop_event_ != nullptr) {
    ::SetEvent(stop_event_);
  }
  running_.store(false);
  if (thread_.joinable()) {
    thread_.join();
  }
  if (stop_event_ != nullptr) {
    ::CloseHandle(stop_event_);
    stop_event_ = nullptr;
  }
}

void AudioCapture::ReportFailure(const std::string& message, HRESULT hr) {
  if (!on_error_) {
    return;
  }
  RecorderError error;
  error.code = kind_ == Kind::kSystemAudio ? RecorderErrorCode::kSystemAudioUnavailable
                                           : RecorderErrorCode::kMicrophoneUnavailable;
  error.message = message;
  error.details = HResultToString(hr);
  // An optional input dropping out degrades the session; the video track and
  // the file are untouched (spec 19, 23).
  error.fatal = false;
  on_error_(error);
}

void AudioCapture::ReportFallback() {
  if (!on_error_) {
    return;
  }
  RecorderError error;
  error.code = kind_ == Kind::kSystemAudio ? RecorderErrorCode::kSystemAudioUnavailable
                                           : RecorderErrorCode::kMicrophoneUnavailable;
  error.message = kind_ == Kind::kSystemAudio
                      ? "The chosen audio output is no longer available. Recording "
                        "the system default instead."
                      : "The chosen microphone is no longer available. Recording the "
                        "system default instead.";
  error.details = device_id_;
  // The recording continues on the default device: this degrades the session,
  // it never ends it (spec 19, 23).
  error.fatal = false;
  on_error_(error);
}

void AudioCapture::CaptureThread() {
  const HRESULT com = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  DWORD task_index = 0;
  const HANDLE task = ::AvSetMmThreadCharacteristicsW(L"Audio", &task_index);

  std::string error;
  if (!OpenEndpoint(&error)) {
    ReportFailure(error, E_FAIL);
  } else {
    const HRESULT hr = client_->Start();
    if (FAILED(hr)) {
      ReportFailure("The audio stream could not be started.", hr);
    } else {
      if (meter_ != nullptr) {
        // This capture owns the device from here until the loop exits, so the
        // meter reads its levels instead of opening a handle of its own
        // (spec 33.2). Claimed only once the stream is actually running: a
        // capture that never opened must not stand between the meter and its
        // own endpoint tap.
        meter_->SetLive(true);
      }
      while (running_.load()) {
        const HANDLE wait_handle =
            kind_ == Kind::kMicrophone && ready_event_ != nullptr ? ready_event_ : nullptr;
        if (wait_handle != nullptr) {
          const HANDLE handles[2] = {stop_event_, wait_handle};
          const DWORD wait =
              ::WaitForMultipleObjects(2, handles, FALSE, kMicrophoneWaitMs);
          if (wait == WAIT_OBJECT_0) {
            break;
          }
        } else if (::WaitForSingleObject(stop_event_, kLoopbackPollMs) == WAIT_OBJECT_0) {
          break;
        }

        for (;;) {
          UINT32 packet_frames = 0;
          HRESULT packet_hr = capture_->GetNextPacketSize(&packet_frames);
          if (FAILED(packet_hr)) {
            ReportFailure("The audio device stopped delivering data.", packet_hr);
            running_.store(false);
            break;
          }
          if (packet_frames == 0) {
            break;
          }

          BYTE* data = nullptr;
          UINT32 frames = 0;
          DWORD flags = 0;
          UINT64 device_position = 0;
          UINT64 qpc_position = 0;
          packet_hr = capture_->GetBuffer(&data, &frames, &flags, &device_position,
                                          &qpc_position);
          if (FAILED(packet_hr)) {
            ReportFailure("An audio buffer could not be read.", packet_hr);
            running_.store(false);
            break;
          }
          if ((flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY) != 0 && sink_ != nullptr) {
            sink_->NoteDiscontinuity();
          }

          // qpcPosition is 100 ns since boot — the same monotonic base as the
          // capture frame timestamps, so audio and video land on one timeline.
          const int64_t media_100ns =
              clock_ != nullptr ? clock_->MediaTime100ns(static_cast<int64_t>(qpc_position))
                                : -1;
          const bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
          const bool writing =
              media_100ns >= 0 && !silent && data != nullptr && sink_ != nullptr;
          // The meter is fed from the packets this capture already reads, so a
          // level never costs a second handle on this device (spec 33.2), and
          // none of this arithmetic happens at all while nothing is metering.
          //
          // A packet that arrives while the session is paused is metered but
          // not written: the bar keeps showing what the microphone hears even
          // though none of it is being recorded. That is this platform's answer
          // to the open point in the channel contract, and macOS is free to
          // answer differently until the specification decides.
          const bool metering = meter_ != nullptr && meter_->enabled();
          if (writing || (metering && !silent && data != nullptr)) {
            converted_.clear();
            resampler_.Process(data, frames, &converted_);
            if (metering) {
              meter_->Add(converted_.data(), converted_.size());
            }
            const size_t converted_frames = converted_.size() / kMixChannels;
            if (writing && converted_frames > 0) {
              const int64_t start_frame =
                  (media_100ns * static_cast<int64_t>(kMixSampleRate)) / 10000000LL;
              sink_->Write(start_frame, converted_.data(), converted_frames);
            }
          } else if (metering) {
            // A silent packet is a level of zero, not the absence of one: a
            // bar that stops updating reads as frozen rather than as quiet.
            meter_->Add(nullptr, static_cast<size_t>(frames) * kMixChannels);
          }
          capture_->ReleaseBuffer(frames);
        }
      }
    }
  }

  if (meter_ != nullptr) {
    // Released before the endpoint is, on every exit path — including the ones
    // that never claimed it, where this is a no-op.
    meter_->SetLive(false);
  }
  CloseEndpoint();
  if (task != nullptr) {
    ::AvRevertMmThreadCharacteristics(task);
  }
  if (SUCCEEDED(com)) {
    ::CoUninitialize();
  }
}

}  // namespace relay
