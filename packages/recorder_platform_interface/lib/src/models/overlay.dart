import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';

import 'camera_overlay_configuration.dart';
import 'media_device.dart';

/// The always-on-top surfaces the application owns.
///
/// Both are separate top-level windows, never child layers of a captured
/// window, and both are passed to the capture filter's exclusion list (§6).
enum OverlayWindowKind {
  /// The recording control strip (design `1f` / `1g`).
  controlStrip,

  /// The live camera preview (design `1e` / `1p`).
  cameraPreview,

  /// The device list a control's chevron opens (§33.4).
  ///
  /// Its own window rather than part of the strip: the strip keeps one size in
  /// every session state (§6), and a menu inside it would resize an
  /// always-on-top window during the very click that opened it.
  inputMenu,
}

/// A command raised by the control strip and routed back to the application.
enum OverlayCommand {
  toggleMicrophone,
  toggleCamera,
  toggleSystemAudio,
  pauseOrResume,
  stop,

  /// A chevron was pressed. One command per input rather than one carrying a
  /// kind, so this channel keeps emitting bare names and a host that has not
  /// learned the new ones ignores them instead of misreading a payload.
  openMicrophoneMenu,
  openCameraMenu,
  openSystemAudioMenu,

  /// The strip's own menu asked to put it back where it started (§33.3).
  resetStripPosition,

  /// An arrow key moved the strip one step (§33.3).
  ///
  /// The keyboard path exists because the drag does not serve everyone: it
  /// needs a sustained pointer gesture on a small window that is deliberately
  /// hard to hit by accident. One command per direction, for the same reason
  /// the chevrons have one each — this channel carries bare names.
  nudgeStripLeft,
  nudgeStripRight,
  nudgeStripUp,
  nudgeStripDown,

  /// The same held with Shift: a coarse step, for crossing a display without
  /// holding a key down (§33.3).
  nudgeStripLeftFar,
  nudgeStripRightFar,
  nudgeStripUpFar,
  nudgeStripDownFar;

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

/// A device the input menu offers (§33.4).
@immutable
class InputMenuItem {
  const InputMenuItem({
    required this.label,
    this.id,
    this.meta,
    this.selected = false,
    this.enabled = true,
  });

  /// The device id, or null for the two rows that are not devices: `System
  /// default` and `Off`.
  final String? id;

  final String label;

  /// The word beside the label — `built-in`, `in use`, the default's name.
  final String? meta;

  final bool selected;

  /// False for a device the platform lists but cannot open. Shown and not
  /// selectable, so its absence is legible (§33.7).
  final bool enabled;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'label': label,
    'meta': meta,
    'selected': selected,
    'enabled': enabled,
  };

  static InputMenuItem fromMap(Map<String, Object?> map) => InputMenuItem(
    id: map['id'] as String?,
    label: map['label'] as String? ?? '',
    meta: map['meta'] as String?,
    selected: map['selected'] as bool? ?? false,
    enabled: map['enabled'] as bool? ?? true,
  );
}

/// Everything the input-menu window renders (§33.4).
@immutable
class InputMenuOverlayState {
  const InputMenuOverlayState({
    required this.kind,
    required this.title,
    this.items = const <InputMenuItem>[],
    this.loading = false,
    this.emptyMessage,
    this.notice,
    this.level,
    this.presets = const <CameraPipPreset>[],
    this.selectedPreset,
    this.canResetPosition = false,
    this.corners = const <CameraOverlayCorner>[],
    this.selectedCorner,
  });

  final MediaDeviceKind kind;
  final String title;
  final List<InputMenuItem> items;

  /// The shape presets, under the list — the camera sheet's answer to the
  /// microphone's level meter (§33.4). Empty for every other kind.
  ///
  /// Carried as the presets themselves rather than as rows, because they are
  /// the one part of this window that is not a list: the sheet draws each at
  /// its own proportions, which is what makes the choice legible before it is
  /// made.
  final List<CameraPipPreset> presets;
  final CameraPipPreset? selectedPreset;

  /// Whether the tile has been dragged away from its default corner, so the
  /// sheet can offer to put it back. False draws no row at all rather than a
  /// dead one.
  final bool canResetPosition;

  /// The four corners, offered in window mode only (§33.5).
  ///
  /// With a display source the tile is dragged and the preview *is* the tile,
  /// so a corner list would be a second and worse answer to a question already
  /// answered better. Empty draws none.
  final List<CameraOverlayCorner> corners;
  final CameraOverlayCorner? selectedCorner;

