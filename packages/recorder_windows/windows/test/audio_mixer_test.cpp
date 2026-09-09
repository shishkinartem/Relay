// The audio half of the pure recorder logic.
//
// These functions decide where a captured packet lands on the session timeline
// and how far the encoder may run ahead of the endpoints feeding it. They are
// pure arithmetic over two clocks that never agree, which is exactly the kind
// of code that looks obviously right and is not: the first real Windows
// recording came back with a microphone track that scraped continuously, and
// both causes were here. Neither was reachable by any suite, because this
// translation unit was not compiled into one.

#include <gtest/gtest.h>

#include <cstdint>
#include <vector>

#include "audio_mixer.h"

namespace relay {
namespace {

constexpr int64_t kSecond = static_cast<int64_t>(kMixSampleRate);
constexpr int64_t kLatency = kSecond / 4;   // the drain's margin, 250 ms
constexpr int64_t kMaxLag = kSecond / 2;    // the floor under a dead endpoint
constexpr size_t kRingFrames = kMixSampleRate * 4;

// A block of `frames` stereo frames, every sample set to `value`, so a test can
// assert which packet a position was filled from.
std::vector<float> Block(size_t frames, float value) {
  return std::vector<float>(frames * kMixChannels, value);
}

// ── the drain ceiling ────────────────────────────────────────────────────────

TEST(AudioDrainCeiling, TheSlowestEndpointDecidesHowFarTheTrackMayBeEncoded) {
  // The regression. The microphone is a tenth of a second behind the loopback,
  // as two endpoints on two clocks always are. Encoding to the *fastest* head
  // reads the microphone past its own write end, and every frame of that
  // overshoot becomes a zero the real samples can never replace.
  // `now` is the instant the fastest head was just timestamped at: both
  // endpoints are healthy, so the floor is not what decides this.
  const int64_t heads[] = {10 * kSecond, 10 * kSecond + kSecond / 10};
  EXPECT_EQ(AudioDrainCeilingFrames(10 * kSecond + kSecond / 10, heads, 2, kLatency,
                                    kMaxLag),
            10 * kSecond - kLatency);
}

TEST(AudioDrainCeiling, TheMarginIsKeptBehindThatHead) {
  // A single endpoint, delivering right now. The margin is the whole rule here;
  // the floor sits further back and never binds.
  const int64_t heads[] = {10 * kSecond};
  EXPECT_EQ(AudioDrainCeilingFrames(10 * kSecond, heads, 1, kLatency, kMaxLag),
            10 * kSecond - kLatency);
}

TEST(AudioDrainCeiling, AnEndpointThatNeverDeliveredDoesNotStallTheTrack) {
  // A microphone that failed to open contributes no head at all: the caller
  // leaves it out of the array, and the track still advances on the floor.
  EXPECT_EQ(AudioDrainCeilingFrames(20 * kSecond, nullptr, 0, kLatency, kMaxLag),
            20 * kSecond - kMaxLag);
}

TEST(AudioDrainCeiling, AnEndpointThatStalledAfterStartingIsBoundedByTheFloor) {
  // It delivered once and then stopped ten seconds ago. Waiting for it would
  // stop the audio track and desynchronize the file, so the floor wins.
  const int64_t heads[] = {10 * kSecond};
  EXPECT_EQ(AudioDrainCeilingFrames(20 * kSecond, heads, 1, kLatency, kMaxLag),
            20 * kSecond - kMaxLag);
}

TEST(AudioDrainCeiling, TheCeilingNeverRunsPastTheCurrentInstant) {
  // A loopback endpoint timestamps packets at the engine's mix instant, which
  // is ahead of now. The track must not be encoded into the future.
  const int64_t heads[] = {20 * kSecond + kSecond};
  EXPECT_EQ(AudioDrainCeilingFrames(20 * kSecond, heads, 1, kLatency, kMaxLag),
            20 * kSecond);
}

TEST(AudioDrainCeiling, TheCeilingIsNeverNegativeAtTheStartOfASession) {
  // The first tick arrives before max_lag has elapsed at all.
  EXPECT_EQ(AudioDrainCeilingFrames(0, nullptr, 0, kLatency, kMaxLag), 0);
}

TEST(AudioDrainCeiling, TheFloorIsLooserThanTheMarginSoItIsNotTheBindingRule) {
  // A property of the two constants rather than of one call: if the floor were
  // tighter than the margin, a perfectly healthy endpoint would be overrun on
  // every tick and the holes would be back. Checked here because the constants
  // are chosen in recording_session.cpp and nothing else compares them.
  EXPECT_GT(kMaxLag, kLatency);
}

// ── the ring buffer ──────────────────────────────────────────────────────────

TEST(AudioRingBuffer, ConsecutivePacketsLeaveNoSeamWhenTheTimestampJittersLate) {
  // The packet says it starts two frames after the previous one ended. Believed
  // literally, that is a two-frame hole zeroed into the seam — one click, on
  // every packet, a hundred times a second.
  AudioRingBuffer ring(kRingFrames);
  const std::vector<float> first = Block(480, 0.5f);
  const std::vector<float> second = Block(480, 0.25f);
  ring.Write(1000, first.data(), 480);
  ring.Write(1000 + 480 + 2, second.data(), 480);

  std::vector<float> out(4 * kMixChannels, -1.0f);
  ASSERT_EQ(ring.Read(1000 + 478, 4, out.data()), 4u);
  EXPECT_FLOAT_EQ(out[0], 0.5f);
  EXPECT_FLOAT_EQ(out[2], 0.5f);
  EXPECT_FLOAT_EQ(out[4], 0.25f);  // no silence between the two packets
  EXPECT_FLOAT_EQ(out[6], 0.25f);
  EXPECT_EQ(ring.discontinuities(), 0u);
}

TEST(AudioRingBuffer, ConsecutivePacketsKeepTheirWholeLengthWhenItJittersEarly) {
  // The mirror image: a packet that claims to start two frames before the
  // previous one ended used to have that overlap silently discarded.
  AudioRingBuffer ring(kRingFrames);
  const std::vector<float> first = Block(480, 0.5f);
  const std::vector<float> second = Block(480, 0.25f);
  ring.Write(1000, first.data(), 480);
  ring.Write(1000 + 480 - 2, second.data(), 480);

  EXPECT_EQ(ring.write_end(), 1000 + 960);
  EXPECT_EQ(ring.dropped_frames(), 0u);
  EXPECT_EQ(ring.discontinuities(), 0u);
}

TEST(AudioRingBuffer, ARealGapIsStillZeroedAndStillCounted) {
  // Beyond the snap window the timestamp is telling the truth: the endpoint
  // genuinely delivered nothing for that interval, and the mix must keep its
  // position rather than slide the recording earlier.
  AudioRingBuffer ring(kRingFrames);
  const std::vector<float> block = Block(480, 0.5f);
  ring.Write(1000, block.data(), 480);
  ring.Write(1000 + 480 + kSecond / 10, block.data(), 480);

  EXPECT_EQ(ring.discontinuities(), 1u);
  EXPECT_EQ(ring.write_end(), 1000 + 480 + kSecond / 10 + 480);
}

TEST(AudioRingBuffer, SnappingNeverMovesAPacketPastTheSnapWindow) {
  // The window is what bounds the correction: a packet a full second late is
  // written where it says it is, not dragged onto the cursor.
  AudioRingBuffer ring(kRingFrames);
  const std::vector<float> block = Block(480, 0.5f);
  ring.Write(0, block.data(), 480);
  ring.Write(480 + kRingWriteSnapFrames + 1, block.data(), 480);

  EXPECT_EQ(ring.write_end(), 480 + kRingWriteSnapFrames + 1 + 480);
}

TEST(AudioRingBuffer, NothingIsStartedBeforeTheFirstPacket) {
  AudioRingBuffer ring(kRingFrames);
  EXPECT_FALSE(ring.started());
  const std::vector<float> block = Block(480, 0.5f);
  ring.Write(1000, block.data(), 480);
  EXPECT_TRUE(ring.started());
}

TEST(AudioRingBuffer, ReadingBeforeTheFirstPacketIsSilenceNotGarbage) {
  AudioRingBuffer ring(kRingFrames);
  std::vector<float> out(4 * kMixChannels, -1.0f);
  EXPECT_EQ(ring.Read(0, 4, out.data()), 0u);
  for (const float sample : out) {
    EXPECT_FLOAT_EQ(sample, 0.0f);
  }
}

TEST(AudioRingBuffer, APacketOlderThanTheWindowIsDroppedAndCounted) {
  // The bound that keeps audio from growing without end (spec 22).
  AudioRingBuffer ring(480);
  const std::vector<float> block = Block(480, 0.5f);
  ring.Write(100000, block.data(), 480);
  ring.Write(0, block.data(), 480);
  EXPECT_EQ(ring.dropped_frames(), 480u);
}

// ── the mixer ────────────────────────────────────────────────────────────────

TEST(AudioMixer, TheSumOfTwoSourcesIsClamped) {
  // Both endpoints loud at once must not wrap round into a scream.
  AudioRingBuffer microphone(kRingFrames);
  AudioRingBuffer system_audio(kRingFrames);
  const std::vector<float> loud = Block(480, 0.9f);
  microphone.Write(0, loud.data(), 480);
  system_audio.Write(0, loud.data(), 480);

  AudioMixer mixer(&microphone, &system_audio);
  std::vector<float> out;
  mixer.Mix(0, 480, &out);
  for (const float sample : out) {
    EXPECT_LE(sample, 1.0f);
    EXPECT_FLOAT_EQ(sample, 1.0f);
  }
}

TEST(AudioMixer, ADisabledSourceContributesNothing) {
  AudioRingBuffer microphone(kRingFrames);
  AudioRingBuffer system_audio(kRingFrames);
  const std::vector<float> block = Block(480, 0.5f);
  microphone.Write(0, block.data(), 480);
  system_audio.Write(0, block.data(), 480);

  AudioMixer mixer(&microphone, &system_audio);
  mixer.SetSystemAudioEnabled(false);
  std::vector<float> out;
  mixer.Mix(0, 480, &out);
  EXPECT_FLOAT_EQ(out[0], 0.5f);
}

// ── the resampler ────────────────────────────────────────────────────────────

TEST(AudioResampler, AnEndpointAlreadyAtTheMixRateIsPassedThroughUntouched) {
  // The common case on both platforms, and the one where any arithmetic at all
  // would be a signal the file did not need.
  AudioResampler resampler;
  resampler.Configure(kMixSampleRate, 2, /*source_is_float=*/true, 32);
  const std::vector<float> input = Block(4, 0.5f);
  std::vector<float> out;
  resampler.Process(reinterpret_cast<const uint8_t*>(input.data()), 4, &out);

  ASSERT_EQ(out.size(), 4u * kMixChannels);
  for (const float sample : out) {
    EXPECT_FLOAT_EQ(sample, 0.5f);
  }
}

TEST(AudioResampler, AMonoEndpointIsPutInBothEars) {
  AudioResampler resampler;
  resampler.Configure(kMixSampleRate, 1, /*source_is_float=*/true, 32);
  const std::vector<float> input = {0.25f, 0.5f};
  std::vector<float> out;
  resampler.Process(reinterpret_cast<const uint8_t*>(input.data()), 2, &out);

  ASSERT_EQ(out.size(), 2u * kMixChannels);
  EXPECT_FLOAT_EQ(out[0], 0.25f);
  EXPECT_FLOAT_EQ(out[1], 0.25f);
  EXPECT_FLOAT_EQ(out[2], 0.5f);
  EXPECT_FLOAT_EQ(out[3], 0.5f);
}

TEST(AudioResampler, SixteenBitIntegerSamplesLandOnTheFullFloatRange) {
  // Reading a 16-bit endpoint as anything else is the classic source of harsh
  // noise, so the scaling is asserted rather than assumed.
  AudioResampler resampler;
  resampler.Configure(kMixSampleRate, 2, /*source_is_float=*/false, 16);
  const std::vector<int16_t> input = {16384, -16384};
  std::vector<float> out;
  resampler.Process(reinterpret_cast<const uint8_t*>(input.data()), 1, &out);

  ASSERT_EQ(out.size(), kMixChannels);
  EXPECT_FLOAT_EQ(out[0], 0.5f);
  EXPECT_FLOAT_EQ(out[1], -0.5f);
}

TEST(AudioResampler, A44100EndpointProducesMoreFramesThanItConsumed) {
  // 48000/44100 of them, give or take the carry the resampler keeps between
  // packets. Asserted as a ratio rather than an exact count, because the carry
  // is the part that must survive across calls.
  AudioResampler resampler;
  resampler.Configure(44100, 2, /*source_is_float=*/true, 32);
  const std::vector<float> input = Block(441, 0.5f);
  std::vector<float> out;
  for (int packet = 0; packet < 10; ++packet) {
    resampler.Process(reinterpret_cast<const uint8_t*>(input.data()), 441, &out);
  }
  const size_t produced = out.size() / kMixChannels;
  EXPECT_GE(produced, 4780u);
  EXPECT_LE(produced, 4820u);
}

}  // namespace
}  // namespace relay
