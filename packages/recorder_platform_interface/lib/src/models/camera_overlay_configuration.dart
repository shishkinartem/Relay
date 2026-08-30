import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

/// Which corner of the output canvas the camera picture-in-picture occupies.
///
/// Still here now that the tile has a free position: it is the default, and it
/// is the set of places the tile snaps to (§33.5).
enum CameraOverlayCorner {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight;

  /// The accepted default for anything unreadable (§7).
  static CameraOverlayCorner fromName(String? name) =>
      tryFromName(name) ?? CameraOverlayCorner.bottomRight;

  /// Null for a name that is not a corner, where "no corner" is a real answer
  /// rather than a decoding failure — a menu selection that chose a device, for
  /// instance, which must not read as a request to move the tile.
  static CameraOverlayCorner? tryFromName(String? name) {
    for (final CameraOverlayCorner corner in values) {
      if (corner.name == name) {
        return corner;
      }
    }
    return null;
  }

  /// How the sheet names it — the corner as a place, not as an axis pair.
  String get label => switch (this) {
    CameraOverlayCorner.topLeft => 'Top left',
    CameraOverlayCorner.topRight => 'Top right',
    CameraOverlayCorner.bottomLeft => 'Lower left',
    CameraOverlayCorner.bottomRight => 'Lower right',
  };
}

/// How the camera frame fills its tile.
enum CameraPipFit {
  /// The whole frame, letterboxed if the tile is a different shape. Nothing is
  /// lost.
  contain,

  /// The centre of the frame, cropped to the tile's shape. Something is lost,
  /// and the user asked for it by choosing a shape the camera is not.
  cover;

  static CameraPipFit fromName(String? name) => values.firstWhere(
    (CameraPipFit f) => f.name == name,
    orElse: () => CameraPipFit.contain,
  );
}

/// The three shapes and sizes the tile comes in (§33.5).
///
/// A preset rather than a number, because "small square" and "small circle" are
/// what people actually want and neither is reachable by dragging a corner —
/// the free size this replaced asked the user to arrive at an answer the
/// product could simply give them.
enum CameraPipPreset {
  /// The camera's own shape, at its own width mapped onto the canvas and capped
  /// at [CameraOverlayConfiguration.cameraPresetWidthCap]. Nothing is cropped.
  /// This is the default and the behaviour that shipped before presets existed.
  camera,

  /// 1:1 at [CameraOverlayConfiguration.smallPresetWidth]. A 16:9 sensor cannot
  /// fill a square, so the centre is taken.
  square,

  /// The square, masked to a circle. Same size, same crop.
  circle;

  /// The default for anything unreadable, because a configuration always
  /// describes *some* tile and [camera] is the one that crops nothing.
  static CameraPipPreset fromName(String? name) =>
      tryFromName(name) ?? CameraPipPreset.camera;

  /// Null for a name that is not a preset.
  ///
  /// Needed wherever "no preset" is a real answer rather than a decoding
  /// failure — the sheet's own choice, which is absent on every selection that
  /// picks a device instead. Defaulting there would turn a microphone choice
  /// into a request to reshape the camera.
  static CameraPipPreset? tryFromName(String? name) {
    for (final CameraPipPreset preset in values) {
      if (preset.name == name) {
        return preset;
      }
    }
    return null;
  }

  /// Whether this preset keeps the whole frame.
  bool get keepsWholeFrame => this == CameraPipPreset.camera;
}

/// Geometry, shape and mirroring of the camera picture-in-picture.
///
/// Every value is configuration, not a compositor constant (§7, §28). The
/// defaults are the accepted ones: the camera's own shape at `0.16 × canvas
/// width`, `0.01 × canvas width` margin, lower right, preview mirrored and
/// output not (`docs/adr/2026-08-23-camera-pip-follows-source-aspect.md`).
///
/// Ratios rather than pixels, so 720p and 1080p and both display and window
/// canvases share one configuration.
///
/// **The frame is never distorted, and is cropped only by an explicit shape
/// preset** — identically in the preview and in the file
/// (`docs/adr/2026-08-30-user-adjustable-camera-pip.md`, §33.5). The default
/// still never crops.
@immutable
class CameraOverlayConfiguration {
  const CameraOverlayConfiguration({
    this.preset = CameraPipPreset.camera,
    this.widthRatio = cameraPresetWidthCap,
    this.aspectRatio = 16 / 9,
    this.followsSourceAspectRatio = true,
    this.cornerRadiusRatio = 0.0,
    this.marginRatio = 0.01,
    this.corner = CameraOverlayCorner.bottomRight,
    this.position,
    this.mirrorPreview = true,
    this.mirrorOutput = false,
  }) : assert(
         widthRatio >= minWidthRatio && widthRatio <= maxWidthRatio,
         'widthRatio must be within the bounds §33.5 states',
       ),
       assert(aspectRatio > 0, 'aspectRatio must be positive'),
       assert(
         marginRatio >= 0 && marginRatio < 1,
         'marginRatio must be in [0, 1)',
       ),
       assert(
         cornerRadiusRatio >= 0 && cornerRadiusRatio <= 0.5,
         'cornerRadiusRatio is a fraction of the tile, and 0.5 is a circle',
       );

