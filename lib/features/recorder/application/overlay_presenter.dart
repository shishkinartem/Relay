import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

/// The always-on-top surfaces, as the session sees them.
///
/// Placement, sizes and the picture-in-picture geometry are behind this, so a
/// session neither knows nor can depend on them; a test substitutes the whole
/// surface with four lines.
abstract interface class SessionOverlays {
  Stream<OverlayCommand> get commands;

  /// Shows the strip where the user left it, or at its default dock when
  /// [position] is null or its display is gone (§33.3).
  Future<void> showControlStrip({OverlayStripPosition? position});

  Future<void> hideControlStrip();

  /// Moves the strip by one keyboard step, in logical points (§33.3).
  ///
  /// The host clamps and snaps it exactly as it does at the end of a drag, so
  /// the keyboard cannot put the strip somewhere the pointer could not.
  Future<void> nudgeControlStrip(double dx, double dy);

  /// Where the strip is now, for persisting. Null when it cannot be read.
  Future<OverlayStripPosition?> controlStripPosition();

  /// Shows the device list for [kind]. Placement is the host's (§33.4).
  Future<void> showInputMenu(MediaDeviceKind kind, InputMenuOverlayState state);

  /// Re-renders an open menu in place.
  Future<void> updateInputMenu(InputMenuOverlayState state);

  Future<void> hideInputMenu();

  /// Choices made in the menu.
  Stream<InputMenuSelection> get menuSelections;

  /// Where the tile was dragged to, once the host has clamped and snapped it
  /// (§33.5). Silent on a host whose preview is not the tile.
  Stream<CameraPreviewMove> get cameraPreviewMoves;

  /// Pushes a snapshot for the strip to draw.
  Future<void> push(RecordingOverlayState state);

  Future<void> showCameraPreview({
    required CaptureSourceType sourceType,
    required DisplayGeometry display,
    required CameraOverlayConfiguration configuration,
  });

  Future<void> hideCameraPreview();

  Future<void> setMainWindowVisible(bool visible);

  Future<List<String>> excludedWindowIds();
}

/// Places and feeds the two always-on-top windows.
///
/// Placement is presentation, never the exclusion mechanism: the windows are
/// kept out of the recording by the capture filter, and would be even if they
/// sat in the middle of the captured display (§6).
class OverlayPresenter implements SessionOverlays {
  OverlayPresenter({
    required this._overlays,
    this.controlStripSize = const Size(360, 46),
    this.windowModePreviewSize = const Size(200, 140),
    this.windowModePreviewMargin = 36,
  });

  final OverlayWindowController _overlays;
  final Size controlStripSize;

  /// The preview in window mode is a captioned object placed where the user
  /// can see it, because the picture-in-picture lands inside a window they may
  /// not be looking at (design `1e`).
  ///
  /// Fixed, and wide rather than tall: the camera is letterboxed inside it, so
  /// a 16:9 and a 4:3 camera are both shown whole and at their own proportions
  /// rather than one of them being stretched to fill the window.
  final Size windowModePreviewSize;
  final double windowModePreviewMargin;

  RecordingOverlayState? _lastPushed;

  @override
  Stream<OverlayCommand> get commands => _overlays.commands;

  /// The default dock is unchanged — top centre, 6 points down — and it is what
  /// a session with no remembered position still gets (§6).
  ///
  /// A remembered position travels as a *fraction*, and the host is what
  /// resolves and clamps it: only the host knows the display's usable area, and
  /// resolving here would put the strip over a menu bar the moment a display
  /// changed shape between two sessions.
  @override
  Future<void> showControlStrip({OverlayStripPosition? position}) =>
      _overlays.showControlStrip(
        position == null
            ? OverlayPlacement.anchored(
                size: controlStripSize,
                anchor: OverlayAnchor.topCenter,
                margin: 6,
              )
            : OverlayPlacement.fractional(
                size: controlStripSize,
                position: position,
                margin: 6,
              ),
      );

  @override
  Future<OverlayStripPosition?> controlStripPosition() =>
      _overlays.controlStripPosition();

  /// The menu is placed entirely by the host, and only its *size* travels.
  ///
  /// Below the strip when there is room and above it otherwise, aligned to the
  /// chevron that asked for it, clamped to the usable area — none of which this
  /// side can compute: it knows neither where the user dragged the strip nor
  /// where Flutter laid the chevron out inside it. What is sent is an estimate
  /// the menu's own engine corrects the moment it measures itself, exactly as
  /// the strip's window does (§6).
  @override
  Future<void> showInputMenu(
    MediaDeviceKind kind,
    InputMenuOverlayState state,
  ) => _overlays.showInputMenu(
    OverlayPlacement.anchored(
      size: estimatedMenuSize(state),
      anchor: OverlayAnchor.topCenter,
      margin: 7,
    ),
    state,
  );

