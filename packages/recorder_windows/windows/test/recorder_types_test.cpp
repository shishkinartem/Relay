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

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <string>
#include <thread>
#include <utility>
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

// ── presets, crop and mask (spec 33.5) ───────────────────────────────────────

TEST(CameraPipPreset, EveryPresetKeepsItsWireSpelling) {
  // These strings are CameraPipPreset.name in Dart and travel on the
  // cameraOverlay map. A rename on either side is caught by nothing else.
  EXPECT_EQ(std::string(CameraPipPresetName(CameraPipPreset::kCamera)), "camera");
  EXPECT_EQ(std::string(CameraPipPresetName(CameraPipPreset::kSquare)), "square");
  EXPECT_EQ(std::string(CameraPipPresetName(CameraPipPreset::kCircle)), "circle");
  EXPECT_EQ(CameraPipPresetFromName("camera"), CameraPipPreset::kCamera);
  EXPECT_EQ(CameraPipPresetFromName("square"), CameraPipPreset::kSquare);
  EXPECT_EQ(CameraPipPresetFromName("circle"), CameraPipPreset::kCircle);
}

TEST(CameraPipPreset, AnUnknownPresetIsTheOneThatCropsNothing) {
  // Unlike a device kind, a preset has to resolve to something: a tile is going
  // to be drawn either way, and the default is the one that keeps the whole
  // frame.
  EXPECT_EQ(CameraPipPresetFromName("hexagon"), CameraPipPreset::kCamera);
  EXPECT_EQ(CameraPipPresetFromName(""), CameraPipPreset::kCamera);
  EXPECT_EQ(CameraPipFitFromName("nonsense"), CameraPipFit::kContain);
  EXPECT_EQ(CameraPipFitFromName(""), CameraPipFit::kContain);
}

TEST(CameraPipFit, EveryFitKeepsItsWireSpelling) {
  EXPECT_EQ(std::string(CameraPipFitName(CameraPipFit::kContain)), "contain");
  EXPECT_EQ(std::string(CameraPipFitName(CameraPipFit::kCover)), "cover");
  EXPECT_EQ(CameraPipFitFromName("contain"), CameraPipFit::kContain);
  EXPECT_EQ(CameraPipFitFromName("cover"), CameraPipFit::kCover);
}

TEST(EffectivePipWidthRatio, TheCameraPresetIsCappedAtTheAcceptedDefault) {
  // A 1280-wide camera on a 1920 canvas asks for 0.66 and gets the cap, so an
  // ordinary session looks exactly as it did before presets existed (33.5).
  const CameraOverlayConfig config;
  EXPECT_DOUBLE_EQ(EffectivePipWidthRatio(config, kCanvasWidth, 1280),
                   kCameraPresetWidthCap);
}

TEST(EffectivePipWidthRatio, ACameraNarrowerThanTheCapGetsItsOwnWidth) {
  // "The camera's own width" is a default, not a licence to upscale: a small
  // sensor is never stretched past its own pixels.
  const CameraOverlayConfig config;
  EXPECT_DOUBLE_EQ(EffectivePipWidthRatio(config, kCanvasWidth, 240), 240.0 / 1920.0);
}

TEST(EffectivePipWidthRatio, TheFloorHoldsForACameraNobodyCouldRead) {
  const CameraOverlayConfig config;
  EXPECT_DOUBLE_EQ(EffectivePipWidthRatio(config, kCanvasWidth, 32), kMinPipWidthRatio);
}

TEST(EffectivePipWidthRatio, AFixedPresetKeepsItsSizeWhateverTheCameraIs) {
  // Square and Circle are a stated size; a small sensor does not shrink them,
  // because the size is the point of choosing them.
  CameraOverlayConfig config;
  config.preset = CameraPipPreset::kSquare;
  config.width_ratio = kSmallPresetWidthRatio;
  EXPECT_DOUBLE_EQ(EffectivePipWidthRatio(config, kCanvasWidth, 240),
                   kSmallPresetWidthRatio);
  EXPECT_DOUBLE_EQ(EffectivePipWidthRatio(config, kCanvasWidth, 4096),
                   kSmallPresetWidthRatio);
}

TEST(EffectivePipWidthRatio, AnUnknownCameraWidthLeavesTheConfiguredRatio) {
  // Nothing has been captured yet. The tile still has to be placed, and the
  // configured width is the honest answer until a frame says otherwise.
  const CameraOverlayConfig config;
  EXPECT_DOUBLE_EQ(EffectivePipWidthRatio(config, kCanvasWidth, 0),
                   kCameraPresetWidthCap);
}

TEST(EffectivePipWidthRatio, TheStatedBoundsHoldHoweverTheValueArrived) {
  CameraOverlayConfig config;
  config.width_ratio = 4.0;
  EXPECT_DOUBLE_EQ(EffectivePipWidthRatio(config, kCanvasWidth, 0), kMaxPipWidthRatio);
  config.width_ratio = 0.001;
  EXPECT_DOUBLE_EQ(EffectivePipWidthRatio(config, kCanvasWidth, 0), kMinPipWidthRatio);
}

TEST(ResolvePipRect, AFreePositionIsHonouredWhereItIs) {
  CameraOverlayConfig config;
  config.has_position = true;
  config.position_x = 0.4;
  config.position_y = 0.3;

  const RectD rect = ResolvePipRect(config, kCanvasWidth, kCanvasHeight);
  EXPECT_NEAR(rect.x, 0.4 * kCanvasWidth, 1e-9);
  EXPECT_NEAR(rect.y, 0.3 * kCanvasHeight, 1e-9);
}

TEST(ResolvePipRect, ADragPastTheEdgeIsClampedToTheMargin) {
  CameraOverlayConfig config;
  config.has_position = true;
  config.position_x = 1.5;
  config.position_y = -0.4;

  const RectD rect = ResolvePipRect(config, kCanvasWidth, kCanvasHeight);
  const double margin = kCanvasWidth * config.margin_ratio;
  EXPECT_NEAR(rect.x, kCanvasWidth - margin - rect.width, 1e-9);
  EXPECT_NEAR(rect.y, margin, 1e-9);
}

TEST(ResolvePipRect, ATileLeftNearACornerSnapsOntoIt) {
  // Within 2% of the canvas width, the tile lands on the margin exactly, so
  // "put it back in the corner" is one gesture rather than a pixel hunt.
  CameraOverlayConfig config;
  config.has_position = true;
  const double margin = kCanvasWidth * config.margin_ratio;
  const double near_corner = margin + kCanvasWidth * kPipSnapRatio * 0.5;
  config.position_x = near_corner / kCanvasWidth;
  config.position_y = near_corner / kCanvasHeight;

  const RectD rect = ResolvePipRect(config, kCanvasWidth, kCanvasHeight);
  EXPECT_NEAR(rect.x, margin, 1e-9);
  EXPECT_NEAR(rect.y, margin, 1e-9);
}

TEST(ResolvePipRect, BeyondTheSnapDistanceTheTileStaysWhereItWasPut) {
  CameraOverlayConfig config;
  config.has_position = true;
  const double margin = kCanvasWidth * config.margin_ratio;
  const double away = margin + kCanvasWidth * kPipSnapRatio * 2.0;
  config.position_x = away / kCanvasWidth;
  config.position_y = away / kCanvasHeight;

  const RectD rect = ResolvePipRect(config, kCanvasWidth, kCanvasHeight);
  EXPECT_NEAR(rect.x, away, 1e-9);
  EXPECT_NEAR(rect.y, away, 1e-9);
}

TEST(ResolvePipRect, NoPositionIsALiveReferenceToTheCornerNotAStaleFraction) {
  // Null is not "unset": a canvas that changes shape keeps the tile in the
  // corner rather than at whatever fraction that corner used to be.
  const CameraOverlayConfig config;
  const RectD wide = ResolvePipRect(config, 1920, 1080);
  const RectD tall = ResolvePipRect(config, 1080, 1920);
  EXPECT_NEAR(1920 - (wide.x + wide.width), 1920 * config.margin_ratio, 1e-9);
  EXPECT_NEAR(1080 - (tall.x + tall.width), 1080 * config.margin_ratio, 1e-9);
}

TEST(PipPositionRatio, TheRoundTripReproducesTheRectangleItWasMeasuredFrom) {
  CameraOverlayConfig config;
  config.has_position = true;
  config.position_x = 0.37;
  config.position_y = 0.61;
  const RectD rect = ResolvePipRect(config, kCanvasWidth, kCanvasHeight);

  double x = 0;
  double y = 0;
  ASSERT_TRUE(PipPositionRatio(rect.x, rect.y, kCanvasWidth, kCanvasHeight, &x, &y));
  CameraOverlayConfig again = config;
  again.position_x = x;
  again.position_y = y;
  const RectD reproduced = ResolvePipRect(again, kCanvasWidth, kCanvasHeight);
  EXPECT_NEAR(reproduced.x, rect.x, 1e-9);
  EXPECT_NEAR(reproduced.y, rect.y, 1e-9);
}

TEST(PipPositionRatio, ACanvasWithNoExtentHasNoFractionToReport) {
  // A fraction of nothing says nothing: the caller keeps whatever it had, which
  // is the null cameraPreviewPosition answers with.
  double x = 0;
  double y = 0;
  EXPECT_FALSE(PipPositionRatio(10, 10, 0, 1080, &x, &y));
  EXPECT_FALSE(PipPositionRatio(10, 10, 1920, 0, &x, &y));
}

