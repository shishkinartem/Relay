import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';

/// The always-on-top surfaces the application owns.
///
/// Both are separate top-level windows, never child layers of a captured
/// window, and both are passed to the capture filter's exclusion list (§6).
enum OverlayWindowKind {
  /// The recording control strip (design `1f` / `1g`).
  controlStrip,

  /// The live camera preview (design `1e` / `1p`).
  cameraPreview,
}

/// A command raised by the control strip and routed back to the application.
enum OverlayCommand {
  toggleMicrophone,
  toggleCamera,
  toggleSystemAudio,
  pauseOrResume,
  stop;

  /// Null for a name this build does not know.
  ///
  /// Deliberately not a fallback: falling back to any member would make a
  /// decoding mismatch press a button nobody pressed, and the member it used to
  /// fall back to was [stop].
  static OverlayCommand? fromName(String? name) {
    for (final OverlayCommand command in values) {
      if (command.name == name) {
        return command;
      }
    }
    return null;
  }
}

/// Where the control strip is docked relative to the current display (§5).
enum OverlayAnchor { topCenter, bottomCenter }

/// Everything the control-strip window renders (design `1f`, `1g`).
///
/// Pushed from the application engine to the overlay engine as one immutable
/// snapshot, so the overlay owns no business state of its own.
@immutable
class RecordingOverlayState {
  const RecordingOverlayState({
    this.isPaused = false,
    this.elapsed = Duration.zero,
    this.microphoneEnabled = true,
    this.cameraEnabled = false,
    this.systemAudioEnabled = true,
    this.microphoneAvailable = true,
    this.cameraAvailable = true,
    this.systemAudioAvailable = true,
    this.isStopping = false,
  });

  final bool isPaused;
  final Duration elapsed;
  final bool microphoneEnabled;
  final bool cameraEnabled;
  final bool systemAudioEnabled;
  final bool microphoneAvailable;
  final bool cameraAvailable;
  final bool systemAudioAvailable;
  final bool isStopping;

  Map<String, Object?> toMap() => <String, Object?>{
    'isPaused': isPaused,
    'elapsedMs': elapsed.inMilliseconds,
    'microphoneEnabled': microphoneEnabled,
    'cameraEnabled': cameraEnabled,
    'systemAudioEnabled': systemAudioEnabled,
    'microphoneAvailable': microphoneAvailable,
    'cameraAvailable': cameraAvailable,
    'systemAudioAvailable': systemAudioAvailable,
    'isStopping': isStopping,
  };