  /// Builds the configuration a [preset] describes (§33.5).
  ///
  /// The `camera` preset's width is a *cap*: the host lowers it to the camera's
  /// own width when that is smaller, because upscaling a sensor past its own
  /// pixels buys nothing. Only the host knows what the camera produces, which
  /// is the same division of labour the aspect ratio already has.
  factory CameraOverlayConfiguration.forPreset(
    CameraPipPreset preset, {
    CameraOverlayCorner corner = CameraOverlayCorner.bottomRight,
    Offset? position,
    double marginRatio = 0.01,
    bool mirrorPreview = true,
    bool mirrorOutput = false,
  }) => switch (preset) {
    CameraPipPreset.camera => CameraOverlayConfiguration(
      widthRatio: cameraPresetWidthCap,
      followsSourceAspectRatio: true,
      corner: corner,
      position: position,
      marginRatio: marginRatio,
      mirrorPreview: mirrorPreview,
      mirrorOutput: mirrorOutput,
    ),
    CameraPipPreset.square => CameraOverlayConfiguration(
      preset: CameraPipPreset.square,
      widthRatio: smallPresetWidth,
      aspectRatio: 1,
      followsSourceAspectRatio: false,
      corner: corner,
      position: position,
      marginRatio: marginRatio,
      mirrorPreview: mirrorPreview,
      mirrorOutput: mirrorOutput,
    ),
    CameraPipPreset.circle => CameraOverlayConfiguration(
      preset: CameraPipPreset.circle,
      widthRatio: smallPresetWidth,
      aspectRatio: 1,
      followsSourceAspectRatio: false,
      cornerRadiusRatio: 0.5,
      corner: corner,
      position: position,
      marginRatio: marginRatio,
      mirrorPreview: mirrorPreview,
      mirrorOutput: mirrorOutput,
    ),
  };

  /// The accepted default, and the largest the `camera` preset ever gets.
  static const double cameraPresetWidthCap = 0.16;

  /// `Square · small` and `Circle · small`.
  static const double smallPresetWidth = 0.10;

  /// The bounds §33.5 states. A tile below the floor cannot be read; one above
  /// the ceiling is no longer picture-in-picture.
  static const double minWidthRatio = 0.08;
  static const double maxWidthRatio = 0.50;

  /// How close to a corner the tile snaps, as a fraction of canvas width.
  static const double snapRatio = 0.02;

  final CameraPipPreset preset;

  /// Picture-in-picture width as a fraction of the canvas width.
  final double widthRatio;

  /// Width / height of the tile when the camera's own shape is unknown or
  /// [followsSourceAspectRatio] is off. 1.0 is square.
  final double aspectRatio;

  /// Give the tile the camera's own shape.
  ///
  /// A tile shaped differently from the camera can only be filled by cropping
  /// the frame or by stretching it. The `camera` preset removes the choice by
  /// taking the camera's shape; `square` and `circle` make it explicitly, and
  /// crop.
  final bool followsSourceAspectRatio;

  /// Corner radius as a fraction of the tile's *width*. `0.5` is a circle.
  ///
  /// A ratio, not pixels: the same configuration has to describe the same shape
  /// on a 720p and a 1080p canvas.
  final double cornerRadiusRatio;

  /// Margin from the canvas edges as a fraction of the canvas width. With a
  /// free [position] it is the minimum distance from any edge.
  final double marginRatio;

  /// Where the tile goes when [position] is null, and the set of places a
  /// dragged tile snaps to.
  final CameraOverlayCorner corner;

  /// The tile's top-left as a fraction of the canvas, or null for [corner].
  ///
  /// Null is not "unset": it is a live reference to the corner, so a canvas
  /// that changes shape keeps the tile in the corner rather than at whatever
  /// fraction that corner used to be.
  final Offset? position;

  /// Users expect a mirrored view of themselves...
  final bool mirrorPreview;

  /// ...and an unmirrored recording.
  final bool mirrorOutput;

