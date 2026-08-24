// The Windows half of the pure recorder logic.
//
// Deliberately the mirror of
// `packages/recorder_macos/macos/recorder_macos/core/Tests/RecorderCoreTests`:
// the two platforms hand-write the same wire spellings and re-implement the
// same geometry and timing, and nothing in the Dart layer can see them
// disagree. Asserting the same properties on both sides is the only thing that
// catches drift — the aligned fallback in `ResolvePipRect` was found exactly
// this way.

#include <gtest/gtest.h>

#include <string>
#include <thread>
#include <vector>

#include "recorder_types.h"

namespace relay {
namespace {

constexpr double kCanvasWidth = 1920.0;
constexpr double kCanvasHeight = 1080.0;

// ── the wire contract ────────────────────────────────────────────────────────

TEST(RecorderContract, EveryErrorCodeKeepsItsWireSpelling) {
  // These strings become PlatformException.code and are mapped straight onto
  // the Dart enum by name. A rename on either side is caught by nothing else.
  const std::vector<std::pair<RecorderErrorCode, std::string>> expected = {
      {RecorderErrorCode::kPermissionDenied, "permissionDenied"},
      {RecorderErrorCode::kSourceUnavailable, "sourceUnavailable"},
      {RecorderErrorCode::kSourceClosed, "sourceClosed"},
      {RecorderErrorCode::kCameraUnavailable, "cameraUnavailable"},
      {RecorderErrorCode::kMicrophoneUnavailable, "microphoneUnavailable"},
      {RecorderErrorCode::kSystemAudioUnavailable, "systemAudioUnavailable"},
      {RecorderErrorCode::kCaptureFailed, "captureFailed"},
      {RecorderErrorCode::kEncodingFailed, "encodingFailed"},
      {RecorderErrorCode::kDiskFull, "diskFull"},
      {RecorderErrorCode::kFinalizationFailed, "finalizationFailed"},
      {RecorderErrorCode::kInvalidState, "invalidState"},
      {RecorderErrorCode::kUnsupported, "unsupported"},
      {RecorderErrorCode::kUnknown, "unknown"},
  };
  ASSERT_EQ(expected.size(), 13u) << "Dart declares thirteen codes";
  for (const auto& [code, name] : expected) {
    EXPECT_EQ(std::string(ErrorCodeName(code)), name);
  }
}

TEST(RecorderContract, EveryStateKeepsItsWireSpelling) {
  const std::vector<std::pair<SessionState, std::string>> expected = {
      {SessionState::kIdle, "idle"},
      {SessionState::kPreparing, "preparing"},
      {SessionState::kPrepared, "prepared"},
      {SessionState::kRecording, "recording"},
      {SessionState::kPaused, "paused"},
      {SessionState::kStopping, "stopping"},
      {SessionState::kFinalizing, "finalizing"},
      {SessionState::kFinalized, "finalized"},
      {SessionState::kFailed, "failed"},
  };
  ASSERT_EQ(expected.size(), 9u) << "Dart declares nine states";
  for (const auto& [state, name] : expected) {
    EXPECT_EQ(std::string(SessionStateName(state)), name);
  }
}

TEST(RecorderContract, EveryCornerNameDecodes) {
  EXPECT_EQ(PipCornerFromName("topLeft"), PipCorner::kTopLeft);
  EXPECT_EQ(PipCornerFromName("topRight"), PipCorner::kTopRight);
  EXPECT_EQ(PipCornerFromName("bottomLeft"), PipCorner::kBottomLeft);
  EXPECT_EQ(PipCornerFromName("bottomRight"), PipCorner::kBottomRight);
}

TEST(RecorderContract, AnUnknownCornerFallsBackToTheSpecifiedDefault) {
  // CLAUDE.md fixes the picture-in-picture in the lower right. An unrecognised
  // name must land there rather than in an arbitrary corner.
  EXPECT_EQ(PipCornerFromName("elsewhere"), PipCorner::kBottomRight);
  EXPECT_EQ(PipCornerFromName(""), PipCorner::kBottomRight);
}

// ── picture-in-picture geometry ──────────────────────────────────────────────

TEST(ResolvePipRect, TheDefaultTileMatchesTheSpecifiedProportions) {
  const CameraOverlayConfig config;
  const RectD rect = ResolvePipRect(config, kCanvasWidth, kCanvasHeight);

  EXPECT_DOUBLE_EQ(rect.width, kCanvasWidth * 0.16);
  EXPECT_DOUBLE_EQ(config.margin_ratio, 0.01);
  EXPECT_EQ(config.corner, PipCorner::kBottomRight);
}

TEST(ResolvePipRect, TheTileSitsInTheLowerRightWithAMarginOnBothEdges) {
  const CameraOverlayConfig config;
  const RectD rect = ResolvePipRect(config, kCanvasWidth, kCanvasHeight);
  const double margin = kCanvasWidth * 0.01;

  EXPECT_NEAR(kCanvasWidth - (rect.x + rect.width), margin, 1e-9);
  EXPECT_NEAR(kCanvasHeight - (rect.y + rect.height), margin, 1e-9);
}

TEST(ResolvePipRect, TheTileTakesTheCameraShapeRatherThanItsOwn) {
  // "The camera frame is never cropped and never distorted" is a property of
  // this arithmetic. A 4:3 camera must get a 4:3 tile.
  CameraOverlayConfig config;
  config.aspect_ratio = 16.0 / 9.0;
  config.follows_source_aspect_ratio = true;

  const RectD rect =
      ResolvePipRect(config, kCanvasWidth, kCanvasHeight, 4.0 / 3.0);
  EXPECT_NEAR(rect.width / rect.height, 4.0 / 3.0, 1e-9);
}

TEST(ResolvePipRect, APortraitCameraIsNotForcedIntoALandscapeTile) {
  CameraOverlayConfig config;
  config.follows_source_aspect_ratio = true;

  const RectD rect =
      ResolvePipRect(config, kCanvasWidth, kCanvasHeight, 9.0 / 16.0);
  EXPECT_NEAR(rect.width / rect.height, 9.0 / 16.0, 1e-9);
  EXPECT_GT(rect.height, rect.width);
}

TEST(ResolvePipRect, TheFallbackRatioIsUsedWhenTheCameraShapeIsUnknown) {
  CameraOverlayConfig config;
  config.aspect_ratio = 16.0 / 9.0;
  config.follows_source_aspect_ratio = true;

  // Zero means unknown: before the first camera frame there is nothing to
  // follow, and Dart placed the preview from the configured fallback.
  const RectD rect = ResolvePipRect(config, kCanvasWidth, kCanvasHeight, 0);
  EXPECT_NEAR(rect.width / rect.height, 16.0 / 9.0, 1e-9);
}

TEST(ResolvePipRect, FollowingIsHonouredOnlyWhenItIsSwitchedOn) {
  CameraOverlayConfig config;
  config.aspect_ratio = 16.0 / 9.0;
  config.follows_source_aspect_ratio = false;

  const RectD rect = ResolvePipRect(config, kCanvasWidth, kCanvasHeight, 1.0);
  EXPECT_NEAR(rect.width / rect.height, 16.0 / 9.0, 1e-9);
}

TEST(ResolvePipRect, AMalformedFallbackRatioFallsBackToSixteenByNine) {
  // The macOS mirror of this test is
  // `testAMalformedFallbackRatioFallsBackToSixteenByNine`. The two disagreed:
  // this produced a square tile and macOS produced a 0.0001-ratio sliver from
  // the same configuration, with nothing in Dart able to observe it.
  CameraOverlayConfig config;
  config.aspect_ratio = 0;
  config.follows_source_aspect_ratio = false;

  const RectD rect = ResolvePipRect(config, kCanvasWidth, kCanvasHeight);
  ASSERT_GT(rect.height, 0);
  EXPECT_NEAR(rect.width / rect.height, 16.0 / 9.0, 1e-9);
}

TEST(ResolvePipRect, EveryCornerAnchorsToItsOwnTwoEdges) {
  const double margin = kCanvasWidth * 0.01;
  const std::vector<PipCorner> corners = {
      PipCorner::kTopLeft, PipCorner::kTopRight, PipCorner::kBottomLeft,
      PipCorner::kBottomRight};

  for (const PipCorner corner : corners) {
    CameraOverlayConfig config;
    config.corner = corner;
    const RectD rect = ResolvePipRect(config, kCanvasWidth, kCanvasHeight);

    const bool left =
        corner == PipCorner::kTopLeft || corner == PipCorner::kBottomLeft;
    const bool top =
        corner == PipCorner::kTopLeft || corner == PipCorner::kTopRight;

    if (left) {
      EXPECT_NEAR(rect.x, margin, 1e-9);
    } else {
      EXPECT_NEAR(kCanvasWidth - (rect.x + rect.width), margin, 1e-9);
    }
    if (top) {
      EXPECT_NEAR(rect.y, margin, 1e-9);
    } else {
      EXPECT_NEAR(kCanvasHeight - (rect.y + rect.height), margin, 1e-9);
    }
  }
}

TEST(ResolvePipRect, TheTileStaysInsideTheCanvas) {
  CameraOverlayConfig config;
  config.follows_source_aspect_ratio = true;

  for (const double ratio : {0.5, 1.0, 4.0 / 3.0, 16.0 / 9.0, 2.35}) {
    const RectD rect =
        ResolvePipRect(config, kCanvasWidth, kCanvasHeight, ratio);
    EXPECT_GE(rect.x, 0) << "ratio " << ratio;
    EXPECT_GE(rect.y, 0) << "ratio " << ratio;
    EXPECT_LE(rect.x + rect.width, kCanvasWidth) << "ratio " << ratio;
    EXPECT_LE(rect.y + rect.height, kCanvasHeight) << "ratio " << ratio;
  }
}

// ── letterboxing ─────────────────────────────────────────────────────────────

TEST(LetterboxRect, TheSourceShapeIsPreservedAndCentred) {
  const RectD rect = LetterboxRect(1600, 1000, 1920, 1080);

  EXPECT_NEAR(rect.width / rect.height, 1.6, 1e-9);
  EXPECT_NEAR(rect.x, (1920 - rect.width) / 2.0, 1e-9);
  EXPECT_NEAR(rect.y, (1080 - rect.height) / 2.0, 1e-9);
}

TEST(LetterboxRect, ATallSourcePillarboxes) {
  const RectD rect = LetterboxRect(1080, 1920, 1920, 1080);

  EXPECT_NEAR(rect.height, 1080, 1e-9);
  EXPECT_LT(rect.width, 1920);
  EXPECT_GT(rect.x, 0) << "bars on the left and right";
  EXPECT_NEAR(rect.y, 0, 1e-9);
}

TEST(LetterboxRect, ADegenerateSourceFillsTheCanvas) {
  // A source that reports no size cannot be fitted; filling is the only
  // answer that still produces a drawable rectangle.
  for (const auto& [w, h] : std::vector<std::pair<double, double>>{
           {0, 1080}, {1920, 0}, {-4, -3}}) {
    const RectD rect = LetterboxRect(w, h, 1920, 1080);
    EXPECT_DOUBLE_EQ(rect.width, 1920);
    EXPECT_DOUBLE_EQ(rect.height, 1080);
  }
}

// ── canvas sizing ────────────────────────────────────────────────────────────

TEST(ResolveCanvasSize, TheCanvasIsAlwaysEven) {
  // H.264 4:2:0 requires even dimensions. An odd canvas is not a slightly
  // wrong file, it is an encoder that refuses to start.
  const CompositionConfig composition;
  for (const auto& [w, h] : std::vector<std::pair<uint32_t, uint32_t>>{
           {1365, 767}, {999, 555}, {1023, 601}, {2560, 1600}}) {
    uint32_t out_width = 0;
    uint32_t out_height = 0;
    ResolveCanvasSize(composition, w, h, 720, &out_width, &out_height);
    EXPECT_EQ(out_width % 2, 0u) << w << "x" << h;
    EXPECT_EQ(out_height % 2, 0u) << w << "x" << h;
  }
}

TEST(ResolveCanvasSize, TheSourceShapeIsPreservedInsideThePreset) {
  const CompositionConfig composition;
  uint32_t width = 0;
  uint32_t height = 0;
  ResolveCanvasSize(composition, 2560, 1600, 720, &width, &height);

  EXPECT_NEAR(static_cast<double>(width) / height, 2560.0 / 1600.0, 0.01);
  EXPECT_LE(height, 720u);
  EXPECT_LE(width, 1280u);
}

TEST(ResolveCanvasSize, ASourceSmallerThanThePresetIsNotUpscaled) {
  const CompositionConfig composition;
  uint32_t width = 0;
  uint32_t height = 0;
  ResolveCanvasSize(composition, 640, 480, 1080, &width, &height);

  EXPECT_EQ(width, 640u);
  EXPECT_EQ(height, 480u);
}

TEST(ResolveCanvasSize, AnUnknownSourceSizeFallsBackToThePresetBox) {
  const CompositionConfig composition;
  uint32_t width = 0;
  uint32_t height = 0;
  ResolveCanvasSize(composition, 0, 0, 1080, &width, &height);

  EXPECT_EQ(width, 1920u);
  EXPECT_EQ(height, 1080u);
}

TEST(ResolveCanvasSize, TheReferenceCanvasPolicyUsesThePresetBox) {
  CompositionConfig composition;
  composition.aspect_policy = AspectRatioPolicy::kLetterboxIntoReferenceCanvas;
  uint32_t width = 0;
  uint32_t height = 0;
  ResolveCanvasSize(composition, 2560, 1600, 720, &width, &height);

  EXPECT_EQ(width, 1280u);
  EXPECT_EQ(height, 720u);
}

TEST(ResolveCanvasSize, TheCanvasNeverCollapses) {
  const CompositionConfig composition;
  uint32_t width = 0;
  uint32_t height = 0;
  ResolveCanvasSize(composition, 1, 1, 720, &width, &height);

  EXPECT_GE(width, 2u);
  EXPECT_GE(height, 2u);
}

// ── the session timeline ─────────────────────────────────────────────────────

// 100 ns units, which is what everything downstream works in.
constexpr int64_t kSecond = 10'000'000LL;

TEST(SessionClock, AFreshClockIsNotRunning) {
  const SessionClock clock;
  EXPECT_FALSE(clock.running());
  EXPECT_FALSE(clock.paused());
  EXPECT_EQ(clock.ElapsedMs(), 0);
}

TEST(SessionClock, MediaTimeIsMeasuredFromTheStart) {
  SessionClock clock;
  clock.Start(1000 * kSecond);

  EXPECT_EQ(clock.MediaTime100ns(1000 * kSecond), 0);
  EXPECT_EQ(clock.MediaTime100ns(1002 * kSecond), 2 * kSecond);
}

TEST(SessionClock, ASampleCapturedWhilePausedHasNoPlaceOnTheTimeline) {
  // -1, not a clamped value: encoding it would put paused wall time into the
  // file and the duration would stop matching the timer on the strip.
  SessionClock clock;
  clock.Start(0);
  clock.Pause(5 * kSecond);

  EXPECT_TRUE(clock.paused());
  EXPECT_EQ(clock.MediaTime100ns(7 * kSecond), -1);
}

TEST(SessionClock, PausedIntervalsAreSubtracted) {
  SessionClock clock;
  clock.Start(0);
  clock.Pause(5 * kSecond);
  clock.Resume(9 * kSecond);

  // Four seconds of wall time passed while paused; the media timeline must not
  // have advanced by them.
  EXPECT_EQ(clock.MediaTime100ns(10 * kSecond), 5 * kSecond);
}

TEST(SessionClock, SeveralPausesAccumulate) {
  SessionClock clock;
  clock.Start(0);
  clock.Pause(2 * kSecond);
  clock.Resume(4 * kSecond);
  clock.Pause(6 * kSecond);
  clock.Resume(10 * kSecond);

  // Six seconds paused in total out of twelve elapsed.
  EXPECT_EQ(clock.MediaTime100ns(12 * kSecond), 6 * kSecond);
}

TEST(SessionClock, PauseIsIdempotent) {
  // A double click on the strip is one mis-timed frame away from doing this.
  SessionClock clock;
  clock.Start(0);
  clock.Pause(2 * kSecond);
  clock.Pause(3 * kSecond);
  clock.Resume(4 * kSecond);

  EXPECT_FALSE(clock.paused());
  EXPECT_EQ(clock.MediaTime100ns(5 * kSecond), 3 * kSecond);
}

TEST(SessionClock, ResumeWithoutPauseDoesNothing) {
  SessionClock clock;
  clock.Start(0);
  clock.Resume(4 * kSecond);

  EXPECT_EQ(clock.MediaTime100ns(5 * kSecond), 5 * kSecond);
}

TEST(SessionClock, StopFreezesTheElapsedTime) {
  SessionClock clock;
  clock.Start(0);
  clock.Stop(8 * kSecond);

  EXPECT_FALSE(clock.running());
  EXPECT_EQ(clock.ElapsedMs(), 8000);
  // A stopped session accepts no more samples: the writer is being finalized.
  EXPECT_EQ(clock.MediaTime100ns(9 * kSecond), -1);
}

TEST(SessionClock, StoppingWhilePausedClosesThePauseFirst) {
  SessionClock clock;
  clock.Start(0);
  clock.Pause(3 * kSecond);
  clock.Stop(10 * kSecond);

  // Seven seconds paused: the recorded duration is the three that were not.
  EXPECT_EQ(clock.ElapsedMs(), 3000);
}

TEST(SessionClock, ATimestampBeforeTheStartIsClampedRatherThanNegative) {
  // Out-of-order buffers do arrive. A negative media time would be appended
  // behind the previous frame and the encoder would reject the run.
  SessionClock clock;
  clock.Start(100 * kSecond);

  EXPECT_EQ(clock.MediaTime100ns(99 * kSecond), 0);
}

TEST(SessionClock, RestartingResetsTheTimeline) {
  SessionClock clock;
  clock.Start(0);
  clock.Pause(2 * kSecond);
  clock.Resume(4 * kSecond);
  clock.Stop(6 * kSecond);

  clock.Start(1000 * kSecond);
  EXPECT_EQ(clock.MediaTime100ns(1000 * kSecond), 0)
      << "a second recording starts at zero";
  EXPECT_FALSE(clock.paused()) << "and does not inherit the previous pause";
}

TEST(SessionClock, ConcurrentAccessFromManyThreadsIsSafe) {
  // Video arrives on the capture thread, audio on the WASAPI thread, and
  // pause/resume on the platform thread. The mutex is the reason this is a
  // wrong number rather than undefined behaviour.
  SessionClock clock;
  clock.Start(0);

  std::vector<std::thread> threads;
  threads.reserve(8);
  for (int worker = 0; worker < 8; ++worker) {
    threads.emplace_back([&clock, worker] {
      for (int i = 1; i <= 200; ++i) {
        if (worker % 4 == 0) {
          clock.Pause(static_cast<int64_t>(i) * kSecond);
          clock.Resume(static_cast<int64_t>(i) * kSecond);
        } else {
          (void)clock.MediaTime100ns(static_cast<int64_t>(i) * kSecond);
          (void)clock.ElapsedMs();
        }
      }
    });
  }
  for (std::thread& thread : threads) {
    thread.join();
  }
  EXPECT_TRUE(clock.running());
}

// ── output paths ─────────────────────────────────────────────────────────────

TEST(RecordingConfig, ThePartAndFinalNamesFollowTheSpecifiedPattern) {
  // Startup recovery finds artefacts by this exact shape, and stop renames
  // `.part` onto `.mp4` (spec 18).
  RecordingConfig config;
  config.recording_id = "abc123";
  config.output_directory = L"C:\\Users\\relay\\Videos\\Relay";

  EXPECT_EQ(config.PartPath(),
            L"C:\\Users\\relay\\Videos\\Relay\\recording-abc123.part");
  EXPECT_EQ(config.FinalPath(),
            L"C:\\Users\\relay\\Videos\\Relay\\recording-abc123.mp4");
}

TEST(RecordingConfig, TheDefaultsMatchTheSpecifiedProductBehaviour) {
  // CLAUDE.md: microphone on, camera off, system audio on, cursor recorded,
  // 30 fps, 720p.
  const RecordingConfig config;

  EXPECT_TRUE(config.microphone_enabled);
  EXPECT_FALSE(config.camera_enabled);
  EXPECT_TRUE(config.system_audio_enabled);
  EXPECT_TRUE(config.show_cursor);
  EXPECT_EQ(config.frame_rate, 30u);
  EXPECT_EQ(config.target_height, 720u);
  EXPECT_EQ(config.source_type, CaptureSourceType::kDisplay);
}

// ── string conversion ────────────────────────────────────────────────────────

TEST(Widen, RoundTripsThroughNarrow) {
  for (const std::string& original :
       {std::string("relay"), std::string("Запись экрана"),
        std::string("recording-abc123.mp4"), std::string("")}) {
    EXPECT_EQ(Narrow(Widen(original)), original);
  }
}

TEST(JoinPath, InsertsExactlyOneSeparator) {
  EXPECT_EQ(JoinPath(L"C:\\Relay", L"a.mp4"), L"C:\\Relay\\a.mp4");
  EXPECT_EQ(JoinPath(L"C:\\Relay\\", L"a.mp4"), L"C:\\Relay\\a.mp4");
}

}  // namespace
}  // namespace relay
