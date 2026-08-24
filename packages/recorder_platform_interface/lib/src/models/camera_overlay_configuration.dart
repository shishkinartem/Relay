import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

/// Which corner of the output canvas the camera picture-in-picture occupies.
enum CameraOverlayCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Geometry and mirroring of the camera picture-in-picture.
///
/// Every value is configuration, not a compositor constant (§7, §28). The
/// defaults are the ones accepted in
/// `docs/adr/2026-08-22-camera-pip-composition.md`: `0.16 x canvas width`, the
/// camera's own shape, `0.01 x canvas width` margin, lower-right, preview
/// mirrored and output not.
///
/// Ratios rather than pixels, so 720p and 1080p and both display and window
/// canvases share one configuration.
@immutable
class CameraOverlayConfiguration {
  const CameraOverlayConfiguration({
    this.widthRatio = 0.16,
    this.aspectRatio = 16 / 9,
    this.followsSourceAspectRatio = true,
    this.cornerRadius = 0.0,
    this.marginRatio = 0.01,
    this.corner = CameraOverlayCorner.bottomRight,
    this.mirrorPreview = true,
    this.mirrorOutput = false,
  }) : assert(
         widthRatio > 0 && widthRatio <= 1,
         'widthRatio must be in (0, 1]',
       ),
       assert(aspectRatio > 0, 'aspectRatio must be positive'),
       assert(
         marginRatio >= 0 && marginRatio < 1,
         'marginRatio must be in [0, 1)',
       );

  /// Picture-in-picture width as a fraction of the canvas width.
  final double widthRatio;

  /// Width / height of the tile when the camera's own shape is unknown or
  /// [followsSourceAspectRatio] is off. 1.0 is square.
  final double aspectRatio;

  /// Give the tile the camera's own shape.
  ///
  /// A tile shaped differently from the camera can only be filled by cropping
  /// the frame or by stretching it; neither is acceptable, so the compositor
  /// letterboxes instead — and then the tile is partly empty. Taking the
  /// camera's shape removes the choice: the frame lands at its own proportions,
  /// whole, at every canvas size.
  final bool followsSourceAspectRatio;

  /// Corner radius in canvas pixels. 0 keeps the square wireframe look.
  final double cornerRadius;

  /// Margin from both canvas edges as a fraction of the canvas width.
  final double marginRatio;

  final CameraOverlayCorner corner;

  /// Users expect a mirrored view of themselves...
  final bool mirrorPreview;

  /// ...and an unmirrored recording.
  final bool mirrorOutput;

  /// The tile's width / height for a camera of [sourceAspectRatio].
  ///
  /// Null — no camera frame yet — falls back to [aspectRatio], so placement
  /// never waits on the first frame.
  double effectiveAspectRatio([double? sourceAspectRatio]) =>
      followsSourceAspectRatio &&
          sourceAspectRatio != null &&
          sourceAspectRatio > 0
      ? sourceAspectRatio
      : aspectRatio;

  /// Resolves the picture-in-picture rectangle for a canvas of the given size.
  ///
  /// Pure geometry, so the compositor can be unit-tested at any canvas size
  /// without a capture session.
  Rect resolveRect(
    double canvasWidth,
    double canvasHeight, {
    double? sourceAspectRatio,
  }) {
    final double width = canvasWidth * widthRatio;
    final double height = width / effectiveAspectRatio(sourceAspectRatio);
    final double margin = canvasWidth * marginRatio;
    final double left = switch (corner) {
      CameraOverlayCorner.topLeft || CameraOverlayCorner.bottomLeft => margin,
      CameraOverlayCorner.topRight ||
      CameraOverlayCorner.bottomRight => canvasWidth - margin - width,
    };
    final double top = switch (corner) {
      CameraOverlayCorner.topLeft || CameraOverlayCorner.topRight => margin,
      CameraOverlayCorner.bottomLeft ||
      CameraOverlayCorner.bottomRight => canvasHeight - margin - height,
    };
    return Rect.fromLTWH(left, top, width, height);
  }

  CameraOverlayConfiguration copyWith({
    double? widthRatio,
    double? aspectRatio,
    bool? followsSourceAspectRatio,
    double? cornerRadius,
    double? marginRatio,
    CameraOverlayCorner? corner,
    bool? mirrorPreview,
    bool? mirrorOutput,
  }) => CameraOverlayConfiguration(
    widthRatio: widthRatio ?? this.widthRatio,
    aspectRatio: aspectRatio ?? this.aspectRatio,
    followsSourceAspectRatio:
        followsSourceAspectRatio ?? this.followsSourceAspectRatio,
    cornerRadius: cornerRadius ?? this.cornerRadius,
    marginRatio: marginRatio ?? this.marginRatio,
    corner: corner ?? this.corner,
    mirrorPreview: mirrorPreview ?? this.mirrorPreview,
    mirrorOutput: mirrorOutput ?? this.mirrorOutput,
  );

  Map<String, Object?> toMap() => <String, Object?>{
    'widthRatio': widthRatio,
    'aspectRatio': aspectRatio,
    'followsSourceAspectRatio': followsSourceAspectRatio,
    'cornerRadius': cornerRadius,
    'marginRatio': marginRatio,
    'corner': corner.name,
    'mirrorPreview': mirrorPreview,
    'mirrorOutput': mirrorOutput,
  };

  @override
  bool operator ==(Object other) =>
      other is CameraOverlayConfiguration &&
      other.widthRatio == widthRatio &&
      other.aspectRatio == aspectRatio &&
      other.followsSourceAspectRatio == followsSourceAspectRatio &&
      other.cornerRadius == cornerRadius &&
      other.marginRatio == marginRatio &&
      other.corner == corner &&
      other.mirrorPreview == mirrorPreview &&
      other.mirrorOutput == mirrorOutput;

  @override
  int get hashCode => Object.hash(
    widthRatio,
    aspectRatio,
    followsSourceAspectRatio,
    cornerRadius,
    marginRatio,
    corner,
    mirrorPreview,
    mirrorOutput,
  );
}