  /// Whether the frame is cropped to fill the tile, or fitted whole inside it.
  CameraPipFit get fit =>
      preset.keepsWholeFrame ? CameraPipFit.contain : CameraPipFit.cover;

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

  /// The width the tile is actually drawn at, as a fraction of the canvas.
  ///
  /// [sourceWidth] is the camera's own width in pixels. On the `camera` preset
  /// it lowers the width so a small sensor is never upscaled past its own
  /// pixels; it does nothing to the fixed presets, whose size is the point.
  double effectiveWidthRatio(double canvasWidth, {int? sourceWidth}) {
    if (!preset.keepsWholeFrame ||
        sourceWidth == null ||
        sourceWidth <= 0 ||
        canvasWidth <= 0) {
      return widthRatio.clamp(minWidthRatio, maxWidthRatio);
    }
    final double natural = sourceWidth / canvasWidth;
    return natural
        .clamp(minWidthRatio, widthRatio)
        .clamp(minWidthRatio, maxWidthRatio);
  }

  /// The corner radius in canvas pixels for a tile of [tileWidth].
  double cornerRadiusFor(double tileWidth) => cornerRadiusRatio * tileWidth;

  /// Resolves the picture-in-picture rectangle for a canvas of the given size.
  ///
  /// Pure geometry, so the compositor can be unit-tested at any canvas size
  /// without a capture session. The result is always fully inside the canvas
  /// and never closer to an edge than the margin, whatever [position] said —
  /// the bounds live here rather than in whatever dragged the tile, so they
  /// hold however the value arrived (§33.5).
  Rect resolveRect(
    double canvasWidth,
    double canvasHeight, {
    double? sourceAspectRatio,
    int? sourceWidth,
  }) {
    final double width =
        canvasWidth *
        effectiveWidthRatio(canvasWidth, sourceWidth: sourceWidth);
    final double height = width / effectiveAspectRatio(sourceAspectRatio);
    final double margin = canvasWidth * marginRatio;

    final Offset? free = position;
    if (free == null) {
      return Rect.fromLTWH(
        _cornerLeft(canvasWidth, width, margin),
        _cornerTop(canvasHeight, height, margin),
        width,
        height,
      );
    }

    final double left = _clampInside(
      free.dx * canvasWidth,
      width,
      canvasWidth,
      margin,
    );
    final double top = _clampInside(
      free.dy * canvasHeight,
      height,
      canvasHeight,
      margin,
    );
    return _snapped(
      Rect.fromLTWH(left, top, width, height),
      canvasWidth,
      canvasHeight,
      margin,
    );
  }

  /// The fraction a tile at [left], [top] on this canvas would be stored as.
  ///
  /// The inverse of [resolveRect]'s free branch, so a drag that reports pixels
  /// can be turned back into a position that survives a canvas of another size.
  static Offset positionRatio(
    double left,
    double top,
    double canvasWidth,
    double canvasHeight,
  ) => canvasWidth <= 0 || canvasHeight <= 0
      ? Offset.zero
      : Offset(
          (left / canvasWidth).clamp(0.0, 1.0),
          (top / canvasHeight).clamp(0.0, 1.0),
        );

  double _cornerLeft(double canvasWidth, double width, double margin) =>
      switch (corner) {
        CameraOverlayCorner.topLeft || CameraOverlayCorner.bottomLeft => margin,
        CameraOverlayCorner.topRight ||
        CameraOverlayCorner.bottomRight => canvasWidth - margin - width,
      };

  double _cornerTop(double canvasHeight, double height, double margin) =>
      switch (corner) {
        CameraOverlayCorner.topLeft || CameraOverlayCorner.topRight => margin,
        CameraOverlayCorner.bottomLeft ||
        CameraOverlayCorner.bottomRight => canvasHeight - margin - height,
      };

  /// Keeps one axis inside the canvas, margin included.
  ///
  /// A tile larger than the canvas is pinned to the near margin rather than
  /// centred: the leading edge on screen beats a tile that overhangs on both
  /// sides.
  static double _clampInside(
    double value,
    double extent,
    double canvasExtent,
    double margin,
  ) {
    final double upper = canvasExtent - margin - extent;
    return upper <= margin ? margin : value.clamp(margin, upper);
  }

