#include "audio_mixer.h"

#include <algorithm>
#include <cstring>

namespace relay {

namespace {

float ClampSample(float value) {
  if (value > 1.0f) {
    return 1.0f;
  }
  if (value < -1.0f) {
    return -1.0f;
  }
  return value;
}

}  // namespace

void AudioResampler::Configure(uint32_t source_rate, uint32_t source_channels,
                               bool source_is_float, uint32_t bits_per_sample) {
  source_rate_ = source_rate == 0 ? kMixSampleRate : source_rate;
  source_channels_ = source_channels == 0 ? 1 : source_channels;
  source_is_float_ = source_is_float;
  bits_per_sample_ = bits_per_sample == 0 ? 32 : bits_per_sample;
  bytes_per_sample_ = bits_per_sample_ / 8;
  configured_ = true;
  Reset();
}

void AudioResampler::Reset() {
  position_ = 0.0;
  previous_left_ = 0.0f;
  previous_right_ = 0.0f;
  has_previous_ = false;
}

void AudioResampler::ReadSourceFrame(const uint8_t* data, size_t frame_index, float* left,
                                     float* right) const {
  const uint8_t* frame = data + frame_index * source_channels_ * bytes_per_sample_;
  float channels[2] = {0.0f, 0.0f};
  const uint32_t used = (std::min)(source_channels_, 2u);
  for (uint32_t channel = 0; channel < used; ++channel) {
    const uint8_t* sample = frame + channel * bytes_per_sample_;
    float value = 0.0f;
    if (source_is_float_ && bits_per_sample_ == 32) {
      float raw = 0.0f;
      std::memcpy(&raw, sample, sizeof(raw));
      value = raw;
    } else if (bits_per_sample_ == 16) {
      int16_t raw = 0;
      std::memcpy(&raw, sample, sizeof(raw));
      value = static_cast<float>(raw) / 32768.0f;
    } else if (bits_per_sample_ == 32) {
      int32_t raw = 0;
      std::memcpy(&raw, sample, sizeof(raw));
      value = static_cast<float>(raw) / 2147483648.0f;
    } else if (bits_per_sample_ == 24) {
      const int32_t raw = (static_cast<int32_t>(sample[2]) << 24 |
                           static_cast<int32_t>(sample[1]) << 16 |
                           static_cast<int32_t>(sample[0]) << 8) >>
                          8;
      value = static_cast<float>(raw) / 8388608.0f;
    }
    channels[channel] = value;
  }
  if (source_channels_ == 1) {
    // Mono microphones are the common case: the same signal in both ears.
    *left = channels[0];
    *right = channels[0];
    return;
  }
  *left = channels[0];
  *right = channels[1];
}

void AudioResampler::Process(const uint8_t* data, size_t frame_count,
                             std::vector<float>* out) {
  if (!configured_ || data == nullptr || frame_count == 0) {
    return;
  }
  if (source_rate_ == kMixSampleRate) {
    const size_t base = out->size();
    out->resize(base + frame_count * kMixChannels);
    for (size_t i = 0; i < frame_count; ++i) {
      float left = 0.0f;
      float right = 0.0f;
      ReadSourceFrame(data, i, &left, &right);
      (*out)[base + i * 2] = left;
      (*out)[base + i * 2 + 1] = right;
    }
    return;
  }

  const double step = static_cast<double>(source_rate_) / kMixSampleRate;
  if (!has_previous_) {
    ReadSourceFrame(data, 0, &previous_left_, &previous_right_);
    has_previous_ = true;
  }
  while (position_ < static_cast<double>(frame_count)) {
    const double index = position_;
    const size_t whole = static_cast<size_t>(index);
    const float fraction = static_cast<float>(index - whole);
    float left0 = previous_left_;
    float right0 = previous_right_;
    if (whole > 0) {
      ReadSourceFrame(data, whole - 1, &left0, &right0);
    }
    float left1 = 0.0f;
    float right1 = 0.0f;
    ReadSourceFrame(data, whole, &left1, &right1);
    out->push_back(left0 + (left1 - left0) * fraction);
    out->push_back(right0 + (right1 - right0) * fraction);
    position_ += step;
  }
  ReadSourceFrame(data, frame_count - 1, &previous_left_, &previous_right_);
  position_ -= static_cast<double>(frame_count);
  if (position_ < 0.0) {
    position_ = 0.0;
  }
}

AudioRingBuffer::AudioRingBuffer(size_t capacity_frames)
    : capacity_frames_(capacity_frames == 0 ? 1 : capacity_frames),
      samples_((capacity_frames == 0 ? 1 : capacity_frames) * kMixChannels, 0.0f) {}

void AudioRingBuffer::Reset() {
  std::lock_guard<std::mutex> lock(mutex_);
  std::fill(samples_.begin(), samples_.end(), 0.0f);
  write_end_ = 0;
  started_ = false;
}

void AudioRingBuffer::Write(int64_t start_frame, const float* interleaved_stereo,
                            size_t frames) {
  if (interleaved_stereo == nullptr || frames == 0 || start_frame < 0) {
    return;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  if (!started_) {
    started_ = true;
    write_end_ = start_frame;
  }

  int64_t frame = start_frame;
  size_t offset = 0;
  const int64_t floor_frame = write_end_ - static_cast<int64_t>(capacity_frames_);
  if (frame + static_cast<int64_t>(frames) <= floor_frame) {
    // Entirely older than the window the mixer can still read: drop, count.
    dropped_frames_.fetch_add(frames);
    return;
  }
  if (frame < floor_frame) {
    const size_t skipped = static_cast<size_t>(floor_frame - frame);
    dropped_frames_.fetch_add(skipped);
    offset = skipped;
    frame = floor_frame;
  }
  if (frame > write_end_) {
    // A gap: the endpoint delivered nothing for that interval. Zero it so the
    // mix keeps its position on the timeline instead of drifting.
    //
    // Only the newest capacity_frames_ slots are ever readable, so the fill
    // starts there: a silent endpoint can leave a gap of minutes, and zeroing
    // it frame by frame would hold the ring mutex for tens of millions of
    // iterations while the encode thread waits to mix.
    const int64_t oldest_readable = frame - static_cast<int64_t>(capacity_frames_);
    for (int64_t missing = (std::max)(write_end_, oldest_readable); missing < frame;
         ++missing) {
      const size_t slot =
          static_cast<size_t>(missing % static_cast<int64_t>(capacity_frames_)) *
          kMixChannels;
      samples_[slot] = 0.0f;
      samples_[slot + 1] = 0.0f;
    }
    discontinuities_.fetch_add(1);
    write_end_ = frame;
  }

  for (size_t i = offset; i < frames; ++i) {
    const int64_t target = start_frame + static_cast<int64_t>(i);
    if (target < write_end_) {
      // Overlapping re-delivery: the newest sample for a position wins.
      continue;
    }
    const size_t slot =
        static_cast<size_t>(target % static_cast<int64_t>(capacity_frames_)) *
        kMixChannels;
    samples_[slot] = interleaved_stereo[i * kMixChannels];
    samples_[slot + 1] = interleaved_stereo[i * kMixChannels + 1];
    write_end_ = target + 1;
  }
}

size_t AudioRingBuffer::Read(int64_t start_frame, size_t frames, float* out) const {
  if (out == nullptr || frames == 0) {
    return 0;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  const int64_t floor_frame = write_end_ - static_cast<int64_t>(capacity_frames_);
  size_t backed = 0;
  for (size_t i = 0; i < frames; ++i) {
    const int64_t frame = start_frame + static_cast<int64_t>(i);
    if (!started_ || frame < floor_frame || frame >= write_end_ || frame < 0) {
      out[i * kMixChannels] = 0.0f;
      out[i * kMixChannels + 1] = 0.0f;
      continue;
    }
    const size_t slot =
        static_cast<size_t>(frame % static_cast<int64_t>(capacity_frames_)) * kMixChannels;
    out[i * kMixChannels] = samples_[slot];
    out[i * kMixChannels + 1] = samples_[slot + 1];
    ++backed;
  }
  return backed;
}

int64_t AudioRingBuffer::write_end() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return write_end_;
}

AudioMixer::AudioMixer(AudioRingBuffer* microphone, AudioRingBuffer* system_audio)
    : microphone_(microphone), system_audio_(system_audio) {}

void AudioMixer::SetMicrophoneEnabled(bool enabled) {
  microphone_enabled_.store(enabled);
}

void AudioMixer::SetSystemAudioEnabled(bool enabled) {
  system_audio_enabled_.store(enabled);
}

void AudioMixer::Mix(int64_t start_frame, size_t frames, std::vector<float>* out) {
  out->assign(frames * kMixChannels, 0.0f);
  if (frames == 0) {
    return;
  }
  scratch_.resize(frames * kMixChannels);

  const bool take_microphone = microphone_ != nullptr && microphone_enabled_.load();
  const bool take_system = system_audio_ != nullptr && system_audio_enabled_.load();

  if (take_microphone) {
    microphone_->Read(start_frame, frames, scratch_.data());
    for (size_t i = 0; i < scratch_.size(); ++i) {
      (*out)[i] += scratch_[i];
    }
  }
  if (take_system) {
    system_audio_->Read(start_frame, frames, scratch_.data());
    for (size_t i = 0; i < scratch_.size(); ++i) {
      (*out)[i] += scratch_[i];
    }
  }
  if (take_microphone && take_system) {
    for (float& sample : *out) {
      sample = ClampSample(sample);
    }
  }
}

}  // namespace relay