TEST(ResolvePipDraw, TheCameraPresetDrawsTheWholeFrameAndCropsNothing) {
  const CameraOverlayConfig config;
  const PipDraw draw = ResolvePipDraw(config, kCanvasWidth, kCanvasHeight, 1280, 720);

  EXPECT_DOUBLE_EQ(draw.source.x, 0);
  EXPECT_DOUBLE_EQ(draw.source.y, 0);
  EXPECT_DOUBLE_EQ(draw.source.width, 1280);
  EXPECT_DOUBLE_EQ(draw.source.height, 720);
  EXPECT_DOUBLE_EQ(draw.corner_radius, 0);
  // And the tile takes the camera's shape, so the letterbox inside it is the
  // tile itself.
  EXPECT_NEAR(draw.dest.width / draw.dest.height, 1280.0 / 720.0, 1e-9);
}

TEST(ResolvePipDraw, ASquarePresetTakesTheCentreOfTheFrame) {
  CameraOverlayConfig config;
  config.preset = CameraPipPreset::kSquare;
  config.width_ratio = kSmallPresetWidthRatio;
  config.aspect_ratio = 1.0;
  config.follows_source_aspect_ratio = false;
  config.fit = CameraPipFit::kCover;

  const PipDraw draw = ResolvePipDraw(config, kCanvasWidth, kCanvasHeight, 1280, 720);
  // The largest square inside a 16:9 frame is its height, centred.
  EXPECT_DOUBLE_EQ(draw.source.width, 720);
  EXPECT_DOUBLE_EQ(draw.source.height, 720);
  EXPECT_DOUBLE_EQ(draw.source.x, (1280 - 720) / 2.0);
  EXPECT_DOUBLE_EQ(draw.source.y, 0);
  // Cover fills the tile, so the destination is the tile and nothing is
  // letterboxed inside it.
  EXPECT_NEAR(draw.dest.width, kCanvasWidth * kSmallPresetWidthRatio, 1e-9);
  EXPECT_NEAR(draw.dest.height, draw.dest.width, 1e-9);
}

TEST(ResolvePipDraw, APortraitCameraIsCroppedOnTheOtherAxis) {
  CameraOverlayConfig config;
  config.preset = CameraPipPreset::kSquare;
  config.width_ratio = kSmallPresetWidthRatio;
  config.aspect_ratio = 1.0;
  config.follows_source_aspect_ratio = false;
  config.fit = CameraPipFit::kCover;

  const PipDraw draw = ResolvePipDraw(config, kCanvasWidth, kCanvasHeight, 720, 1280);
  EXPECT_DOUBLE_EQ(draw.source.width, 720);
  EXPECT_DOUBLE_EQ(draw.source.height, 720);
  EXPECT_DOUBLE_EQ(draw.source.x, 0);
  EXPECT_DOUBLE_EQ(draw.source.y, (1280 - 720) / 2.0);
}

TEST(ResolvePipDraw, TheCircleIsTheSquareWithARadiusOfHalfItsWidth) {
  // Same size, same crop: only the mask differs, which is what makes the two
  // presets one shape with two edges (33.5).
  CameraOverlayConfig square;
  square.preset = CameraPipPreset::kSquare;
  square.width_ratio = kSmallPresetWidthRatio;
  square.aspect_ratio = 1.0;
  square.follows_source_aspect_ratio = false;
  square.fit = CameraPipFit::kCover;
  CameraOverlayConfig circle = square;
  circle.preset = CameraPipPreset::kCircle;
  circle.corner_radius_ratio = 0.5;

  const PipDraw flat = ResolvePipDraw(square, kCanvasWidth, kCanvasHeight, 1280, 720);
  const PipDraw round = ResolvePipDraw(circle, kCanvasWidth, kCanvasHeight, 1280, 720);
  EXPECT_DOUBLE_EQ(round.dest.width, flat.dest.width);
  EXPECT_DOUBLE_EQ(round.source.width, flat.source.width);
  EXPECT_DOUBLE_EQ(round.corner_radius, round.dest.width / 2.0);
}

TEST(ResolvePipDraw, TheRadiusNeverExceedsHalfTheShorterSide) {
  // A ratio above 0.5 on a tile that is not square would otherwise describe an
  // arc larger than the rectangle it is rounding.
  CameraOverlayConfig config;
  config.corner_radius_ratio = 0.5;

  const PipDraw draw = ResolvePipDraw(config, kCanvasWidth, kCanvasHeight, 1280, 720);
  EXPECT_LE(draw.corner_radius, (std::min)(draw.dest.width, draw.dest.height) / 2.0);
}

TEST(ResolvePipDraw, NoFrameYetStillPlacesTheTile) {
  // The preview is positioned before the first camera frame arrives; there is
  // simply no crop to resolve for a frame that does not exist.
  const CameraOverlayConfig config;
  const PipDraw draw = ResolvePipDraw(config, kCanvasWidth, kCanvasHeight, 0, 0);
  EXPECT_GT(draw.dest.width, 0);
  EXPECT_DOUBLE_EQ(draw.source.width, 0);
}

// ── what the preview window is told to draw (spec 33.5, design 1p) ───────────

TEST(ResolveCameraPreviewDraw, TheDisplayModePreviewCarriesThePresetsCropAndMask) {
  // The defect this exists to prevent: a preview that letterboxes a rectangle
  // while the file gets a cropped circle. `1p` promises they are one object.
  CameraOverlayConfig config;
  config.preset = CameraPipPreset::kCircle;
  config.width_ratio = kSmallPresetWidthRatio;
  config.aspect_ratio = 1.0;
  config.follows_source_aspect_ratio = false;
  config.fit = CameraPipFit::kCover;
  config.corner_radius_ratio = 0.5;

  const PipDraw draw = ResolvePipDraw(config, kCanvasWidth, kCanvasHeight, 1280, 720);
  const CameraPreviewDraw preview =
      ResolveCameraPreviewDraw(config, /*is_tile=*/true, draw, 1280, 720);

  EXPECT_EQ(preview.fit, CameraPipFit::kCover);
  EXPECT_DOUBLE_EQ(preview.corner_radius_ratio, 0.5);
  // The tile's shape, not the camera's: the host pushes the crop to the
  // preview's texture, so a square tile fed a 16:9 sensor is drawn square.
  EXPECT_NEAR(preview.aspect_ratio, 1.0, 1e-9);
}

TEST(ResolveCameraPreviewDraw, TheWindowModePreviewCarriesThePresetsShapeToo) {
  // This asserted the opposite until 2026-08-30, on the reasoning that design
  // 1e makes the window-mode preview a separate captioned object rather than
  // the tile. That is true of the PANEL and says nothing about the picture
  // inside it — and the compositor has no source-type gate, so a window
  // recording gets the circle in the file exactly as a display recording does.
  // All three presets therefore looked identical on screen while the MP4
  // differed, which is the defect spec 33.5 forbids.
  CameraOverlayConfig config;
  config.preset = CameraPipPreset::kCircle;
  config.aspect_ratio = 1.0;
  config.follows_source_aspect_ratio = false;
  config.fit = CameraPipFit::kCover;
  config.corner_radius_ratio = 0.5;

  const PipDraw draw = ResolvePipDraw(config, kCanvasWidth, kCanvasHeight, 1280, 720);
  const CameraPreviewDraw preview =
      ResolveCameraPreviewDraw(config, /*is_tile=*/false, draw, 1280, 720);

  EXPECT_EQ(preview.fit, CameraPipFit::kCover);
  EXPECT_DOUBLE_EQ(preview.corner_radius_ratio, 0.5);
  // The TEXTURE is the camera's own frame — PushFrame crops for the tile and
  // nothing else — so reporting the tile's shape here would squash a picture
  // that never received the crop.
  EXPECT_NEAR(preview.aspect_ratio, 1280.0 / 720.0, 1e-9);
  // The BOX is the tile's, which is what lets the captioned panel show the
  // shape the file gets without becoming that shape itself.
  EXPECT_NEAR(preview.pip_aspect_ratio, 1.0, 1e-9);
}

TEST(ResolveCameraPreviewDraw, DisplayModeReportsOneShapeForBothBoxAndTexture) {
  // There the host has already cropped the texture to the tile, so the two
  // questions have the same answer and Dart has one code path.
  CameraOverlayConfig config;
  config.preset = CameraPipPreset::kSquare;
  config.aspect_ratio = 1.0;
  config.follows_source_aspect_ratio = false;
  config.fit = CameraPipFit::kCover;

  const PipDraw draw = ResolvePipDraw(config, kCanvasWidth, kCanvasHeight, 1280, 720);
  const CameraPreviewDraw preview =
      ResolveCameraPreviewDraw(config, /*is_tile=*/true, draw, 1280, 720);

  EXPECT_NEAR(preview.aspect_ratio, preview.pip_aspect_ratio, 1e-9);
  EXPECT_NEAR(preview.pip_aspect_ratio, 1.0, 1e-9);
}

TEST(ResolveCameraPreviewDraw, TheDefaultPresetCropsNothingAndMasksNothing) {
  const CameraOverlayConfig config;
  const PipDraw draw = ResolvePipDraw(config, kCanvasWidth, kCanvasHeight, 640, 480);
  const CameraPreviewDraw preview =
      ResolveCameraPreviewDraw(config, /*is_tile=*/true, draw, 640, 480);

  EXPECT_EQ(preview.fit, CameraPipFit::kContain);
  EXPECT_DOUBLE_EQ(preview.corner_radius_ratio, 0);
  // A 4:3 camera on the `camera` preset gives a 4:3 tile, which is the whole
  // point of following the source aspect ratio.
  EXPECT_NEAR(preview.aspect_ratio, 4.0 / 3.0, 1e-9);
}