  /// Pulls a nearly-cornered tile onto the corner exactly.
  ///
  /// "Put it back in the corner" is one gesture rather than a pixel hunt, and
  /// a snap can never be the thing that pushes the tile out: the targets are
  /// the margin itself.
  Rect _snapped(
    Rect rect,
    double canvasWidth,
    double canvasHeight,
    double margin,
  ) {
    final double distance = canvasWidth * snapRatio;
    final double right = canvasWidth - margin - rect.width;
    final double bottom = canvasHeight - margin - rect.height;
    final double left = _snap(rect.left, <double>[margin, right], distance);
    final double top = _snap(rect.top, <double>[margin, bottom], distance);
    return Rect.fromLTWH(left, top, rect.width, rect.height);
  }

  static double _snap(double value, List<double> targets, double distance) {
    for (final double target in targets) {
      if ((value - target).abs() <= distance) {
        return target;
      }
    }
    return value;
  }

  CameraOverlayConfiguration copyWith({
    CameraPipPreset? preset,
    double? widthRatio,
    double? aspectRatio,
    bool? followsSourceAspectRatio,
    double? cornerRadiusRatio,
    double? marginRatio,
    CameraOverlayCorner? corner,
    Object? position = _unset,
    bool? mirrorPreview,
    bool? mirrorOutput,
  }) => CameraOverlayConfiguration(
    preset: preset ?? this.preset,
    widthRatio: widthRatio ?? this.widthRatio,
    aspectRatio: aspectRatio ?? this.aspectRatio,
    followsSourceAspectRatio:
        followsSourceAspectRatio ?? this.followsSourceAspectRatio,
    cornerRadiusRatio: cornerRadiusRatio ?? this.cornerRadiusRatio,
    marginRatio: marginRatio ?? this.marginRatio,
    corner: corner ?? this.corner,
    position: identical(position, _unset) ? this.position : position as Offset?,
    mirrorPreview: mirrorPreview ?? this.mirrorPreview,
    mirrorOutput: mirrorOutput ?? this.mirrorOutput,
  );

  Map<String, Object?> toMap() => <String, Object?>{
    'preset': preset.name,
    'widthRatio': widthRatio,
    'aspectRatio': aspectRatio,
    'followsSourceAspectRatio': followsSourceAspectRatio,
    'cornerRadiusRatio': cornerRadiusRatio,
    'marginRatio': marginRatio,
    'corner': corner.name,
    'fit': fit.name,
    // Always present, null included: the host reads one shape, and a key that
    // disappears makes the documented example a lie.
    'positionX': position?.dx,
    'positionY': position?.dy,
    'mirrorPreview': mirrorPreview,
    'mirrorOutput': mirrorOutput,
  };

  static CameraOverlayConfiguration fromMap(Map<String, Object?> map) {
    final num? x = map['positionX'] as num?;
    final num? y = map['positionY'] as num?;
    return CameraOverlayConfiguration(
      preset: CameraPipPreset.fromName(map['preset'] as String?),
      widthRatio: (map['widthRatio'] as num? ?? cameraPresetWidthCap)
          .toDouble()
          .clamp(minWidthRatio, maxWidthRatio),
      aspectRatio: (map['aspectRatio'] as num? ?? 16 / 9).toDouble(),
      followsSourceAspectRatio:
          map['followsSourceAspectRatio'] as bool? ?? true,
      cornerRadiusRatio: (map['cornerRadiusRatio'] as num? ?? 0)
          .toDouble()
          .clamp(0.0, 0.5),
      marginRatio: (map['marginRatio'] as num? ?? 0.01).toDouble(),
      corner: CameraOverlayCorner.values.firstWhere(
        (CameraOverlayCorner c) => c.name == map['corner'],
        orElse: () => CameraOverlayCorner.bottomRight,
      ),
      // Half a position is no position: a tile placed on one axis and cornered
      // on the other is a shape nobody asked for.
      position: x == null || y == null
          ? null
          : Offset(x.toDouble(), y.toDouble()),
      mirrorPreview: map['mirrorPreview'] as bool? ?? true,
      mirrorOutput: map['mirrorOutput'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CameraOverlayConfiguration &&
      other.preset == preset &&
      other.widthRatio == widthRatio &&
      other.aspectRatio == aspectRatio &&
      other.followsSourceAspectRatio == followsSourceAspectRatio &&
      other.cornerRadiusRatio == cornerRadiusRatio &&
      other.marginRatio == marginRatio &&
      other.corner == corner &&
      other.position == position &&
      other.mirrorPreview == mirrorPreview &&
      other.mirrorOutput == mirrorOutput;

  @override
  int get hashCode => Object.hash(
    preset,
    widthRatio,
    aspectRatio,
    followsSourceAspectRatio,
    cornerRadiusRatio,
    marginRatio,
    corner,
    position,
    mirrorPreview,
    mirrorOutput,
  );

  static const Object _unset = Object();
}
