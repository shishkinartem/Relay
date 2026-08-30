import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/features/recorder/application/overlay_presenter.dart';

import '../../../support/fakes.dart';

/// The camera preview has two designed presentations and the presenter is what
/// chooses between them (design `1e` versus `1p`).
void main() {
  const DisplayGeometry display = DisplayGeometry(
    id: 'display:1',
    logicalWidth: 1440,
    logicalHeight: 900,
    pixelWidth: 2880,
    pixelHeight: 1800,
    scaleFactor: 2,
  );
  const CameraOverlayConfiguration configuration = CameraOverlayConfiguration();

  late FakeOverlayWindowController overlays;
  late OverlayPresenter presenter;

  setUp(() {
    overlays = FakeOverlayWindowController();
    presenter = OverlayPresenter(overlays: overlays);
  });

  Future<void> show(CaptureSourceType sourceType) =>
      presenter.showCameraPreview(
        sourceType: sourceType,
        display: display,
        configuration: configuration,
      );

  test(
    'a display source asks for the picture-in-picture presentation',
    () async {
      await show(CaptureSourceType.display);

      expect(overlays.cameraPipModes, <bool>[true]);
      // The tile configuration travels only in this mode: the host re-resolves
      // the rectangle against the camera's real shape so the preview lands
      // exactly where the compositor draws it.
      expect(overlays.cameraOverlays.single, configuration);
      expect(
        overlays.cameraPlacements.single.frame,
        configuration.resolveRect(display.logicalWidth, display.logicalHeight),
      );
    },
  );

  test('a window source asks for the captioned window presentation', () async {
    await show(CaptureSourceType.window);

    // Regression: the mode used to be inferred by the host from the presence
    // of a frame, and both branches send one — so window mode was reported as
    // display mode and the captioned preview never rendered.
    expect(overlays.cameraPipModes, <bool>[false]);
    // The tile's configuration is sent here too. The compositor has no
    // source-type gate — a window recording gets the chosen preset in the file
    // exactly as a display recording does — so a preview with nothing to
    // resolve from is a preview that cannot show the shape the user picked
    // (§33.5). Withholding it here made Camera, Square and Circle identical on
    // screen while the MP4 differed.
    expect(overlays.cameraOverlays.single, isNotNull);
    expect(
      overlays.cameraPlacements.single.frame,
      Rect.fromLTWH(
        display.logicalWidth -
            presenter.windowModePreviewMargin -
            presenter.windowModePreviewSize.width,
        display.logicalHeight -
            presenter.windowModePreviewMargin -
            presenter.windowModePreviewSize.height,
        presenter.windowModePreviewSize.width,
        presenter.windowModePreviewSize.height,
      ),
    );
  });

  test('both modes place the window absolutely, so the frame cannot carry the '
      'mode', () async {
    await show(CaptureSourceType.display);
    await show(CaptureSourceType.window);

    expect(
      overlays.cameraPlacements.map((OverlayPlacement p) => p.frame != null),
      <bool>[true, true],
    );
    expect(overlays.cameraPipModes, <bool>[true, false]);
  });
}