TEST(ResolveCameraPreviewDraw, ANeverOpenedCameraFallsBackToTheConfiguredShape) {
  // The preview is placed before the camera has delivered anything, and the
  // window-mode preview has no tile to take a shape from.
  CameraOverlayConfig config;
  config.aspect_ratio = 4.0 / 3.0;

  const PipDraw draw = ResolvePipDraw(config, kCanvasWidth, kCanvasHeight, 0, 0);
  const CameraPreviewDraw preview =
      ResolveCameraPreviewDraw(config, /*is_tile=*/false, draw, 0, 0);
  EXPECT_NEAR(preview.aspect_ratio, 4.0 / 3.0, 1e-9);

  // A fallback that is not a shape falls back again, exactly as ResolvePipRect
  // does, rather than collapsing the window.
  config.aspect_ratio = 0;
  const CameraPreviewDraw malformed =
      ResolveCameraPreviewDraw(config, /*is_tile=*/false, draw, 0, 0);
  EXPECT_NEAR(malformed.aspect_ratio, 16.0 / 9.0, 1e-9);
}

TEST(ResolveCameraPreviewDraw, ARadiusOutsideTheStatedRangeIsClampedNotDrawn) {
  // 0.5 is a circle and there is no shape past it. Dart clamps the same value
  // on the way in; a host that sent 3.0 would ask the preview to round a tile
  // by more than its own width.
  CameraOverlayConfig config;
  config.corner_radius_ratio = 3.0;
  const PipDraw draw = ResolvePipDraw(config, kCanvasWidth, kCanvasHeight, 1280, 720);
  EXPECT_DOUBLE_EQ(
      ResolveCameraPreviewDraw(config, /*is_tile=*/true, draw, 1280, 720)
          .corner_radius_ratio,
      kMaxCornerRadiusRatio);

  config.corner_radius_ratio = -1.0;
  EXPECT_DOUBLE_EQ(
      ResolveCameraPreviewDraw(config, /*is_tile=*/true, draw, 1280, 720)
          .corner_radius_ratio,
      0.0);
}

TEST(ResolveCameraPreviewDraw, ATileWithNoExtentStillReportsADrawableShape) {
  // The canvas has no room, or nothing has been composed yet. A zero aspect
  // ratio would be a window with no height.
  const CameraOverlayConfig config;
  const CameraPreviewDraw preview =
      ResolveCameraPreviewDraw(config, /*is_tile=*/true, PipDraw(), 0, 0);
  EXPECT_NEAR(preview.aspect_ratio, 16.0 / 9.0, 1e-9);
}

// ── which choices close the input menu (spec 33.4) ───────────────────────────

TEST(MenuChoiceClosesMenu, ADeviceRowClosesTheSheet) {
  // Including `System default` and `Off`, which carry none of the camera
  // sheet's extra keys either.
  EXPECT_TRUE(MenuChoiceClosesMenu(/*has_preset=*/false, /*has_corner=*/false));
}

TEST(MenuChoiceClosesMenu, AShapePresetLeavesTheSheetOpen) {
  // The tile changes shape on screen underneath it, and comparing the three
  // presets must not cost a reopen each time.
  EXPECT_FALSE(MenuChoiceClosesMenu(/*has_preset=*/true, /*has_corner=*/false));
}

TEST(MenuChoiceClosesMenu, ACornerLeavesTheSheetOpen) {
  // Window mode's placement row: the tile moves under the sheet exactly as a
  // preset reshapes it.
  EXPECT_FALSE(MenuChoiceClosesMenu(/*has_preset=*/false, /*has_corner=*/true));
}

TEST(ResolveCameraFrameMask, TheDefaultPresetMasksNothing) {
  const CameraOverlayConfig config;
  const CameraFrameMask mask =
      ResolveCameraFrameMask(config, kCanvasWidth, kCanvasHeight, 1280, 720);
  EXPECT_TRUE(CameraMaskIsRectangular(mask));
  EXPECT_DOUBLE_EQ(mask.crop.width, 1280);
  EXPECT_DOUBLE_EQ(mask.crop.height, 720);
  EXPECT_DOUBLE_EQ(CameraMaskCoverage(mask, 0.5, 0.5), 1.0);
  EXPECT_DOUBLE_EQ(CameraMaskCoverage(mask, 639.5, 359.5), 1.0);
}

TEST(ResolveCameraFrameMask, TheCircleBecomesACircleInTheFramesOwnPixels) {
  // The crop and the tile are the same shape, so the mask scales to the frame
  // without becoming an ellipse — which is what lets the preview and the file
  // be masked by one number.
  CameraOverlayConfig config;
  config.preset = CameraPipPreset::kCircle;
  config.width_ratio = kSmallPresetWidthRatio;
  config.aspect_ratio = 1.0;
  config.follows_source_aspect_ratio = false;
  config.fit = CameraPipFit::kCover;
  config.corner_radius_ratio = 0.5;

  const CameraFrameMask mask =
      ResolveCameraFrameMask(config, kCanvasWidth, kCanvasHeight, 1280, 720);
  EXPECT_FALSE(CameraMaskIsRectangular(mask));
  EXPECT_DOUBLE_EQ(mask.crop.width, 720);
  EXPECT_NEAR(mask.corner_radius, 360.0, 1e-9);

  // The centre is covered, the corners of the crop are not.
  EXPECT_DOUBLE_EQ(CameraMaskCoverage(mask, 640.0, 360.0), 1.0);
  EXPECT_DOUBLE_EQ(CameraMaskCoverage(mask, mask.crop.x + 1, 1), 0.0);
  EXPECT_DOUBLE_EQ(
      CameraMaskCoverage(mask, mask.crop.x + mask.crop.width - 1, 719), 0.0);
}

TEST(CameraMaskCoverage, TheEdgeOfARoundedMaskIsRampedNotStepped) {
  CameraFrameMask mask;
  mask.crop = RectD{0, 0, 100, 100};
  mask.corner_radius = 50;
  // Straight across the middle: fully covered inside, nothing outside, and a
  // single pixel of ramp between them.
  EXPECT_DOUBLE_EQ(CameraMaskCoverage(mask, 50, 50), 1.0);
  EXPECT_DOUBLE_EQ(CameraMaskCoverage(mask, 99.4, 50), 1.0);
  EXPECT_DOUBLE_EQ(CameraMaskCoverage(mask, 100.6, 50), 0.0);
  EXPECT_NEAR(CameraMaskCoverage(mask, 100.0, 50), 0.5, 1e-9);
}

TEST(CameraMaskCoverage, ARectangularMaskCutsHardSoNothingHasToBlend) {
  CameraFrameMask mask;
  mask.crop = RectD{10, 10, 80, 80};
  EXPECT_TRUE(CameraMaskIsRectangular(mask));
  EXPECT_DOUBLE_EQ(CameraMaskCoverage(mask, 50, 50), 1.0);
  EXPECT_DOUBLE_EQ(CameraMaskCoverage(mask, 9.9, 50), 0.0);
  EXPECT_DOUBLE_EQ(CameraMaskCoverage(mask, 90.1, 50), 0.0);
}

TEST(ApplyCameraMaskRow, TheRowFastPathAgreesWithTheCoverageItStandsFor) {
  // The mask is applied a row at a time for speed. The two must not be two
  // answers: a circle in the preview and a rounded square in the file is
  // exactly the defect 33.7 calls a defect rather than a tolerance.
  CameraFrameMask mask;
  mask.crop = RectD{4, 2, 24, 24};
  mask.corner_radius = 12;

  constexpr uint32_t kWidth = 32;
  constexpr uint32_t kHeight = 30;
  std::vector<uint8_t> pixels(static_cast<size_t>(kWidth) * kHeight * 4, 0x11);
  for (uint32_t row = 0; row < kHeight; ++row) {
    uint8_t* line = pixels.data() + static_cast<size_t>(row) * kWidth * 4;
    ApplyCameraMaskRow(mask, static_cast<double>(row) + 0.5, kWidth, line);
    for (uint32_t column = 0; column < kWidth; ++column) {
      const double coverage = CameraMaskCoverage(
          mask, static_cast<double>(column) + 0.5, static_cast<double>(row) + 0.5);
      EXPECT_EQ(line[column * 4 + 3],
                static_cast<uint8_t>(coverage * 255.0 + 0.5))
          << "row " << row << " column " << column;
      // And nothing but the alpha byte is touched.
      EXPECT_EQ(line[column * 4 + 0], 0x11);
      EXPECT_EQ(line[column * 4 + 1], 0x11);
      EXPECT_EQ(line[column * 4 + 2], 0x11);
    }
  }
}

