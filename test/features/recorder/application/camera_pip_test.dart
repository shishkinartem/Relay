import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/settings/app_settings.dart';

import '../../../support/harness.dart';

/// The camera tile: three presets, a free position, and bounds that hold
/// however the value arrived (§33.5).
void main() {
  group('the presets', () {
    test('camera keeps the whole frame at the accepted default', () {
      final CameraOverlayConfiguration configuration =
          CameraOverlayConfiguration.forPreset(CameraPipPreset.camera);

      expect(configuration.widthRatio, 0.16);
      expect(configuration.followsSourceAspectRatio, isTrue);
      expect(configuration.fit, CameraPipFit.contain);
      expect(configuration.cornerRadiusRatio, 0);
    });

    test('square and circle are small, 1:1 and cropped', () {
      for (final CameraPipPreset preset in <CameraPipPreset>[
        CameraPipPreset.square,
        CameraPipPreset.circle,
      ]) {
        final CameraOverlayConfiguration configuration =
            CameraOverlayConfiguration.forPreset(preset);
        expect(configuration.widthRatio, 0.10);
        expect(configuration.aspectRatio, 1);
        expect(configuration.followsSourceAspectRatio, isFalse);
        expect(
          configuration.fit,
          CameraPipFit.cover,
          reason: 'a 16:9 sensor cannot fill a square any other way',
        );
      }
    });

    test('only the circle is masked, and it is masked all the way', () {
      expect(
        CameraOverlayConfiguration.forPreset(CameraPipPreset.circle)
            .cornerRadiusRatio,
        0.5,
      );
      expect(
        CameraOverlayConfiguration.forPreset(CameraPipPreset.square)
            .cornerRadiusRatio,
        0,
      );
    });

    test('a small camera is never upscaled past its own pixels', () {
      const CameraOverlayConfiguration configuration =
          CameraOverlayConfiguration();

      // A 1080p sensor on a 1920 canvas asks for 0.66 and gets the cap, which
      // is why an ordinary session looks exactly as it did before presets.
      expect(configuration.effectiveWidthRatio(1920, sourceWidth: 1920), 0.16);
      // A 160-wide one asks for less than the cap and gets what it asks for…
      expect(
        configuration.effectiveWidthRatio(1920, sourceWidth: 192),
        closeTo(0.10, 1e-9),
      );
      // …down to the floor, below which nothing is readable.
      expect(configuration.effectiveWidthRatio(1920, sourceWidth: 32), 0.08);
    });

    test('a fixed preset ignores the camera it is showing', () {
      final CameraOverlayConfiguration square =
          CameraOverlayConfiguration.forPreset(CameraPipPreset.square);

      expect(square.effectiveWidthRatio(1920, sourceWidth: 64), 0.10);
    });
  });

  group('where the tile lands', () {
    const CameraOverlayConfiguration cornered = CameraOverlayConfiguration();

    test('no position means the corner, at any canvas size', () {
      for (final Size canvas in <Size>[
        const Size(1280, 720),
        const Size(1920, 1080),
      ]) {
        final Rect rect = cornered.resolveRect(canvas.width, canvas.height);
        expect(rect.right, closeTo(canvas.width * 0.99, 0.001));
        expect(
          rect.bottom,
          closeTo(canvas.height - canvas.width * 0.01, 0.001),
        );
      }
    });

    test('a free position is resolved as a fraction of the canvas', () {
      final CameraOverlayConfiguration free = cornered.copyWith(
        position: const Offset(0.5, 0.25),
      );

      final Rect rect = free.resolveRect(1920, 1080);

      expect(rect.left, closeTo(960, 0.001));
      expect(rect.top, closeTo(270, 0.001));
    });

    test('the tile can never leave the canvas, whatever it was told', () {
      // The bounds live in the geometry, not in whatever dragged the tile, so
      // they hold for a stored value, a restored session and a gesture alike.
      final CameraOverlayConfiguration escaped = cornered.copyWith(
        position: const Offset(4, -2),
      );

      final Rect rect = escaped.resolveRect(1920, 1080);

      expect(rect.left, lessThanOrEqualTo(1920 - 19.2 - rect.width + 0.001));
      expect(rect.top, greaterThanOrEqualTo(19.2 - 0.001));
      expect(rect.right, lessThanOrEqualTo(1920 - 19.2 + 0.001));
      expect(rect.bottom, lessThanOrEqualTo(1080 - 19.2 + 0.001));
    });

    test('a nearly-cornered tile snaps onto the corner exactly', () {
      // 2% of 1920 is 38.4 points of tolerance, and the margin is 19.2.
      final CameraOverlayConfiguration near = cornered.copyWith(
        position: Offset(30 / 1920, 30 / 1080),
      );

      final Rect rect = near.resolveRect(1920, 1080);

      expect(rect.left, closeTo(19.2, 0.001));
      expect(rect.top, closeTo(19.2, 0.001));
    });

    test('a tile far from a corner is left where it was put', () {
      final CameraOverlayConfiguration mid = cornered.copyWith(
        position: const Offset(0.4, 0.4),
      );

      final Rect rect = mid.resolveRect(1920, 1080);

      expect(rect.left, closeTo(768, 0.001));
      expect(rect.top, closeTo(432, 0.001));
    });

    test('a position round-trips through the fraction it is stored as', () {
      final Offset ratio = CameraOverlayConfiguration.positionRatio(
        768,
        432,
        1920,
        1080,
      );
      final Rect rect = cornered
          .copyWith(position: ratio)
          .resolveRect(1920, 1080);

      expect(rect.left, closeTo(768, 0.001));
      expect(rect.top, closeTo(432, 0.001));
    });
  });

  group('the wire', () {
    test('a configuration round-trips whole', () {
      final CameraOverlayConfiguration original =
          CameraOverlayConfiguration.forPreset(
            CameraPipPreset.circle,
            position: const Offset(0.3, 0.4),
          );

      expect(CameraOverlayConfiguration.fromMap(original.toMap()), original);
    });

    test('half a position is no position', () {
      // A tile placed on one axis and cornered on the other is a shape nobody
      // asked for.
      final CameraOverlayConfiguration decoded =
          CameraOverlayConfiguration.fromMap(<String, Object?>{
            'positionX': 0.5,
          });

      expect(decoded.position, isNull);
    });

    test('a width outside the bounds is clamped rather than asserted', () {
      // The wire is not a place to crash: a host that sends nonsense should
      // produce a legible tile, not a dead application.
      expect(
        CameraOverlayConfiguration.fromMap(<String, Object?>{'widthRatio': 4.0})
            .widthRatio,
        0.50,
      );
      expect(
        CameraOverlayConfiguration.fromMap(<String, Object?>{
          'cornerRadiusRatio': 9.0,
        }).cornerRadiusRatio,
        0.5,
      );
    });
  });

  group('the session', () {
    test('a preset chosen before recording travels with the preview', () async {
      final TestHarness harness = await TestHarness.create(
        settings: const AppSettings(cameraPipPreset: CameraPipPreset.circle),
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.settings.setCameraEnabled(true);

      await harness.viewModel.requestStart();

      expect(
        harness.recorder.lastConfiguration!.cameraOverlay.preset,
        CameraPipPreset.circle,
      );
    });

    test('a preset chosen mid-recording re-points the live tile', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.settings.setCameraEnabled(true);
      await harness.viewModel.requestStart();

      await harness.viewModel.setCameraPreset(CameraPipPreset.square);

      expect(
        harness.recorder.cameraOverlays.single.preset,
        CameraPipPreset.square,
      );
      // In effect immediately — the sheet has to draw the shape the tile is
      // now — and not yet on disk. §33.5 persists the tile "when the session
      // ends normally".
      expect(harness.viewModel.cameraPreset, CameraPipPreset.square);
      expect(harness.settings.settings.cameraPipPreset, CameraPipPreset.camera);
    });

    test('the preset is persisted when the session ends', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.settings.setCameraEnabled(true);
      await harness.viewModel.requestStart();
      await harness.viewModel.setCameraPreset(CameraPipPreset.circle);

      await harness.viewModel.stop();

      expect(harness.settings.settings.cameraPipPreset, CameraPipPreset.circle);
      expect(harness.viewModel.cameraPreset, CameraPipPreset.circle);
    });

    /// §33.7: "crash mid-session → neither the position nor the preset is
    /// persisted; the next session starts from the previous default". A crash
    /// is the absence of a teardown, which is what a fresh view model over the
    /// same stored settings stands for.
    test('a preset tried mid-session does not survive a crash', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.settings.setCameraEnabled(true);
      await harness.viewModel.requestStart();

      await harness.viewModel.setCameraPreset(CameraPipPreset.square);

      // Nothing tore down, so nothing was written: the process going away here
      // leaves the stored preset exactly as the last completed session left it.
      expect(harness.settings.settings.cameraPipPreset, CameraPipPreset.camera);
    });

    test('a preset chosen before recording is persisted at once', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.setCameraPreset(CameraPipPreset.square);

      // No session, so there is no experiment to survive: the user is setting
      // the default, and it has to be there next launch whether or not they
      // went on to record.
      expect(harness.settings.settings.cameraPipPreset, CameraPipPreset.square);
    });

    test('choosing the preset that is already set changes nothing', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      await harness.viewModel.setCameraPreset(CameraPipPreset.camera);

      expect(harness.recorder.cameraOverlays, isEmpty);
    });

    test('outside a session nothing is pushed to a compositor', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.setCameraPreset(CameraPipPreset.circle);

      expect(harness.recorder.cameraOverlays, isEmpty);
      expect(harness.settings.settings.cameraPipPreset, CameraPipPreset.circle);
    });

    test(
      'where the tile was dragged is remembered when the session ends',
      () async {
        final TestHarness harness = await TestHarness.create();
        addTearDown(harness.dispose);
        await harness.initialize();
        harness.recorder.reportedCameraPreviewPosition = const Offset(
          0.58,
          0.30,
        );

        await harness.viewModel.requestStart();
        await harness.viewModel.stop();

        expect(
          harness.settings.settings.cameraPipPosition,
          const Offset(0.58, 0.30),
        );
      },
    );

    test('window mode reports no position, and none is stored', () async {
      // There the preview is a captioned object that is deliberately not the
      // tile, so a drag moved something else (design `1e`).
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      harness.recorder.reportedCameraPreviewPosition = null;

      await harness.viewModel.requestStart();
      await harness.viewModel.stop();

      expect(harness.settings.settings.cameraPipPosition, isNull);
    });

    test('the position survives a settings round trip', () {
      const AppSettings settings = AppSettings(
        cameraPipPreset: CameraPipPreset.square,
        cameraPipPosition: Offset(0.58, 0.30),
      );

      final AppSettings restored = AppSettings.fromJson(settings.toJson());

      expect(restored, settings);
      expect(restored.hashCode, settings.hashCode);
    });

    test('a stored position with one axis missing is not a position', () {
      expect(
        AppSettings.fromJson(<String, Object?>{
          AppSettings.keyCameraPipPosition: <String, Object?>{'x': 0.5},
        }).cameraPipPosition,
        isNull,
      );
    });
  });
}