  /// One disabled row while the platform answers — never an empty panel, and
  /// never a list that appears to have loaded (§33.7).
  final bool loading;

  /// Shown instead of the list when there is nothing to offer.
  final String? emptyMessage;

  /// A line under the list: the device that was lost, the permission that is
  /// missing.
  final String? notice;

  /// The microphone's live level, or null for a kind that is not metered.
  final InputLevel? level;

  Map<String, Object?> toMap() => <String, Object?>{
    'kind': kind.name,
    'title': title,
    'loading': loading,
    'emptyMessage': emptyMessage,
    'notice': notice,
    'level': level?.toMap(),
    'items': <Object?>[for (final InputMenuItem item in items) item.toMap()],
    'presets': <Object?>[for (final CameraPipPreset p in presets) p.name],
    'selectedPreset': selectedPreset?.name,
    'canResetPosition': canResetPosition,
    'corners': <Object?>[for (final CameraOverlayCorner c in corners) c.name],
    'selectedCorner': selectedCorner?.name,
  };

  static InputMenuOverlayState fromMap(Map<String, Object?> map) {
    final Object? level = map['level'];
    return InputMenuOverlayState(
      // A menu for a kind this build does not know cannot be drawn; the
      // microphone is the safe stand-in because it is the one every platform
      // has, and the host is what decides whether the window opens at all.
      kind:
          MediaDeviceKind.fromName(map['kind'] as String?) ??
          MediaDeviceKind.microphone,
      title: map['title'] as String? ?? '',
      loading: map['loading'] as bool? ?? false,
      emptyMessage: map['emptyMessage'] as String?,
      notice: map['notice'] as String?,
      level: level is Map<Object?, Object?>
          ? InputLevel.fromMap(level.cast<String, Object?>())
          : null,
      items: <InputMenuItem>[
        for (final Object? entry
            in (map['items'] as List<Object?>? ?? const <Object?>[]))
          InputMenuItem.fromMap(
            (entry! as Map<Object?, Object?>).cast<String, Object?>(),
          ),
      ],
      // A preset name this build does not know is dropped, not defaulted: the
      // three shapes are the same three on both sides, and one that decoded
      // into `camera` would silently show the wrong tile as selected.
      presets: <CameraPipPreset>[
        for (final Object? entry
            in (map['presets'] as List<Object?>? ?? const <Object?>[]))
          if (CameraPipPreset.tryFromName(entry as String?)
              case final CameraPipPreset p)
            p,
      ],
      selectedPreset: CameraPipPreset.tryFromName(
        map['selectedPreset'] as String?,
      ),
      canResetPosition: map['canResetPosition'] as bool? ?? false,
      corners: <CameraOverlayCorner>[
        for (final Object? entry
            in (map['corners'] as List<Object?>? ?? const <Object?>[]))
          if (CameraOverlayCorner.tryFromName(entry as String?)
              case final CameraOverlayCorner c)
            c,
      ],
      selectedCorner: CameraOverlayCorner.tryFromName(
        map['selectedCorner'] as String?,
      ),
    );
  }
}

/// What the input menu reports back: a choice, or the fact that it closed.
///
/// Both, on one type, because the application has to hear both. A dismissal
/// that told nobody left the application believing a menu was open that had
/// already gone — so the chevron needed two presses to reopen it, and the meter
/// the menu had started went on holding a microphone nobody was watching.
@immutable
class InputMenuSelection {
  const InputMenuSelection({
    required this.kind,
    this.deviceId,
    this.off = false,
    this.dismissed = false,
    this.preset,
    this.corner,
    this.resetPosition = false,
  });

  /// A shape preset was pressed in the camera sheet (§33.5).
  const InputMenuSelection.preset(this.kind, CameraPipPreset this.preset)
    : deviceId = null,
      off = false,
      dismissed = false,
      corner = null,
      resetPosition = false;

  /// A corner was chosen in the camera sheet's window-mode placement row.
  const InputMenuSelection.corner(this.kind, CameraOverlayCorner this.corner)
    : deviceId = null,
      off = false,
      dismissed = false,
      preset = null,
      resetPosition = false;

  /// `Reset position` was pressed in the camera sheet.
  const InputMenuSelection.resetTilePosition(this.kind)
    : deviceId = null,
      off = false,
      dismissed = false,
      preset = null,
      corner = null,
      resetPosition = true;