TEST(ApplyCameraMaskRow, AnUnconfiguredMaskLeavesTheFrameOpaque) {
  // No crop yet: every pixel is drawn, which is what an uninitialized
  // compositor has to look like rather than an invisible camera.
  const CameraFrameMask mask;
  std::vector<uint8_t> pixels(4 * 4, 0);
  ApplyCameraMaskRow(mask, 0.5, 4, pixels.data());
  for (uint32_t column = 0; column < 4; ++column) {
    EXPECT_EQ(pixels[column * 4 + 3], 0xFF);
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

// ── the movable control strip (spec 33.3) ────────────────────────────────────

// 1920 x 1080 with a 40-pixel taskbar along the bottom: the usable area is what
// every one of these is measured against, and a work area equal to the display
// would not notice if it were not.
constexpr RECT kWorkArea{0, 0, 1920, 1040};
// A second display to the right of the first, taskbar along its top. Its origin
// is not the desktop's, which is what catches a fraction resolved as if it were.
constexpr RECT kSecondWorkArea{1920, 40, 3840, 1080};
constexpr LONG kStripWidth = 360;
constexpr LONG kStripHeight = 46;

RECT StripAt(LONG left, LONG top) {
  return RECT{left, top, left + kStripWidth, top + kStripHeight};
}

TEST(StripSnapPixels, TheSnapDistanceFollowsTheMonitorScale) {
  EXPECT_EQ(StripSnapPixels(1.0), 24);
  EXPECT_EQ(StripSnapPixels(1.5), 36);
  EXPECT_EQ(StripSnapPixels(2.0), 48);
  // A monitor that reports no usable scale still snaps, at the unscaled
  // distance: a snap of zero is a strip that never lands on an edge.
  EXPECT_EQ(StripSnapPixels(0.0), 24);
  EXPECT_EQ(StripSnapPixels(-1.0), 24);
  EXPECT_EQ(StripSnapPixels(std::nan("")), 24);
}

TEST(FractionalStripFrame, TheFractionIsResolvedAgainstTheUsableArea) {
  const RECT frame =
      FractionalStripFrame(kWorkArea, 0.25, 0.5, kStripWidth, kStripHeight);

  EXPECT_EQ(frame.left, 480);
  EXPECT_EQ(frame.top, 520) << "half of 1040, not half of 1080";
  EXPECT_EQ(frame.right - frame.left, kStripWidth);
  EXPECT_EQ(frame.bottom - frame.top, kStripHeight);
}

TEST(FractionalStripFrame, TheFractionIsRelativeToTheDisplayItWasStoredAgainst) {
  const RECT frame =
      FractionalStripFrame(kSecondWorkArea, 0.5, 0.0, kStripWidth, kStripHeight);

  EXPECT_EQ(frame.left, 1920 + 960);
  EXPECT_EQ(frame.top, 40) << "the top of the usable area, under that taskbar";
}

TEST(FractionalStripFrame, AFractionOutsideTheUnitSquareIsClampedNotRefused) {
  // The same rule OverlayStripPosition.tryFrom applies in Dart: a fraction
  // slightly outside the unit square is a rounding artefact of a resolution
  // change, not a lost spot.
  const RECT high = FractionalStripFrame(kWorkArea, 1.4, 3.0, kStripWidth, kStripHeight);
  EXPECT_EQ(high.left, 1920 - kStripWidth);
  EXPECT_EQ(high.top, 1040 - kStripHeight);

  const RECT low = FractionalStripFrame(kWorkArea, -0.2, -5.0, kStripWidth, kStripHeight);
  EXPECT_EQ(low.left, 0);
  EXPECT_EQ(low.top, 0);

  const RECT malformed =
      FractionalStripFrame(kWorkArea, std::nan(""), std::nan(""), kStripWidth, kStripHeight);
  EXPECT_EQ(malformed.left, 0) << "a NaN is the near edge, never a NaN rectangle";
  EXPECT_EQ(malformed.top, 0);
}

TEST(FractionalStripFrame, AStripWiderThanTheDisplayStartsAtTheNearEdge) {
  // A 360-point strip on a 200-pixel-wide usable area cannot fit. Pinned to the
  // left, where its controls start, rather than centred with both ends off.
  constexpr RECT tiny{0, 0, 200, 100};
  const RECT frame = FractionalStripFrame(tiny, 0.9, 0.9, kStripWidth, kStripHeight);

  EXPECT_EQ(frame.left, 0);
  EXPECT_EQ(frame.top, 100 - kStripHeight);
  EXPECT_EQ(frame.right - frame.left, kStripWidth) << "the size is never shrunk to fit";
}

TEST(FractionalStripFrame, AUsableAreaWithNoExtentStillProducesAFrame) {
  // What a monitor query that failed leaves behind. There is no right place to
  // put the strip on a display of no size; there is still no excuse for a
  // rectangle with a NaN or a negative extent in it.
  constexpr RECT empty{0, 0, 0, 0};
  const RECT frame = FractionalStripFrame(empty, 0.5, 0.5, kStripWidth, kStripHeight);

  EXPECT_EQ(frame.left, 0);
  EXPECT_EQ(frame.top, 0);
  EXPECT_EQ(frame.right - frame.left, kStripWidth);
  EXPECT_EQ(frame.bottom - frame.top, kStripHeight);
}

TEST(ClampToWorkArea, ADragThatEndedOffTheUsableAreaComesBack) {
  const RECT past_the_corner = ClampToWorkArea(kWorkArea, StripAt(1800, 1020));
  EXPECT_EQ(past_the_corner.left, 1920 - kStripWidth);
  EXPECT_EQ(past_the_corner.top, 1040 - kStripHeight)
      << "the taskbar's 40 pixels stay uncovered";

  const RECT before_the_origin = ClampToWorkArea(kWorkArea, StripAt(-50, -30));
  EXPECT_EQ(before_the_origin.left, 0);
  EXPECT_EQ(before_the_origin.top, 0);
}

TEST(ClampToWorkArea, AFrameAlreadyInsideIsLeftExactlyWhereItIs) {
  const RECT frame = StripAt(640, 500);
  const RECT clamped = ClampToWorkArea(kWorkArea, frame);

  EXPECT_EQ(clamped.left, frame.left);
  EXPECT_EQ(clamped.top, frame.top);
  EXPECT_EQ(clamped.right, frame.right);
  EXPECT_EQ(clamped.bottom, frame.bottom);
}

TEST(StripPositionRatio, TheRoundTripReproducesTheFrameItWasMeasuredFrom) {
  // The property the whole design rests on: what the host reports at teardown
  // has to put the strip back where it was on the next session.
  for (const RECT& frame : {StripAt(0, 0), StripAt(480, 520), StripAt(37, 991),
                            StripAt(1920 - kStripWidth, 1040 - kStripHeight)}) {
    double x = 0;
    double y = 0;
    ASSERT_TRUE(StripPositionRatio(kWorkArea, frame, &x, &y));
    EXPECT_GE(x, 0.0);
    EXPECT_LE(x, 1.0);
    const RECT resolved =
        FractionalStripFrame(kWorkArea, x, y, kStripWidth, kStripHeight);
    EXPECT_EQ(resolved.left, frame.left) << "left " << frame.left;
    EXPECT_EQ(resolved.top, frame.top) << "top " << frame.top;
  }
}

TEST(StripPositionRatio, AUsableAreaWithNoExtentHasNoFractionToReport) {
  // A fraction of nothing says nothing. The contract spells this as a null
  // reply, and Dart then keeps the position it already had — failing to read
  // where the strip is is not the user having moved it back.
  constexpr RECT empty{0, 0, 0, 0};
  double x = -1;
  double y = -1;

  EXPECT_FALSE(StripPositionRatio(empty, StripAt(0, 0), &x, &y));
  EXPECT_DOUBLE_EQ(x, -1.0) << "the caller's value is left alone";
  EXPECT_DOUBLE_EQ(y, -1.0);
}

TEST(StripPositionRatio, AFrameOutsideTheUsableAreaStillReportsAUsableFraction) {
  // What a window Windows moved when a display was unplugged looks like before
  // anything has clamped it.
  double x = 0;
  double y = 0;
  ASSERT_TRUE(StripPositionRatio(kWorkArea, StripAt(-400, 4000), &x, &y));

  EXPECT_DOUBLE_EQ(x, 0.0);
  EXPECT_DOUBLE_EQ(y, 1.0);
}

TEST(SnapStripFrame, AnEdgeWithinTheThresholdTakesTheStrip) {
  const LONG snap = StripSnapPixels(1.0);

  EXPECT_EQ(SnapStripFrame(kWorkArea, StripAt(18, 500), snap).left, 0);
  EXPECT_EQ(SnapStripFrame(kWorkArea, StripAt(1920 - kStripWidth - 9, 500), snap).left,
            1920 - kStripWidth);
  EXPECT_EQ(SnapStripFrame(kWorkArea, StripAt(640, 20), snap).top, 0);
  EXPECT_EQ(SnapStripFrame(kWorkArea, StripAt(640, 1040 - kStripHeight - 20), snap).top,
            1040 - kStripHeight);
}

TEST(SnapStripFrame, TheHorizontalCentreIsASnapTargetToo) {
  const LONG centred = (1920 - kStripWidth) / 2;
  const RECT frame = SnapStripFrame(kWorkArea, StripAt(centred + 15, 500), 24);

  EXPECT_EQ(frame.left, centred);
  EXPECT_EQ(frame.top, 500) << "nothing snaps vertically to the middle";
}

TEST(SnapStripFrame, BeyondTheThresholdNothingMoves) {
  const RECT frame = StripAt(40, 300);
  const RECT snapped = SnapStripFrame(kWorkArea, frame, 24);

  EXPECT_EQ(snapped.left, frame.left);
  EXPECT_EQ(snapped.top, frame.top);
}

TEST(SnapStripFrame, TheNearestCandidateWins) {
  // A usable area small enough that the left edge and the centre are both in
  // range at once: 0, 20 and 40 are the three candidates.
  constexpr RECT narrow{0, 0, 400, 200};
  const RECT frame = SnapStripFrame(narrow, StripAt(15, 100), 24);

  EXPECT_EQ(frame.left, 20) << "the centre, five away, not the edge fifteen away";
}

TEST(SnapStripFrame, ASnapThatWouldPushTheStripOffTheEdgeCannot) {
  // 360 points of strip on a 300-pixel usable area: the right-edge candidate is
  // at -60 and the centre at -30, both outside the display. The clamp runs after
  // the snap precisely so neither can be the answer.
  constexpr RECT narrow{0, 0, 300, 200};
  const RECT frame = SnapStripFrame(narrow, StripAt(-50, 100), 24);

  EXPECT_EQ(frame.left, 0);
  EXPECT_EQ(frame.right - frame.left, kStripWidth);
}

TEST(SnapStripFrame, SnappingAnAlreadySnappedFrameChangesNothing) {
  // Idempotent because two things snap: the end of the drag loop and the
  // fallback behind it, and they must not fight.
  const LONG snap = StripSnapPixels(1.0);
  const RECT once = SnapStripFrame(kWorkArea, StripAt(12, 1030), snap);
  const RECT twice = SnapStripFrame(kWorkArea, once, snap);

  EXPECT_EQ(twice.left, once.left);
  EXPECT_EQ(twice.top, once.top);
  EXPECT_EQ(once.left, 0);
  EXPECT_EQ(once.top, 1040 - kStripHeight);
}

TEST(SnapStripFrame, WithoutAThresholdItStillClamps) {
  const RECT frame = SnapStripFrame(kWorkArea, StripAt(1900, 1035), 0);

  EXPECT_EQ(frame.left, 1920 - kStripWidth);
  EXPECT_EQ(frame.top, 1040 - kStripHeight);
}

TEST(IsUsableWorkArea, ADisplayWithRoomOnItIsUsable) {
  EXPECT_TRUE(IsUsableWorkArea(kWorkArea));
  EXPECT_TRUE(IsUsableWorkArea(kSecondWorkArea));
}

TEST(IsUsableWorkArea, TheRectangleAFailedMonitorReadLeavesBehindIsNot) {
  // GetMonitorInfoW leaves its structure zeroed when the handle no longer names
  // a monitor — one removed between the check that it was live and the read —
  // and resolving anything against that rectangle puts the strip at the virtual
  // desktop's origin, which need not be on a display at all.
  EXPECT_FALSE(IsUsableWorkArea(RECT{}));
  EXPECT_FALSE(IsUsableWorkArea(RECT{100, 100, 100, 500}));
  EXPECT_FALSE(IsUsableWorkArea(RECT{100, 100, 500, 100}));
  EXPECT_FALSE(IsUsableWorkArea(RECT{500, 500, 100, 100}));
}

TEST(ShouldBeginOverlayMove, AHeldButtonOnTheStripStartsTheMove) {
  EXPECT_TRUE(ShouldBeginOverlayMove(true, false, true));
}

TEST(ShouldBeginOverlayMove, AButtonAlreadyReleasedDropsTheRequest) {
  // The request is acted on a turn of the message loop after it was made, and
  // the operating system's move loop ends on the *next* button release: begun
  // with nothing held, it would drag the strip around behind a button nobody is
  // pressing until the user clicked to put it down.
  EXPECT_FALSE(ShouldBeginOverlayMove(true, false, false));
}

TEST(ShouldBeginOverlayMove, ASecondRequestInsideARunningLoopIsDropped) {
  // The move loop pumps the message queue, so a second posted request is
  // dispatched mid-drag. One gesture, one loop.
  EXPECT_FALSE(ShouldBeginOverlayMove(true, true, true));
}

TEST(ShouldBeginOverlayMove, AnOverlayThatIsNotDraggableNeverMoves) {
  // The window-mode camera preview: a separate captioned object that is not the
  // picture-in-picture, so dragging it would move a window standing for nothing
  // (design 1e, spec 33.5). The menu is never draggable at all.
  EXPECT_FALSE(ShouldBeginOverlayMove(false, false, true));
}

TEST(FractionalStripFrame, TheStoredFractionSurvivesAUsableAreaThatShrinksAndReturns) {
  // The ratchet this is here to prevent. A strip left at 0.80 of a 1920-wide
  // usable area sits at 1536; a display that drops to 1280 and comes back has
  // to put it back at 1536, and only the *stored* fraction can do that.
  constexpr RECT wide{0, 0, 1920, 1040};
  constexpr RECT narrow{0, 0, 1280, 1040};
  const RECT placed = FractionalStripFrame(wide, 0.8, 0.5, kStripWidth, kStripHeight);
  ASSERT_EQ(placed.left, 1536);

  const RECT shrunk = FractionalStripFrame(narrow, 0.8, 0.5, kStripWidth, kStripHeight);
  EXPECT_EQ(shrunk.left, 1280 - kStripWidth) << "0.8 of 1280 leaves the strip no room";
  EXPECT_EQ(FractionalStripFrame(wide, 0.8, 0.5, kStripWidth, kStripHeight).left,
            placed.left);

  // And why re-deriving the fraction from the clamped frame cannot be allowed
  // to replace it: the same round trip then lands 156 pixels short, and every
  // taskbar change after it takes a little more.
  double x = 0;
  double y = 0;
  ASSERT_TRUE(StripPositionRatio(narrow, shrunk, &x, &y));
  EXPECT_EQ(FractionalStripFrame(wide, x, y, kStripWidth, kStripHeight).left, 1380);
}

// ── the input menu's placement (spec 33.4) ───────────────────────────────────

// A strip 360 x 46 docked at the top centre of a 1920 x 1040 usable area, which
// is where the default placement puts it.
constexpr RECT kMenuWorkArea{0, 0, 1920, 1040};
constexpr RECT kStripFrame{780, 6, 1140, 52};
constexpr LONG kMenuGap = 6;

TEST(ResolveInputMenuFrame, TheMenuOpensUnderTheStripWhenThereIsRoom) {
  const RECT frame =
      ResolveInputMenuFrame(kMenuWorkArea, kStripFrame, 900, 240, 200, kMenuGap);
  EXPECT_EQ(frame.top, kStripFrame.bottom + kMenuGap);
  EXPECT_EQ(frame.bottom - frame.top, 200);
}

TEST(ResolveInputMenuFrame, TheMenuIsCentredOnTheChevronThatAskedForIt) {
  // Not on the strip: the chevron is what the user pressed, and only Flutter
  // knew where inside the strip it ended up.
  const RECT frame =
      ResolveInputMenuFrame(kMenuWorkArea, kStripFrame, 900, 240, 200, kMenuGap);
  EXPECT_EQ(frame.left + (frame.right - frame.left) / 2, 900);
}

TEST(ResolveInputMenuFrame, AMenuThatWouldRunOffTheBottomFlipsAboveTheStrip) {
  constexpr RECT low_strip{780, 900, 1140, 946};
  const RECT frame =
      ResolveInputMenuFrame(kMenuWorkArea, low_strip, 900, 240, 200, kMenuGap);
  EXPECT_EQ(frame.bottom, low_strip.top - kMenuGap);
  EXPECT_EQ(frame.top, low_strip.top - kMenuGap - 200);
}

TEST(ResolveInputMenuFrame, WithNoRoomOnEitherSideItTakesTheSpaceBelow) {
  // A menu taller than the usable area. Overlapping the strip is legible;
  // hanging off the top of the screen is not.
  constexpr RECT centred{780, 500, 1140, 546};
  const RECT frame =
      ResolveInputMenuFrame(kMenuWorkArea, centred, 900, 240, 1200, kMenuGap);
  EXPECT_GE(frame.top, kMenuWorkArea.top);
  EXPECT_LE(frame.left, kMenuWorkArea.right);
}

TEST(ResolveInputMenuFrame, AChevronNearTheEdgeStillLandsInsideTheUsableArea) {
  // Clamped to the usable area, always: 33.4's "aligned to the chevron" never
  // beats 6's "never off the screen".
  const RECT frame =
      ResolveInputMenuFrame(kMenuWorkArea, kStripFrame, 1918, 240, 200, kMenuGap);
  EXPECT_LE(frame.right, kMenuWorkArea.right);
  EXPECT_GE(frame.left, kMenuWorkArea.left);
  EXPECT_EQ(frame.right - frame.left, 240);
}

TEST(ResolveInputMenuFrame, TheMenuNeverCoversTheTaskbar) {
  // rcWork, never rcMonitor: a menu resolved against the whole display would
  // open over the taskbar (spec 6).
  constexpr RECT taskbar_work_area{0, 0, 1920, 1000};
  constexpr RECT bottom_strip{780, 900, 1140, 946};
  const RECT frame = ResolveInputMenuFrame(taskbar_work_area, bottom_strip, 900, 240,
                                           200, kMenuGap);
  EXPECT_LE(frame.bottom, taskbar_work_area.bottom);
}

TEST(ResolveInputMenuFrame, ASizeOfNothingIsAFrameOfNothingNotANegativeOne) {
  const RECT frame =
      ResolveInputMenuFrame(kMenuWorkArea, kStripFrame, 900, -10, -10, kMenuGap);
  EXPECT_EQ(frame.right - frame.left, 0);
  EXPECT_EQ(frame.bottom - frame.top, 0);
}

// ── moving the strip by keyboard (spec 33.3) ─────────────────────────────────

TEST(NudgeStripFrame, TheStripMovesByExactlyWhatWasAsked) {
  constexpr RECT frame{800, 400, 1160, 446};
  const RECT moved = NudgeStripFrame(kMenuWorkArea, frame, 8, -8, 0);
  EXPECT_EQ(moved.left, 808);
  EXPECT_EQ(moved.top, 392);
  EXPECT_EQ(moved.right - moved.left, frame.right - frame.left);
}

TEST(NudgeStripFrame, TheKeyboardCannotPushTheStripOffTheUsableArea) {
  constexpr RECT frame{1900, 400, 2260, 446};
  const RECT moved = NudgeStripFrame(kMenuWorkArea, frame, 32, 0, 0);
  EXPECT_LE(moved.right, kMenuWorkArea.right);
  EXPECT_EQ(moved.right - moved.left, 360);
}

TEST(NudgeStripFrame, TheKeyboardSnapsWhereADragWould) {
  // Arrow keys and a pointer must not be able to leave the strip in two
  // different places, so the same snap runs on both paths.
  constexpr RECT frame{800, 40, 1160, 86};
  const RECT nudged = NudgeStripFrame(kMenuWorkArea, frame, 0, -20, 24);
  const RECT dragged = SnapStripFrame(kMenuWorkArea, RECT{800, 20, 1160, 66}, 24);
  EXPECT_EQ(nudged.top, kMenuWorkArea.top);
  EXPECT_EQ(nudged.top, dragged.top);
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

  // Ten seconds of wall time, four of them paused: five seconds were recorded
  // before the pause and one after it, so the sample captured at wall ten sits
  // six seconds into the file. The subtraction is the whole point — the
  // encoded duration has to equal the elapsed time the strip shows (spec 9).
  //
  // Asserted 5 until this stage, which is the wall time of the pause rather
  // than the media time of the sample. The arithmetic under test never
  // produced it.
  EXPECT_EQ(clock.MediaTime100ns(10 * kSecond), 6 * kSecond);
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

TEST(RecordingConfig, NoInputDeviceIsChosenUntilOneIs) {
  // Empty means the platform's own default, which is exactly what an
  // unconfigured session recorded before device selection existed (spec 33.2).
  const RecordingConfig config;

  EXPECT_TRUE(config.camera_device_id.empty());
  EXPECT_TRUE(config.microphone_device_id.empty());
  EXPECT_TRUE(config.system_audio_device_id.empty());
}

// ── input devices (spec 33.2) ────────────────────────────────────────────────

MediaDeviceInfo Device(std::string id, bool is_default = false) {
  MediaDeviceInfo device;
  device.id = std::move(id);
  device.kind = MediaDeviceKind::kMicrophone;
  device.is_system_default = is_default;
  return device;
}

// An enumerated camera. An empty id is a source with no Media Foundation
// symbolic link — a virtual camera the caller can never name.
MediaDeviceInfo Camera(std::string id, bool is_default = false) {
  MediaDeviceInfo device = Device(std::move(id), is_default);
  device.kind = MediaDeviceKind::kCamera;
  return device;
}

TEST(MediaDeviceKindName, EveryKindKeepsItsWireSpelling) {
  // These strings are the `kind` on every device map, on the metering calls and
  // on the level events, and Dart maps them straight onto its own enum by name.
  // A rename on either side is caught by nothing else.
  const std::vector<std::pair<MediaDeviceKind, std::string>> expected = {
      {MediaDeviceKind::kCamera, "camera"},
      {MediaDeviceKind::kMicrophone, "microphone"},
      {MediaDeviceKind::kSystemAudio, "systemAudio"},
  };
  ASSERT_EQ(expected.size(), kMediaDeviceKindCount) << "Dart declares three kinds";
  for (const auto& [kind, name] : expected) {
    EXPECT_EQ(std::string(MediaDeviceKindName(kind)), name);
  }
}

TEST(MediaDeviceKindFromName, AnUnknownNameResolvesToNothingNeverToAMember) {
  // Deliberately not a fallback: a decoding mismatch that resolved to any
  // member would file a camera under the microphone.
  MediaDeviceKind kind = MediaDeviceKind::kCamera;
  EXPECT_TRUE(MediaDeviceKindFromName("systemAudio", &kind));
  EXPECT_EQ(kind, MediaDeviceKind::kSystemAudio);

  EXPECT_FALSE(MediaDeviceKindFromName("gramophone", &kind));
  EXPECT_EQ(kind, MediaDeviceKind::kSystemAudio) << "the out parameter is untouched";
  EXPECT_FALSE(MediaDeviceKindFromName("", &kind));
  EXPECT_FALSE(MediaDeviceKindFromName("Microphone", &kind)) << "case matters";
}

TEST(DeviceKindCapabilities, WindowsOffersAChoiceForEveryKind) {
  // WASAPI loopback is per render endpoint, so "which output am I recording?"
  // has a real answer here that it does not have on macOS.
  EXPECT_EQ(SelectableDeviceKindNames(),
            (std::vector<std::string>{"camera", "microphone", "systemAudio"}));
}

TEST(DeviceKindCapabilities, OnlyTheMicrophoneReportsALevel) {
  EXPECT_EQ(MeterableDeviceKindNames(), (std::vector<std::string>{"microphone"}));
  EXPECT_TRUE(IsMeterableDeviceKind(MediaDeviceKind::kMicrophone));
  EXPECT_FALSE(IsMeterableDeviceKind(MediaDeviceKind::kCamera));
  EXPECT_FALSE(IsMeterableDeviceKind(MediaDeviceKind::kSystemAudio));
}

TEST(OrderDevicesDefaultFirst, TheDefaultLeadsAndNothingElseMoves) {
  std::vector<MediaDeviceInfo> devices = {Device("a"), Device("b"), Device("c", true),
                                          Device("d")};
  OrderDevicesDefaultFirst(&devices);

  std::vector<std::string> ids;
  for (const MediaDeviceInfo& device : devices) {
    ids.push_back(device.id);
  }
  EXPECT_EQ(ids, (std::vector<std::string>{"c", "a", "b", "d"}))
      << "a rotate, not a swap: everything else keeps the platform's own order";
}

TEST(OrderDevicesDefaultFirst, AListWithNoDefaultIsLeftAlone) {
  std::vector<MediaDeviceInfo> devices = {Device("a"), Device("b")};
  OrderDevicesDefaultFirst(&devices);

  ASSERT_EQ(devices.size(), 2u);
  EXPECT_EQ(devices[0].id, "a");
  EXPECT_EQ(devices[1].id, "b");
}

TEST(OrderDevicesDefaultFirst, AnEmptyListIsAnAnswerNotACrash) {
  // No camera attached is a legitimate reply, not a failure.
  std::vector<MediaDeviceInfo> devices;
  OrderDevicesDefaultFirst(&devices);
  EXPECT_TRUE(devices.empty());
  OrderDevicesDefaultFirst(nullptr);
}

TEST(SelectDeviceIndex, ARequestedDeviceIsTheOneThatOpens) {
  const std::vector<MediaDeviceInfo> devices = {Device("a", true), Device("b"),
                                               Device("c")};
  EXPECT_EQ(SelectDeviceIndex(devices, "c"), 2u);
}

TEST(SelectDeviceIndex, NoRequestMeansTheSystemDefault) {
  // A null device id on the configuration means exactly this, which is what
  // this plugin opened before device selection existed.
  const std::vector<MediaDeviceInfo> devices = {Device("a"), Device("b", true)};
  EXPECT_EQ(SelectDeviceIndex(devices, ""), 1u);
}

TEST(SelectDeviceIndex, AStaleIdFallsBackAndNeverFails) {
  // A wrong microphone is a degraded recording; a refused prepare is no
  // recording at all.
  const std::vector<MediaDeviceInfo> devices = {Device("a"), Device("b", true)};
  EXPECT_EQ(SelectDeviceIndex(devices, "unplugged"), 1u);
}

TEST(SelectDeviceIndex, WithoutADefaultTheFirstEntryIsTheDefault) {
  // Media Foundation names no default camera: the first source it enumerates is
  // the one the recorder opens.
  const std::vector<MediaDeviceInfo> devices = {Device("a"), Device("b")};
  EXPECT_EQ(SelectDeviceIndex(devices, "gone"), 0u);
  EXPECT_EQ(SelectDeviceIndex(devices, ""), 0u);
}

TEST(SelectDeviceIndex, AnEmptyListSelectsNothing) {
  EXPECT_EQ(SelectDeviceIndex({}, "a"), kNoDeviceIndex);
}

TEST(RetainSelectableCameras, ANamelessSourceIsNeitherListedNorOpened) {
  // A virtual camera with no symbolic link has no id: it can be neither listed
  // nor persisted, and a capture that opened it anyway would record a camera
  // the user was never offered.
  std::vector<MediaDeviceInfo> devices = {Camera(""), Camera("logitech"),
                                          Camera("obs")};
  std::vector<size_t> sources;
  RetainSelectableCameras(&devices, &sources);

  ASSERT_EQ(devices.size(), 2u);
  EXPECT_EQ(devices[0].id, "logitech");
  EXPECT_TRUE(devices[0].is_system_default)
      << "the first source that can be named is the one the recorder opens";
  EXPECT_FALSE(devices[1].is_system_default);
  EXPECT_EQ(sources, (std::vector<size_t>{1u, 2u}))
      << "the enumeration index each survivor came from";
}

TEST(RetainSelectableCameras, TheDefaultMarkIsRecomputedNotInherited) {
  // Media Foundation names no default camera. Marking the first *enumerated*
  // source and only then dropping the nameless ones left the list headless and
  // disagreeing with the camera the capture opened.
  std::vector<MediaDeviceInfo> devices = {Camera("", true), Camera("logitech")};
  RetainSelectableCameras(&devices);

  ASSERT_EQ(devices.size(), 1u);
  EXPECT_EQ(devices[0].id, "logitech");
  EXPECT_TRUE(devices[0].is_system_default);
}

TEST(RetainSelectableCameras, TheSelectionMapsBackOntoTheEnumeratedSources) {
  // What camera_capture.cpp does with the two of these together: select on the
  // filtered list, then open `sources[selected]`.
  std::vector<MediaDeviceInfo> devices = {Camera(""), Camera("a"), Camera("b")};
  std::vector<size_t> sources;
  RetainSelectableCameras(&devices, &sources);

  EXPECT_EQ(sources[SelectDeviceIndex(devices, "b")], 2u);
  EXPECT_EQ(sources[SelectDeviceIndex(devices, "")], 1u)
      << "nothing chosen opens the first namable source, never the nameless one";
}

TEST(RetainSelectableCameras, NothingNamableIsAnEmptyListNotTheWrongCamera) {
  std::vector<MediaDeviceInfo> devices = {Camera(""), Camera("")};
  std::vector<size_t> sources;
  RetainSelectableCameras(&devices, &sources);

  EXPECT_TRUE(devices.empty());
  EXPECT_TRUE(sources.empty());
  EXPECT_EQ(SelectDeviceIndex(devices, ""), kNoDeviceIndex)
      << "no camera is available, which is what the capture reports";
  RetainSelectableCameras(nullptr, &sources);
}

// ── input levels ─────────────────────────────────────────────────────────────

TEST(ClampUnitLevel, ALevelAboveFullScaleIsClippingNotAnOverflowingBar) {
  EXPECT_DOUBLE_EQ(ClampUnitLevel(1.4), 1.0);
  EXPECT_DOUBLE_EQ(ClampUnitLevel(-0.2), 0.0);
  EXPECT_DOUBLE_EQ(ClampUnitLevel(0.5), 0.5);
  EXPECT_DOUBLE_EQ(ClampUnitLevel(std::nan("")), 0.0)
      << "a broken device reads as silence, not as a NaN in the bar";
}

TEST(LevelAccumulator, NothingIsAccumulatedUntilSomethingIsMetering) {
  // A capture nobody is watching does no level arithmetic at all.
  LevelAccumulator accumulator;
  const std::vector<float> samples = {0.5f, -0.5f};
  accumulator.Add(samples.data(), samples.size());

  const InputLevelSample level = accumulator.Take();
  EXPECT_DOUBLE_EQ(level.peak, 0.0);
  EXPECT_DOUBLE_EQ(level.rms, 0.0);
}

TEST(LevelAccumulator, ThePeakIsTheLoudestSampleOfTheWholeInterval) {
  // Several packets arrive between two 20 Hz reads; the level covers all of
  // them, not just the last.
  LevelAccumulator accumulator;
  accumulator.SetEnabled(true);
  const std::vector<float> quiet = {0.1f, -0.1f};
  const std::vector<float> loud = {0.25f, -0.75f};
  accumulator.Add(quiet.data(), quiet.size());
  accumulator.Add(loud.data(), loud.size());

  const InputLevelSample level = accumulator.Take();
  EXPECT_DOUBLE_EQ(level.peak, 0.75);
  EXPECT_NEAR(level.rms, std::sqrt((0.01 + 0.01 + 0.0625 + 0.5625) / 4.0), 1e-9);
}

TEST(LevelAccumulator, TakingStartsAFreshInterval) {
  LevelAccumulator accumulator;
  accumulator.SetEnabled(true);
  const std::vector<float> samples = {1.0f};
  accumulator.Add(samples.data(), samples.size());
  (void)accumulator.Take();

  const InputLevelSample level = accumulator.Take();
  EXPECT_DOUBLE_EQ(level.peak, 0.0) << "a stale peak would freeze the bar";
  EXPECT_DOUBLE_EQ(level.rms, 0.0);
}

TEST(LevelAccumulator, ASilentPacketIsALevelNotTheAbsenceOfOne) {
  LevelAccumulator accumulator;
  accumulator.SetEnabled(true);
  const std::vector<float> loud = {1.0f};
  accumulator.Add(loud.data(), loud.size());
  accumulator.Add(nullptr, 3);

  const InputLevelSample level = accumulator.Take();
  EXPECT_DOUBLE_EQ(level.peak, 1.0);
  EXPECT_NEAR(level.rms, std::sqrt(1.0 / 4.0), 1e-9)
      << "silence pulls the mean square down instead of holding the bar up";
}

TEST(LevelAccumulator, ClippingSamplesAreClampedNotDrawnPastTheEnd) {
  LevelAccumulator accumulator;
  accumulator.SetEnabled(true);
  const std::vector<float> hot = {1.5f, -1.5f};
  accumulator.Add(hot.data(), hot.size());

  const InputLevelSample level = accumulator.Take();
  EXPECT_DOUBLE_EQ(level.peak, 1.0);
  EXPECT_DOUBLE_EQ(level.rms, 1.0);
}

TEST(LevelAccumulator, SwitchingOffDiscardsTheIntervalInProgress) {
  LevelAccumulator accumulator;
  accumulator.SetEnabled(true);
  const std::vector<float> samples = {1.0f};
  accumulator.Add(samples.data(), samples.size());
  accumulator.SetEnabled(false);
  accumulator.SetEnabled(true);

  EXPECT_DOUBLE_EQ(accumulator.Take().peak, 0.0);
}

TEST(LevelAccumulator, TheLiveFlagSaysWhoOwnsTheDevice) {
  // While a recording holds the microphone the meter reads its levels from
  // here and opens no second handle of its own.
  LevelAccumulator accumulator;
  EXPECT_FALSE(accumulator.live());
  accumulator.SetLive(true);
  EXPECT_TRUE(accumulator.live());
  accumulator.SetLive(false);
  EXPECT_FALSE(accumulator.live());
}

TEST(LevelAccumulator, ConcurrentWritesAndReadsDoNotTear) {
  LevelAccumulator accumulator;
  accumulator.SetEnabled(true);
  std::atomic<bool> stop{false};
  std::thread producer([&accumulator, &stop]() {
    const std::vector<float> samples = {0.5f, -0.25f};
    while (!stop.load()) {
      accumulator.Add(samples.data(), samples.size());
    }
  });
  for (int i = 0; i < 1000; ++i) {
    const InputLevelSample level = accumulator.Take();
    EXPECT_GE(level.peak, 0.0);
    EXPECT_LE(level.peak, 1.0);
    EXPECT_LE(level.rms, level.peak + 1e-9);
  }
  stop.store(true);
  producer.join();
}

// ── metering subscriptions ───────────────────────────────────────────────────

TEST(MeteringSubscriptions, TwoCallersMakeOneTap) {
  MeteringSubscriptions subscriptions;
  EXPECT_TRUE(subscriptions.Retain(MediaDeviceKind::kMicrophone))
      << "the first reference opens the tap";
  EXPECT_FALSE(subscriptions.Retain(MediaDeviceKind::kMicrophone))
      << "the second shares it";

  EXPECT_FALSE(subscriptions.Release(MediaDeviceKind::kMicrophone));
  EXPECT_TRUE(subscriptions.IsActive(MediaDeviceKind::kMicrophone));
  EXPECT_TRUE(subscriptions.Release(MediaDeviceKind::kMicrophone))
      << "the tap closes with the last subscriber";
  EXPECT_FALSE(subscriptions.IsActive(MediaDeviceKind::kMicrophone));
}

TEST(MeteringSubscriptions, AStopWithNothingRunningIsANoOp) {
  MeteringSubscriptions subscriptions;
  EXPECT_FALSE(subscriptions.Release(MediaDeviceKind::kMicrophone));
  EXPECT_FALSE(subscriptions.AnyActive());
  // And it does not go negative: the next start still opens the tap.
  EXPECT_TRUE(subscriptions.Retain(MediaDeviceKind::kMicrophone));
}

TEST(MeteringSubscriptions, EachKindIsCountedSeparately) {
  MeteringSubscriptions subscriptions;
  EXPECT_TRUE(subscriptions.Retain(MediaDeviceKind::kMicrophone));
  EXPECT_TRUE(subscriptions.Retain(MediaDeviceKind::kCamera));
  EXPECT_TRUE(subscriptions.Release(MediaDeviceKind::kCamera));
  EXPECT_TRUE(subscriptions.IsActive(MediaDeviceKind::kMicrophone));
}

TEST(MeteringSubscriptions, ClearReportsWhetherAnythingWasOpen) {
  MeteringSubscriptions subscriptions;
  EXPECT_FALSE(subscriptions.Clear());
  subscriptions.Retain(MediaDeviceKind::kMicrophone);
  subscriptions.Retain(MediaDeviceKind::kMicrophone);
  EXPECT_TRUE(subscriptions.Clear()) << "dispose closes a tap however deep it is";
  EXPECT_FALSE(subscriptions.AnyActive());
  EXPECT_FALSE(subscriptions.Clear());
}

// ── the metered device ───────────────────────────────────────────────────────

TEST(MeterTarget, ASecondMeterOnTheSameDeviceSharesTheTap) {
  MeterTarget target;
  EXPECT_TRUE(target.wants_open()) << "a fresh target has nothing open";
  EXPECT_TRUE(target.Point("mic:mv7"));
  target.NoteOpened();
  EXPECT_FALSE(target.wants_open());

  EXPECT_FALSE(target.Point("mic:mv7"))
      << "two meters on one microphone make one tap, not two";
  EXPECT_FALSE(target.wants_open());
}

TEST(MeterTarget, ADifferentDeviceRePointsTheTapRatherThanAddingOne) {
  // The bar sits under a device row: a start naming another microphone has to
  // move the tap, or picking between two microphones by speaking into them does
  // not work at all (spec 33.2).
  MeterTarget target;
  target.Point("mic:mv7");
  target.NoteOpened();

  EXPECT_TRUE(target.Point("mic:webcam"));
  EXPECT_TRUE(target.wants_open());
  EXPECT_EQ(target.device_id(), "mic:webcam");
}

TEST(MeterTarget, ThePlatformDefaultIsADeviceLikeAnyOther) {
  // An empty id means the platform default, the same meaning it has on the
  // recording configuration — and moving to it is a re-point like any other.
  MeterTarget target;
  target.Point("mic:mv7");
  target.NoteOpened();

  EXPECT_TRUE(target.Point(""));
  EXPECT_TRUE(target.device_id().empty());
  EXPECT_TRUE(target.wants_open());
}

TEST(MeterTarget, ADeviceListChangeReOpensWithoutChangingTheDevice) {
  // Without this the tap goes on reading the endpoint that used to be the
  // default while the next recording opens the new one.
  MeterTarget target;
  target.Point("");
  target.NoteOpened();

  target.Reopen();
  EXPECT_TRUE(target.wants_open());
  EXPECT_TRUE(target.device_id().empty());
}

TEST(MeterTarget, ATapThatWasLostIsOpenedAgain) {
  MeterTarget target;
  target.Point("mic:mv7");
  target.NoteOpened();
  target.NoteClosed();

  EXPECT_TRUE(target.wants_open());
  EXPECT_FALSE(target.Point("mic:mv7")) << "the same device, still waiting to open";
  EXPECT_TRUE(target.wants_open());
}

TEST(RetryBackoff, TheFirstAttemptKeepsTheTickAndTheRestBackOff) {
  // With no capture endpoint at all, every tick is a fresh CoCreateInstance and
  // GetDefaultAudioEndpoint for a bar that cannot move.
  RetryBackoff backoff(std::chrono::milliseconds(50), std::chrono::milliseconds(400));
  EXPECT_EQ(backoff.Next(), std::chrono::milliseconds(50));
  EXPECT_EQ(backoff.Next(), std::chrono::milliseconds(100));
  EXPECT_EQ(backoff.Next(), std::chrono::milliseconds(200));
  EXPECT_EQ(backoff.Next(), std::chrono::milliseconds(400));
  EXPECT_EQ(backoff.Next(), std::chrono::milliseconds(400)) << "the ceiling holds";
}

TEST(RetryBackoff, SomethingWorkingPutsTheCadenceBack) {
  // A microphone finally plugged in must not be metered at the rate an empty
  // machine backed off to.
  RetryBackoff backoff(std::chrono::milliseconds(50), std::chrono::milliseconds(400));
  backoff.Next();
  backoff.Next();
  backoff.Reset();
  EXPECT_EQ(backoff.Next(), std::chrono::milliseconds(50));
}

// ── device-change bursts ─────────────────────────────────────────────────────

TEST(ChangeCoalescer, OneHeadsetIsOneEvent) {
  // Windows raises a callback per endpoint and per role. Ten of them, answered
  // with three enumerations each, is thirty tasks on a sixteen-slot queue — and
  // the user's next Record answered with "The recorder is busy".
  ChangeCoalescer coalescer(250, 1000);
  EXPECT_FALSE(coalescer.pending());
  EXPECT_FALSE(coalescer.Take(0)) << "nothing to deliver";

  int64_t now = 0;
  for (int i = 0; i < 10; ++i) {
    coalescer.Note(now);
    now += 5;
    EXPECT_FALSE(coalescer.Take(now)) << "the burst is still arriving";
  }
  EXPECT_TRUE(coalescer.pending());
  EXPECT_EQ(coalescer.WaitMs(now), 245);
  EXPECT_TRUE(coalescer.Take(now + 250));
  EXPECT_FALSE(coalescer.pending());
  EXPECT_FALSE(coalescer.Take(now + 1000)) << "and only once";
}

TEST(ChangeCoalescer, ASecondBurstIsASecondEvent) {
  ChangeCoalescer coalescer(250, 1000);
  coalescer.Note(0);
  EXPECT_TRUE(coalescer.Take(250));

  coalescer.Note(1000);
  EXPECT_FALSE(coalescer.Take(1100));
  EXPECT_TRUE(coalescer.Take(1250));
}

TEST(ChangeCoalescer, ADeviceThatNeverSettlesStillReports) {
  // A flapping endpoint would otherwise hold the event off for as long as it
  // kept flapping, and the list would never be re-read at all.
  ChangeCoalescer coalescer(250, 1000);
  int64_t now = 0;
  for (; now < 1000; now += 100) {
    coalescer.Note(now);
    EXPECT_FALSE(coalescer.Take(now));
  }
  coalescer.Note(now);
  EXPECT_TRUE(coalescer.Take(now)) << "the ceiling is what bounds it";
}

TEST(ChangeCoalescer, NothingPendingWaitsToBeWoken) {
  ChangeCoalescer coalescer(250, 1000);
  EXPECT_EQ(coalescer.WaitMs(0), 0)
      << "zero here is 'wait for a notification', not 'deliver now'";
  coalescer.Note(0);
  EXPECT_EQ(coalescer.WaitMs(0), 250);
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

// ── the resource census (spec 19.1) ──────────────────────────────────────────
//
// The mirror of `ResourceCensusTests` in the macOS core. Whether the plugin's
// three contributors report the right numbers is asserted from Dart; what is
// here is the arithmetic and the released-rows rule, which are the parts a
// Flutter-free suite can reach.

TEST(ResourceCensus, SummingAddsEachRowIndependently) {
  ResourceCensus session;
  session.capture_streams = 1;
  session.camera_sessions = 1;
  session.microphone_sessions = 1;
  session.session_timers = 1;
  session.power_assertions = 1;
  session.writers = 1;
  session.compositors = 1;

  ResourceCensus overlays;
  overlays.registered_textures = 1;
  overlays.overlay_engines = 3;
  overlays.event_monitors = 2;

  ResourceCensus meter;
  meter.metering_taps = 1;
  meter.meter_subscriptions = 2;

  const ResourceCensus total = session + overlays + meter;

  ResourceCensus expected;
  expected.capture_streams = 1;
  expected.camera_sessions = 1;
  expected.microphone_sessions = 1;
  expected.metering_taps = 1;
  expected.meter_subscriptions = 2;
  expected.registered_textures = 1;
  expected.overlay_engines = 3;
  expected.event_monitors = 2;
  expected.session_timers = 1;
  expected.power_assertions = 1;
  expected.writers = 1;
  expected.compositors = 1;
  EXPECT_TRUE(total == expected);
}

TEST(ResourceCensus, AnEmptyCensusHasReleasedEverything) {
  EXPECT_TRUE(ResourceCensus().session_resources_released());
}

// Spec 19.1's second table lets a host keep its overlay engines for the life of
// the process. This host does not, but the rule is about the specification
// rather than about Windows, and both halves of the contract have to agree.
TEST(ResourceCensus, KeptOverlayEnginesAreNotHeldSessionResources) {
  ResourceCensus census;
  census.overlay_engines = 3;
  EXPECT_TRUE(census.session_resources_released());
}

TEST(ResourceCensus, EveryOtherRowFailsTheReleasedCheck) {
  int ResourceCensus::*const rows[] = {
      &ResourceCensus::capture_streams,     &ResourceCensus::camera_sessions,
      &ResourceCensus::microphone_sessions, &ResourceCensus::metering_taps,
      &ResourceCensus::meter_subscriptions, &ResourceCensus::registered_textures,
      &ResourceCensus::event_monitors,      &ResourceCensus::session_timers,
      &ResourceCensus::power_assertions,    &ResourceCensus::writers,
      &ResourceCensus::compositors,
  };
  for (int ResourceCensus::*const row : rows) {
    ResourceCensus census;
    census.*row = 1;
    EXPECT_FALSE(census.session_resources_released());
  }
}

TEST(ResourceCensus, EqualityComparesEveryRow) {
  ResourceCensus left;
  ResourceCensus right;
  EXPECT_TRUE(left == right);
  right.compositors = 1;
  EXPECT_TRUE(left != right);
}

// The reference count, not "is anything active": a leaked subscription with no
// tap open is a meter that will re-open a device on the next start.
TEST(MeteringSubscriptions, TotalCountsEveryOutstandingReference) {
  MeteringSubscriptions subscriptions;
  EXPECT_EQ(subscriptions.Total(), 0);

  subscriptions.Retain(MediaDeviceKind::kMicrophone);
  subscriptions.Retain(MediaDeviceKind::kMicrophone);
  subscriptions.Retain(MediaDeviceKind::kCamera);
  EXPECT_EQ(subscriptions.Total(), 3);

  subscriptions.Release(MediaDeviceKind::kMicrophone);
  EXPECT_EQ(subscriptions.Total(), 2);

  subscriptions.Clear();
  EXPECT_EQ(subscriptions.Total(), 0);
}

}  // namespace
}  // namespace relay
