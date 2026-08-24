import 'dart:async';
import 'dart:ui';

import 'package:recorder_platform_interface/recorder_platform_interface.dart';

/// The always-on-top surfaces, as the session sees them.
///
/// Placement, sizes and the picture-in-picture geometry are behind this, so a
/// session neither knows nor can depend on them; a test substitutes the whole
/// surface with four lines.
abstract interface class SessionOverlays {
  Stream<OverlayCommand> get commands;

  Future<void> showControlStrip();

  Future<void> hideControlStrip();

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

  @override
  Future<void> showControlStrip() => _overlays.showControlStrip(
    OverlayPlacement.anchored(
      size: controlStripSize,
      anchor: OverlayAnchor.topCenter,
      margin: 6,
    ),
  );

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
      cameraOverlay: matchesPip ? configuration : null,
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
