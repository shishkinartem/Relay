#ifndef RELAY_AUDIO_MIXER_H_
#define RELAY_AUDIO_MIXER_H_

#include <atomic>
#include <cstdint>
#include <mutex>
#include <vector>

#include "recorder_types.h"

namespace relay {

// One mixed AAC track comes out of the session (spec 8), so both sources are
// normalized to this format before they ever meet.
constexpr uint32_t kMixSampleRate = 48000;
constexpr uint32_t kMixChannels = 2;

// Converts a WASAPI endpoint format into 48 kHz interleaved stereo float.
//
// Linear interpolation. Screen-recording audio is speech and UI sound at
// endpoint rates that are almost always already 48 kHz; a polyphase resampler
// would cost complexity for an inaudible difference on the rare 44.1 kHz
// endpoint. Revisit with measurements, not by assumption.
class AudioResampler {
 public:
  void Configure(uint32_t source_rate, uint32_t source_channels, bool source_is_float,
                 uint32_t bits_per_sample);
  void Reset();

  // Appends the converted frames to `out`.
  void Process(const uint8_t* data, size_t frame_count, std::vector<float>* out);

  bool configured() const { return configured_; }

 private:
  void ReadSourceFrame(const uint8_t* data, size_t frame_index, float* left,
                       float* right) const;

  uint32_t source_rate_ = kMixSampleRate;
  uint32_t source_channels_ = kMixChannels;
  bool source_is_float_ = true;
  uint32_t bytes_per_sample_ = 4;
  uint32_t bits_per_sample_ = 32;
  bool configured_ = false;

  double position_ = 0.0;
  float previous_left_ = 0.0f;
  float previous_right_ = 0.0f;
  bool has_previous_ = false;
};

// Ring buffer addressed by position on the session timeline.
//
// Capacity is fixed at construction. A writer that falls more than the capacity
// behind the newest sample has its packet dropped and the drop counter advanced
// — audio never grows without bound (spec 22). A reader asking for a range that
// was never written gets silence, which is what keeps a silent loopback stream
// from stalling the mix.
class AudioRingBuffer {
 public:
  explicit AudioRingBuffer(size_t capacity_frames);

  void Reset();
  void Write(int64_t start_frame, const float* interleaved_stereo, size_t frames);
  // Returns how many of the requested frames were backed by captured audio.
  size_t Read(int64_t start_frame, size_t frames, float* out) const;

  int64_t write_end() const;
  uint64_t dropped_frames() const { return dropped_frames_.load(); }
  uint64_t discontinuities() const { return discontinuities_.load(); }
  void NoteDiscontinuity() { discontinuities_.fetch_add(1); }

 private:
  const size_t capacity_frames_;
  mutable std::mutex mutex_;
  std::vector<float> samples_;  // interleaved stereo, capacity_frames_ * 2
  int64_t write_end_ = 0;
  bool started_ = false;
  std::atomic<uint64_t> dropped_frames_{0};
  std::atomic<uint64_t> discontinuities_{0};
};

// Sums microphone and system audio into the single output track.
//
// A disabled source stops contributing to the mix; its capture stream keeps
// running, so toggling never restarts a device mid-session (spec 8).
class AudioMixer {
 public:
  AudioMixer(AudioRingBuffer* microphone, AudioRingBuffer* system_audio);

  void SetMicrophoneEnabled(bool enabled);
  void SetSystemAudioEnabled(bool enabled);
  bool microphone_enabled() const { return microphone_enabled_.load(); }
  bool system_audio_enabled() const { return system_audio_enabled_.load(); }

  // Fills `out` with `frames` interleaved stereo frames starting at
  // `start_frame` on the session timeline.
  void Mix(int64_t start_frame, size_t frames, std::vector<float>* out);

 private:
  AudioRingBuffer* const microphone_;
  AudioRingBuffer* const system_audio_;
  std::atomic<bool> microphone_enabled_{true};
  std::atomic<bool> system_audio_enabled_{true};
  std::vector<float> scratch_;
};

}  // namespace relay

#endif  // RELAY_AUDIO_MIXER_H_