  /// The menu closed without a choice — a click outside, the strip moving, the
  /// display changing. Nothing is applied; the application just stops believing
  /// the window is there.
  const InputMenuSelection.dismissed(this.kind)
    : deviceId = null,
      off = false,
      dismissed = true,
      preset = null,
      corner = null,
      resetPosition = false;

  final MediaDeviceKind kind;

  /// Null with [off] false means `System default`.
  final String? deviceId;

  /// The `Off` row, which is the existing toggle rather than a device.
  final bool off;

  final bool dismissed;

  /// Set only by the camera sheet. Unlike a device choice this leaves the sheet
  /// open: the tile changes shape on screen under it, and trying the other two
  /// should not cost a reopen each time.
  final CameraPipPreset? preset;

  /// Window mode's answer to the drag, and like [preset] it leaves the sheet
  /// open.
  final CameraOverlayCorner? corner;

  final bool resetPosition;

  static InputMenuSelection? tryFromMap(Map<String, Object?> map) {
    final MediaDeviceKind? kind = MediaDeviceKind.fromName(
      map['kind'] as String?,
    );
    if (kind == null) {
      return null;
    }
    return InputMenuSelection(
      kind: kind,
      deviceId: map['deviceId'] as String?,
      off: map['off'] as bool? ?? false,
      dismissed: map['dismissed'] as bool? ?? false,
      preset: CameraPipPreset.tryFromName(map['preset'] as String?),
      corner: CameraOverlayCorner.tryFromName(map['corner'] as String?),
      resetPosition: map['resetPosition'] as bool? ?? false,
    );
  }

  Map<String, Object?> toMap() => <String, Object?>{
    'kind': kind.name,
    'deviceId': deviceId,
    'off': off,
    'dismissed': dismissed,
    'preset': preset?.name,
    'corner': corner?.name,
    'resetPosition': resetPosition,
  };

  @override
  bool operator ==(Object other) =>
      other is InputMenuSelection &&
      other.kind == kind &&
      other.deviceId == deviceId &&
      other.off == off &&
      other.dismissed == dismissed &&
      other.preset == preset &&
      other.corner == corner &&
      other.resetPosition == resetPosition;

  @override
  int get hashCode => Object.hash(
    kind,
    deviceId,
    off,
    dismissed,
    preset,
    corner,
    resetPosition,
  );

  @override
  String toString() => switch (this) {
    _ when dismissed => 'InputMenuSelection($kind, dismissed)',
    _ when resetPosition => 'InputMenuSelection($kind, reset position)',
    _ when preset != null => 'InputMenuSelection($kind, ${preset!.name})',
    _ when corner != null => 'InputMenuSelection($kind, ${corner!.name})',
    _ => 'InputMenuSelection($kind, ${off ? 'off' : deviceId ?? 'default'})',
  };
}

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
    this.microphoneHasMenu = false,
    this.cameraHasMenu = false,
    this.systemAudioHasMenu = false,
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

  /// Whether this input has a device list to disclose (§33.4).
  ///
  /// From `RecorderCapabilities.selectableDeviceKinds`, carried in the snapshot
  /// so the strip never asks which operating system it is on (§28). False draws
  /// no caret at all rather than a dead one.
  final bool microphoneHasMenu;
  final bool cameraHasMenu;
  final bool systemAudioHasMenu;

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
    'microphoneHasMenu': microphoneHasMenu,
    'cameraHasMenu': cameraHasMenu,
    'systemAudioHasMenu': systemAudioHasMenu,
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
        microphoneHasMenu: map['microphoneHasMenu'] as bool? ?? false,
        cameraHasMenu: map['cameraHasMenu'] as bool? ?? false,
        systemAudioHasMenu: map['systemAudioHasMenu'] as bool? ?? false,
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
      other.isStopping == isStopping &&
      other.microphoneHasMenu == microphoneHasMenu &&
      other.cameraHasMenu == cameraHasMenu &&
      other.systemAudioHasMenu == systemAudioHasMenu;

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
    microphoneHasMenu,
    cameraHasMenu,
    systemAudioHasMenu,
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
    this.fit = CameraPipFit.contain,
    this.cornerRadiusRatio = 0,
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

  /// The preset's crop and mask, so the preview draws what the compositor draws
  /// (§33.5). `1p` promises they are the same object.
  final CameraPipFit fit;
  final double cornerRadiusRatio;

  Map<String, Object?> toMap() => <String, Object?>{
    'textureId': textureId,
    'mirrored': mirrored,
    'matchesCompositedPip': matchesCompositedPip,
    'aspectRatio': aspectRatio,
    'fit': fit.name,
    'cornerRadiusRatio': cornerRadiusRatio,
  };

  static CameraPreviewOverlayState fromMap(Map<String, Object?> map) =>
      CameraPreviewOverlayState(
        textureId: (map['textureId'] as num?)?.toInt(),
        mirrored: map['mirrored'] as bool? ?? true,
        matchesCompositedPip: map['matchesCompositedPip'] as bool? ?? false,
        aspectRatio: (map['aspectRatio'] as num? ?? 16 / 9).toDouble(),
        fit: CameraPipFit.fromName(map['fit'] as String?),
        cornerRadiusRatio: (map['cornerRadiusRatio'] as num? ?? 0)
            .toDouble()
            .clamp(0.0, 0.5),
      );
}