  /// A first guess at the window's size, corrected by the engine's own
  /// measurement.
  ///
  /// Too small clips a row; too large shows dead space for a frame. Worse than
  /// either, on macOS: a panel driven to a size and then back to one it recently
  /// left can be handed a surface of the wrong size out of the engine's
  /// back-buffer cache, and the render target it builds from that has no colour
  /// attachment at all — a null dereference on the raster thread
  /// (flutter/flutter#185394). The host remembers the measured size per content
  /// shape so a sheet is only ever corrected **once**; this estimate is what
  /// that first show lands on, and every term it forgets is a correction.
  ///
  /// It has one term per section `InputMenuSheet` can lay out. Adding a section
  /// there without adding a term here is how it came to be ninety points short
  /// on the camera sheet, and two hundred in window mode.
  @visibleForTesting
  Size estimatedMenuSize(InputMenuOverlayState state) {
    const double header = 30;
    const double row = 30;
    // Measured against the sheet itself, not guessed — see
    // test/features/recorder/presentation/input_menu_size_test.dart, which
    // fails when a section is added here without a term.
    const double meter = 50;
    const double notice = 37;
    // `Shape and size`: a kicker, a gap and one row of preset tiles.
    const double presets = 99;
    // `Position`: a kicker, a gap and two rows of corner tiles.
    const double corners = 107;
    const double resetRow = 34;
    final int rows = state.loading || state.items.isEmpty
        ? 1
        : state.items.length;
    return Size(
      inputMenuWidth,
      header +
          rows * row +
          (state.level == null ? 0 : meter) +
          (state.presets.isEmpty ? 0 : presets) +
          (state.corners.isEmpty ? 0 : corners) +
          (state.canResetPosition ? resetRow : 0) +
          (state.notice == null ? 0 : notice),
    );
  }

  /// The design's device sheet is 268 points wide (§33.4).
  static const double inputMenuWidth = 268;

  @override
  Future<void> updateInputMenu(InputMenuOverlayState state) =>
      _overlays.updateInputMenu(state);

  @override
  Future<void> hideInputMenu() => _overlays.hideInputMenu();

  @override
  Stream<InputMenuSelection> get menuSelections => _overlays.menuSelections;

  @override
  Stream<CameraPreviewMove> get cameraPreviewMoves =>
      _overlays.cameraPreviewMoves;

  @override
  Future<void> nudgeControlStrip(double dx, double dy) =>
      _overlays.nudgeControlStrip(dx, dy);

  @override
  Future<void> hideControlStrip() {
    _lastPushed = null;
    return _overlays.hideControlStrip();
  }

  /// Pushes a snapshot, skipping pushes that would not change anything.
  @override
  Future<void> push(RecordingOverlayState state) async {
    if (_lastPushed == state) {
      return;
    }
    _lastPushed = state;
    await _overlays.updateControlStrip(state);
  }

  /// In display mode the preview is placed exactly where the compositor draws
  /// the picture-in-picture, so what the user sees is what lands in the file
  /// (design `1p`, `docs/adr/2026-08-22-camera-pip-composition.md`).
  ///
  /// Both modes place the window absolutely, so the mode is sent as its own
  /// flag rather than left for the host to infer from the placement.
  @override
  Future<void> showCameraPreview({
    required CaptureSourceType sourceType,
    required DisplayGeometry display,
    required CameraOverlayConfiguration configuration,
  }) {
    final bool matchesPip = sourceType == CaptureSourceType.display;
    final OverlayPlacement placement = matchesPip
        ? OverlayPlacement.absolute(
            configuration.resolveRect(
              display.logicalWidth,
              display.logicalHeight,
            ),
          )
        : OverlayPlacement.absolute(
            Rect.fromLTWH(
              display.logicalWidth -
                  windowModePreviewMargin -
                  windowModePreviewSize.width,
              display.logicalHeight -
                  windowModePreviewMargin -
                  windowModePreviewSize.height,
              windowModePreviewSize.width,
              windowModePreviewSize.height,
            ),
          );
    // The rectangle above is resolved from the configured *fallback* aspect
    // ratio. Only the host knows the camera's real shape, so it re-resolves the
    // tile against it — which is what keeps the preview exactly on top of the
    // picture-in-picture the compositor draws (design `1p`).
    return _overlays.showCameraPreview(
      placement,
      matchesCompositedPip: matchesPip,
      // Sent in both modes. The tile's shape is what the compositor writes into
      // the file whatever the source is, so the preview needs it to show the
      // preset the user chose; withholding it in window mode is what made all
      // three presets look identical there (§33.5).
      cameraOverlay: configuration,
    );
  }

  @override
  Future<void> hideCameraPreview() => _overlays.hideCameraPreview();

  @override
  Future<void> setMainWindowVisible(bool visible) =>
      _overlays.setMainWindowVisible(visible);

  @override
  Future<List<String>> excludedWindowIds() => _overlays.excludedWindowIds();
}
