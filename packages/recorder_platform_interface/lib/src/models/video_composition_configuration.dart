import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import 'recording_quality.dart';

/// How the quality preset maps onto a source whose aspect ratio is not 16:9.
///
/// `TECHNICAL_SPEC.md` §10/§30.3 leaves the precise policy **open**, with one
/// hard constraint: the source aspect ratio must not be distorted and content
/// must not be silently cropped. Both values below satisfy that constraint;
/// neither is presented as the resolved answer to §30.3.
enum AspectRatioPolicy {
  /// Fit the source inside the preset's reference box, preserving its aspect
  /// ratio. The canvas takes the source's shape and never exceeds the preset's
  /// pixel budget. No bars, no crop.
  containWithinPreset,

  /// Keep a fixed 16:9 canvas at the preset size and letterbox/pillarbox the
  /// source inside it. No distortion, no crop, at the cost of bars.
  letterboxIntoReferenceCanvas,
}

/// What the pipeline does when the source changes size or aspect mid-session.
///
/// §4.4 is **open**. The one implemented behaviour is the conservative one:
/// the canvas established at `prepare` time is fixed for the whole session and
/// later frames are letterboxed into it, because re-negotiating encoder
/// dimensions mid-stream is the option that risks an unplayable file.
enum SourceGeometryChangePolicy {
  /// Hold the initial canvas; letterbox/pillarbox any differently shaped frame.
  fixedCanvasLetterbox,
}

/// Canvas policy for the video compositor.
@immutable
class VideoCompositionConfiguration {
  const VideoCompositionConfiguration({
    this.aspectRatioPolicy = AspectRatioPolicy.containWithinPreset,
    this.geometryChangePolicy = SourceGeometryChangePolicy.fixedCanvasLetterbox,
  });

  final AspectRatioPolicy aspectRatioPolicy;
  final SourceGeometryChangePolicy geometryChangePolicy;

  /// Resolves the encoded canvas for a source of [sourceWidth] x
  /// [sourceHeight] under [quality].
  ///
  /// Dimensions are rounded to even numbers because H.264 4:2:0 chroma
  /// subsampling requires it.
  /// The most pixels a [RecordingQuality.native] canvas may have: 3840 x 2160.
  ///
  /// Not a quality judgement — an encodability one. H.264 caps frame size in
  /// macroblocks, and a 5K panel's 5120 x 2880 needs a level above 5.2, which
  /// little hardware will take. Above this budget the native canvas is scaled
  /// down proportionally, so "native" stays honest on every display that can be
  /// encoded and degrades to something playable on the ones that cannot,
  /// instead of failing `prepare` with an encoder error the user cannot act on.
  static const int maxNativePixels = 3840 * 2160;

  Size resolveCanvasSize({
    required int sourceWidth,
    required int sourceHeight,
    required RecordingQuality quality,
  }) {
    if (quality.followsSourceResolution) {
      // A source of unknown size has no native resolution to follow. Falling
      // through to the box arithmetic below would compute a 0 x 0 box and
      // clamp it to a 2 x 2 canvas, so the fallback is stated here instead.
      if (sourceWidth <= 0 || sourceHeight <= 0) {
        return Size(
          _even(RecordingQuality.fullHd1080.referenceWidth),
          _even(RecordingQuality.fullHd1080.targetHeight),
        );
      }
      final double budgetScale = _nativeBudgetScale(sourceWidth, sourceHeight);
      return Size(
        _even((sourceWidth * budgetScale).round()),
        _even((sourceHeight * budgetScale).round()),
      );
    }
    final int boxWidth = quality.referenceWidth;
    final int boxHeight = quality.targetHeight;
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      return Size(_even(boxWidth), _even(boxHeight));
    }
    switch (aspectRatioPolicy) {
      case AspectRatioPolicy.letterboxIntoReferenceCanvas:
        return Size(_even(boxWidth), _even(boxHeight));
      case AspectRatioPolicy.containWithinPreset:
        final double scale = math.min(
          boxWidth / sourceWidth,
          boxHeight / sourceHeight,
        );
        // Never upscale a source that is already smaller than the preset box:
        // it would spend bitrate on invented pixels.
        final double applied = math.min(scale, 1.0);
        return Size(
          _even((sourceWidth * applied).round()),
          _even((sourceHeight * applied).round()),
        );
    }
  }

  /// 1.0 for a source inside [maxNativePixels], otherwise the factor that puts
  /// it exactly on the budget. Area scales with the square of the linear
  /// factor, hence the square root.
  static double _nativeBudgetScale(int width, int height) {
    final int pixels = width * height;
    if (pixels <= maxNativePixels) {
      return 1;
    }
    return math.sqrt(maxNativePixels / pixels);
  }

  static double _even(int value) {
    final int clamped = math.max(2, value);
    return (clamped.isEven ? clamped : clamped - 1).toDouble();
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'aspectRatioPolicy': aspectRatioPolicy.name,
    'geometryChangePolicy': geometryChangePolicy.name,
  };

  @override
  bool operator ==(Object other) =>
      other is VideoCompositionConfiguration &&
      other.aspectRatioPolicy == aspectRatioPolicy &&
      other.geometryChangePolicy == geometryChangePolicy;

  @override
  int get hashCode => Object.hash(aspectRatioPolicy, geometryChangePolicy);
}