/// Where the control strip sits, as the user last left it (§33.3).
///
/// A **fraction of the display's usable area**, not a point. A point survives
/// nothing: a resolution change, an undocked monitor or a different machine put
/// the strip somewhere that no longer exists, and the only recovery is a reset
/// the user has to discover. A fraction reproduces the same relative spot on
/// any of them.
///
/// [displayId] is the display holding the strip's centre when the drag ended —
/// deliberately not §5's *current* display, because overriding that placement is
/// the whole point of being able to drag it.
@immutable
class OverlayStripPosition {
  const OverlayStripPosition({
    required this.displayId,
    required this.x,
    required this.y,
  });

  final String displayId;

  /// Top-left as a fraction of the usable area, each in `[0, 1]`.
  final double x;
  final double y;

  /// Null for anything that cannot name a spot on a display.
  ///
  /// A stored position is only useful if it can be resolved; one that cannot is
  /// dropped so the strip returns to its default anchor rather than to a
  /// rectangle nobody can point at.
  static OverlayStripPosition? tryFrom({
    required String? displayId,
    required num? x,
    required num? y,
  }) {
    if (displayId == null || displayId.isEmpty || x == null || y == null) {
      return null;
    }
    final double dx = x.toDouble();
    final double dy = y.toDouble();
    if (!dx.isFinite || !dy.isFinite) {
      return null;
    }
    return OverlayStripPosition(
      displayId: displayId,
      // Clamped rather than rejected: a fraction slightly outside the unit
      // square is a rounding artefact of a resolution change, not a lost spot.
      x: dx.clamp(0.0, 1.0),
      y: dy.clamp(0.0, 1.0),
    );
  }

  static OverlayStripPosition? tryFromMap(Map<String, Object?> map) => tryFrom(
    displayId: map['displayId'] as String?,
    x: map['x'] as num?,
    y: map['y'] as num?,
  );

  Map<String, Object?> toMap() => <String, Object?>{
    'displayId': displayId,
    'x': x,
    'y': y,
  };

  @override
  bool operator ==(Object other) =>
      other is OverlayStripPosition &&
      other.displayId == displayId &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(displayId, x, y);

  @override
  String toString() =>
      'OverlayStripPosition($displayId, ${x.toStringAsFixed(3)}, '
      '${y.toStringAsFixed(3)})';
}

/// Placement request for an overlay window, in logical display points.
@immutable
class OverlayPlacement {
  const OverlayPlacement.anchored({
    required this.size,
    required this.anchor,
    this.margin = 8,
  }) : frame = null,
       position = null;

  /// The strip where the user put it (§33.3).
  ///
  /// The host resolves the fraction against the display's **usable** area and
  /// clamps the result, which is what keeps the menu bar, the notch and the
  /// taskbar uncovered however the fraction was arrived at. A [position] whose
  /// display is gone falls back to [anchor], so the placement always resolves.
  const OverlayPlacement.fractional({
    required this.size,
    required OverlayStripPosition this.position,
    this.anchor = OverlayAnchor.topCenter,
    this.margin = 8,
  }) : frame = null;

  const OverlayPlacement.absolute(Rect this.frame)
    : size = null,
      anchor = null,
      margin = 0,
      position = null;

  /// Size for an anchored overlay; null when [frame] is given.
  final Size? size;
  final OverlayAnchor? anchor;
  final double margin;

  /// Exact frame on the current display; null when anchored.
  final Rect? frame;

  /// The remembered spot, when there is one. Null means "use [anchor]".
  final OverlayStripPosition? position;

  Map<String, Object?> toMap() => <String, Object?>{
    if (size != null) 'width': size!.width,
    if (size != null) 'height': size!.height,
    if (anchor != null) 'anchor': anchor!.name,
    'margin': margin,
    if (position != null) 'position': position!.toMap(),
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
