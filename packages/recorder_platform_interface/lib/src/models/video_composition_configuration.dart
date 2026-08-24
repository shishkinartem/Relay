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
  Size resolveCanvasSize({
    required int sourceWidth,
    required int sourceHeight,
    required RecordingQuality quality,
  }) {
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
