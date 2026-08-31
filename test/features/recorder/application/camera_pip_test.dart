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

  group('a preset change keeps the tile where it is', () {
    // A 16:9 camera on a 1920 x 1080 canvas: the `camera` tile is 307.2 x
    // 172.8, both small tiles are 192 x 192, and the margin is 19.2.
    const double w = 1920;
    const double h = 1080;

    CameraOverlayConfiguration presetAt(CameraPipPreset preset, Offset? at) =>
        CameraOverlayConfiguration.forPreset(preset, position: at);

    Rect after(
      CameraPipPreset from,
      CameraPipPreset to,
      Offset at, {
      double? sourceAspectRatio,
    }) => presetAt(to, at)
        .repositionedForSize(
          previous: presetAt(from, at),
          canvasWidth: w,
          canvasHeight: h,
          sourceAspectRatio: sourceAspectRatio,
        )
        .resolveRect(w, h, sourceAspectRatio: sourceAspectRatio);

    /// The lower-right-flush `camera` tile, as a stored fraction.
    const Offset flush = Offset(1593.6 / w, 888 / h);

    test('a corner-flush tile stays corner-flush, through all three', () {
      // Holding the top-left instead puts a 192-wide tile at 1593.6, which is
      // 115 points inside the right margin — past the 38.4-point snap, and near
      // enough to nothing that the user reads it as a reset (§33.7).
      for (final CameraPipPreset to in <CameraPipPreset>[
        CameraPipPreset.square,
        CameraPipPreset.circle,
      ]) {
        final Rect rect = after(CameraPipPreset.camera, to, flush);
        expect(rect.right, closeTo(w - 19.2, 0.001), reason: to.name);
        expect(rect.bottom, closeTo(h - 19.2, 0.001), reason: to.name);
      }
    });

    test('and back again, which is the gesture that reported it', () {
      // Camera -> Square -> Camera is one press each way, and it is also the
      // A -> B -> A the preview window is no longer driven through.
      final CameraOverlayConfiguration square =
          presetAt(CameraPipPreset.square, flush).repositionedForSize(
            previous: presetAt(CameraPipPreset.camera, flush),
            canvasWidth: w,
            canvasHeight: h,
          );
      final Rect back = presetAt(CameraPipPreset.camera, square.position)
          .repositionedForSize(
            previous: square,
            canvasWidth: w,
            canvasHeight: h,
          )
          .resolveRect(w, h);

      expect(back.left, closeTo(1593.6, 0.001));
      expect(back.top, closeTo(888, 0.001));
    });

    test('a tile in the top-left corner stays in it', () {
      final Rect rect = after(
        CameraPipPreset.camera,
        CameraPipPreset.square,
        const Offset(19.2 / w, 19.2 / h),
      );

      expect(rect.left, closeTo(19.2, 0.001));
      expect(rect.top, closeTo(19.2, 0.001));
    });

    test('a centred tile stays centred', () {
      // The anchor is a place in the canvas' free space, so the midpoint of
      // that space maps to the midpoint of it at any other size. A rule that
      // held whichever edge was nearer would have to special-case this.
      final Rect rect = after(
        CameraPipPreset.camera,
        CameraPipPreset.square,
        Offset(((w - 307.2) / 2) / w, ((h - 172.8) / 2) / h),
      );

      expect(rect.center.dx, closeTo(w / 2, 0.001));
      expect(rect.center.dy, closeTo(h / 2, 0.001));
    });

    test('a tile between the two moves proportionally, not by its corner', () {
      // The centre is what the eye follows, so it is what stays put; holding
      // the top-left would move it by half the size change instead.
      final Rect rect = after(
        CameraPipPreset.camera,
        CameraPipPreset.square,
        const Offset(700 / w, 400 / h),
      );

      expect(rect.center.dx, closeTo(700 + 307.2 / 2, 8));
      expect(rect.center.dy, closeTo(400 + 172.8 / 2, 8));
    });

    test('a tile on its corner is left on its corner', () {
      // Null is a live reference to the corner, not an unset value: writing a
      // fraction for it would replace the rule with a snapshot of it.
      final CameraOverlayConfiguration cornered =
          CameraOverlayConfiguration.forPreset(CameraPipPreset.square)
              .repositionedForSize(
                previous: CameraOverlayConfiguration.forPreset(
                  CameraPipPreset.camera,
                ),
                canvasWidth: w,
                canvasHeight: h,
              );

      expect(cornered.position, isNull);
    });

    test('a canvas with no size changes nothing', () {
      final CameraOverlayConfiguration unchanged =
          presetAt(CameraPipPreset.square, flush).repositionedForSize(
            previous: presetAt(CameraPipPreset.camera, flush),
            canvasWidth: 0,
            canvasHeight: 0,
          );

      expect(unchanged.position, flush);
    });

    test('an axis with no room to move is pinned to the margin', () {
      // 1920 x 200 leaves a 192-tall square nothing to move in vertically:
      // 200 - 2 x 19.2 - 192 is negative. The near margin is the same answer
      // the clamp gives it, and the other axis is unaffected.
      final CameraOverlayConfiguration pinned =
          presetAt(CameraPipPreset.square, flush).repositionedForSize(
            previous: presetAt(CameraPipPreset.camera, flush),
            canvasWidth: 1920,
            canvasHeight: 200,
          );

      expect(pinned.position!.dy, closeTo(19.2 / 200, 1e-9));
      expect(pinned.position!.dx, closeTo((1920 - 19.2 - 192) / 1920, 1e-9));
    });

    test('a camera that is not 16:9 still lands on its corner', () {
      // The host is what knows the sensor's real shape, and it re-clamps
      // whatever reaches it. Told the shape, this side gets there on its own.
      final Rect rect = after(
        CameraPipPreset.camera,
        CameraPipPreset.square,
        Offset(1593.6 / w, (h - 19.2 - 307.2 * 3 / 4) / h),
        sourceAspectRatio: 4 / 3,
      );

      expect(rect.right, closeTo(w - 19.2, 0.001));
      expect(rect.bottom, closeTo(h - 19.2, 0.001));
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

    test('a reported drag round-trips, and only it decodes as one', () {
      const CameraPreviewMove move = CameraPreviewMove(Offset(0.58, 0.30));

      expect(CameraPreviewMove.tryFromMap(move.toMap()), move);
      // The channel carries three shapes; each stream keeps what it recognises.
      expect(
        CameraPreviewMove.tryFromMap(<String, Object?>{
          'kind': 'camera',
          'preset': 'circle',
        }),
        isNull,
      );
      expect(
        CameraPreviewMove.tryFromMap(<String, Object?>{
          'event': CameraPreviewMove.eventName,
          'x': 0.5,
        }),
        isNull,
        reason: 'half a position is no position',
      );
      expect(
        CameraPreviewMove.tryFromMap(<String, Object?>{
          'event': CameraPreviewMove.eventName,
          'x': double.nan,
          'y': 0.5,
        }),
        isNull,
      );
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

        await harness.viewModel.requestStart();
        await harness.reportCameraDrag(const Offset(0.58, 0.30));
        await harness.viewModel.stop();

        expect(
          harness.settings.settings.cameraPipPosition,
          const Offset(0.58, 0.30),
        );
      },
    );

    test('a session with no drag stores no position', () async {
      // The preview window sits at the tile's rectangle whether the user
      // dragged it there or the corner rule put it there, so reading its
      // position back at teardown stored the corner's own spot as a *free*
      // position — after which `resolveRect` never took its corner branch
      // again and `Reset position` was offered to someone who had never moved
      // anything. Only a reported drag is a position (§33.5).
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      harness.recorder.reportedCameraPreviewPosition = const Offset(0.83, 0.82);

      await harness.viewModel.requestStart();
      await harness.viewModel.stop();

      expect(harness.settings.settings.cameraPipPosition, isNull);
      expect(
        harness.recorder.calls,
        isNot(contains('cameraPreviewPosition')),
        reason: 'the window is not asked where it is; a drag reports itself',
      );
    });

    test('window mode reports no drag, and none is stored', () async {
      // There the preview is a captioned object that is deliberately not the
      // tile, so a drag moved something else (design `1e`) and the host raises
      // nothing.
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.requestStart();
      await harness.viewModel.stop();

      expect(harness.settings.settings.cameraPipPosition, isNull);
    });

    test('a drag survives a preset change', () async {
      // The owner's report: "when the camera's type is changed its position
      // goes back to the default". The drag was recorded on the host only, so
      // every configuration the application pushed afterwards carried the
      // position the session started with (§33.7).
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.settings.setCameraEnabled(true);
      await harness.viewModel.requestStart();
      await harness.reportCameraDrag(const Offset(0.2, 0.2));

      await harness.viewModel.setCameraPreset(CameraPipPreset.circle);

      expect(harness.recorder.cameraOverlays.last.position, isNotNull);
      expect(
        harness.recorder.cameraOverlays.last.preset,
        CameraPipPreset.circle,
      );
    });

    test('a drag survives the camera being turned off and on', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.settings.setCameraEnabled(true);
      await harness.viewModel.requestStart();
      await harness.reportCameraDrag(const Offset(0.2, 0.2));
      harness.overlays.cameraOverlays.clear();

      await harness.viewModel.toggleCamera();
      await harness.viewModel.toggleCamera();

      expect(
        harness.overlays.cameraOverlays.last!.position,
        const Offset(0.2, 0.2),
      );
    });

    test('a drag makes Reset position offerable', () async {
      // The row is drawn from `canResetPosition`, which used to read only the
      // *stored* position — written at teardown — so it was false for the whole
      // session in which the tile had actually been dragged.
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      expect(
        harness.viewModel.menuStateFor(MediaDeviceKind.camera).canResetPosition,
        isFalse,
      );

      await harness.reportCameraDrag(const Offset(0.2, 0.2));

      expect(
        harness.viewModel.menuStateFor(MediaDeviceKind.camera).canResetPosition,
        isTrue,
      );
    });

    test('a corner chosen after a drag wins, and is what is stored', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();
      await harness.reportCameraDrag(const Offset(0.2, 0.2));

      await harness.viewModel.setCameraCorner(CameraOverlayCorner.topLeft);
      await harness.viewModel.stop();

      expect(harness.viewModel.cameraOverlay.position, isNull);
      expect(harness.settings.settings.cameraPipPosition, isNull);
      expect(
        harness.settings.settings.cameraPipCorner,
        CameraOverlayCorner.topLeft,
      );
    });

    test('a stored position moves with the preset it is stored beside', () async {
      // Chosen on the launch screen, with no session to tear down. The two are
      // stored together and describe one tile, so leaving the position behind
      // would make the pair describe a tile nobody put there — and that is what
      // the next launch would draw.
      final TestHarness harness = await TestHarness.create(
        settings: const AppSettings(
          // Lower-right flush for the `camera` preset on the fake display.
          cameraPipPosition: Offset(
            (1512 - 15.12 - 241.92) / 1512,
            (982 - 15.12 - 136.08) / 982,
          ),
        ),
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.setCameraPreset(CameraPipPreset.square);

      final Rect rect = harness.viewModel.cameraOverlay.resolveRect(1512, 982);
      expect(rect.right, closeTo(1512 - 15.12, 0.001));
      expect(rect.bottom, closeTo(982 - 15.12, 0.001));
      expect(
        harness.settings.settings.cameraPipPosition,
        harness.viewModel.cameraOverlay.position,
      );
    });

    test('a live drag is not written out by a preset change', () async {
      // §33.5: persisted when the session ends normally. A drag this session
      // has not finished with is not a stored position yet.
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();
      await harness.reportCameraDrag(const Offset(0.2, 0.2));

      await harness.viewModel.setCameraPreset(CameraPipPreset.square);

      expect(harness.settings.settings.cameraPipPosition, isNull);
      expect(harness.viewModel.cameraOverlay.position, isNotNull);
    });

    test('Reset position after a drag clears it for good', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();
      await harness.reportCameraDrag(const Offset(0.2, 0.2));

      await harness.viewModel.resetCameraPipPosition();
      await harness.viewModel.stop();

      expect(harness.viewModel.cameraOverlay.position, isNull);
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