  static RecordingOverlayState fromMap(Map<String, Object?> map) =>
      RecordingOverlayState(
        isPaused: map['isPaused'] as bool? ?? false,
        elapsed: Duration(
          milliseconds: (map['elapsedMs'] as num? ?? 0).toInt(),
        ),
        microphoneEnabled: map['microphoneEnabled'] as bool? ?? true,
        cameraEnabled: map['cameraEnabled'] as bool? ?? false,
        systemAudioEnabled: map['systemAudioEnabled'] as bool? ?? true,
        microphoneAvailable: map['microphoneAvailable'] as bool? ?? true,
        cameraAvailable: map['cameraAvailable'] as bool? ?? true,
        systemAudioAvailable: map['systemAudioAvailable'] as bool? ?? true,
        isStopping: map['isStopping'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is RecordingOverlayState &&
      other.isPaused == isPaused &&
      other.elapsed == elapsed &&
      other.microphoneEnabled == microphoneEnabled &&
      other.cameraEnabled == cameraEnabled &&
      other.systemAudioEnabled == systemAudioEnabled &&
      other.microphoneAvailable == microphoneAvailable &&
      other.cameraAvailable == cameraAvailable &&
      other.systemAudioAvailable == systemAudioAvailable &&
      other.isStopping == isStopping;

  @override
  int get hashCode => Object.hash(
    isPaused,
    elapsed,
    microphoneEnabled,
    cameraEnabled,
    systemAudioEnabled,
    microphoneAvailable,
    cameraAvailable,
    systemAudioAvailable,
    isStopping,
  );
}

/// What the camera-preview window renders.
///
/// [textureId] is registered against the *preview engine's* texture registry,
/// so it is delivered to that engine and never crosses into the main one.
@immutable
class CameraPreviewOverlayState {
  const CameraPreviewOverlayState({
    this.textureId,
    this.mirrored = true,
    this.matchesCompositedPip = false,
    this.aspectRatio = 16 / 9,
  });

  final int? textureId;
  final bool mirrored;

  /// True in display mode, where the preview sits exactly where the compositor
  /// draws the picture-in-picture, so the user sees what lands in the file
  /// (design `1p`).
  final bool matchesCompositedPip;

  /// The camera's own width / height, resolved by the host. The preview draws
  /// the texture at this shape instead of stretching it to fill the window.
  final double aspectRatio;

  Map<String, Object?> toMap() => <String, Object?>{
    'textureId': textureId,
    'mirrored': mirrored,
    'matchesCompositedPip': matchesCompositedPip,
    'aspectRatio': aspectRatio,
  };

  static CameraPreviewOverlayState fromMap(Map<String, Object?> map) =>
      CameraPreviewOverlayState(
        textureId: (map['textureId'] as num?)?.toInt(),
        mirrored: map['mirrored'] as bool? ?? true,
        matchesCompositedPip: map['matchesCompositedPip'] as bool? ?? false,
        aspectRatio: (map['aspectRatio'] as num? ?? 16 / 9).toDouble(),
      );
}

/// Placement request for an overlay window, in logical display points.
@immutable
class OverlayPlacement {
  const OverlayPlacement.anchored({
    required this.size,
    required this.anchor,
    this.margin = 8,
  }) : frame = null;

  const OverlayPlacement.absolute(Rect this.frame)
    : size = null,
      anchor = null,
      margin = 0;

  /// Size for an anchored overlay; null when [frame] is given.
  final Size? size;
  final OverlayAnchor? anchor;
  final double margin;

  /// Exact frame on the current display; null when anchored.
  final Rect? frame;

  Map<String, Object?> toMap() => <String, Object?>{
    if (size != null) 'width': size!.width,
    if (size != null) 'height': size!.height,
    if (anchor != null) 'anchor': anchor!.name,
    'margin': margin,
    if (frame != null)
      'frame': <String, Object?>{
        'x': frame!.left,
        'y': frame!.top,
        'width': frame!.width,
        'height': frame!.height,
      },
  };
}

/// Geometry of the display that holds the main application window (§5).
@immutable
class DisplayGeometry {
  const DisplayGeometry({
    required this.id,
    required this.logicalWidth,
    required this.logicalHeight,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.scaleFactor,
  });

  final String id;
  final double logicalWidth;
  final double logicalHeight;
  final int pixelWidth;
  final int pixelHeight;
  final double scaleFactor;

  /// Whether this describes a real display.
  ///
  /// A null or malformed reply used to decode into a perfectly well-formed
  /// 0 × 0 display, and every caller downstream treated it as one: overlay
  /// placement resolved against a zero rectangle and the control strip was
  /// docked to a display that does not exist. Nothing distinguished "the
  /// platform answered" from "the platform answered with nothing", which is
  /// exactly the distinction a caller needs.
  bool get isUsable => logicalWidth > 0 && logicalHeight > 0;

  /// A display that could not be read.
  ///
  /// Named rather than implied, so a caller that ignores [isUsable] at least
  /// reads a value that says what it is.
  static const DisplayGeometry unknown = DisplayGeometry(
    id: '',
    logicalWidth: 0,
    logicalHeight: 0,
    pixelWidth: 0,
    pixelHeight: 0,
    scaleFactor: 1,
  );

  /// Decodes a native reply, or returns null when there is nothing to decode.
  ///
  /// Null rather than [unknown]: the channel layer turns it into a typed
  /// failure, and a caller that wanted a value gets one it can check.
  static DisplayGeometry? tryFromMap(Map<String, Object?> map) {
    final DisplayGeometry geometry = fromMap(map);
    return geometry.isUsable ? geometry : null;
  }

  static DisplayGeometry fromMap(Map<String, Object?> map) => DisplayGeometry(
    id: map['id'] as String? ?? '',
    logicalWidth: (map['logicalWidth'] as num? ?? 0).toDouble(),
    logicalHeight: (map['logicalHeight'] as num? ?? 0).toDouble(),
    pixelWidth: (map['pixelWidth'] as num? ?? 0).toInt(),
    pixelHeight: (map['pixelHeight'] as num? ?? 0).toInt(),
    scaleFactor: (map['scaleFactor'] as num? ?? 1).toDouble(),
  );
}
