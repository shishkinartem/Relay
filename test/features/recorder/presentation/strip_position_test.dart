import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/settings/app_settings.dart';
import 'package:relay/design_system/design_system.dart';
import 'package:relay/features/recorder/application/recorder_view_model.dart';

import '../../../support/harness.dart';

/// The strip goes where the user puts it (§33.3).
///
/// Two halves are covered here: the gesture that starts a drag without ever
/// stealing a control's press, and the round trip that means the next session
/// opens the strip where the last one left it.
void main() {
  group('the drag handle', () {
    Future<void> mountStrip(
      WidgetTester tester, {
      required VoidCallback onMove,
      VoidCallback? onStop,
    }) async {
      await loadDesignFonts();
      await tester.pumpWidget(
        RelayTheme(
          child: Align(
            alignment: Alignment.topLeft,
            child: RecordingControlStrip(
              elapsed: const Duration(seconds: 5),
              isPaused: false,
              microphoneEnabled: true,
              cameraEnabled: false,
              systemAudioEnabled: true,
              onMoveRequested: onMove,
              onStop: onStop ?? () {},
            ),
          ),
        ),
      );
    }

    testWidgets('a press that has not travelled is not a drag', (
      WidgetTester tester,
    ) async {
      int moves = 0;
      await mountStrip(tester, onMove: () => moves++);

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.text('00:00:05')),
      );
      await gesture.moveBy(const Offset(3, 0));
      await tester.pump();

      expect(
        moves,
        0,
        reason: 'under the 4 px threshold this is still a click',
      );

      await gesture.moveBy(const Offset(3, 0));
      await tester.pump();
      expect(moves, 1);

      // The host owns the pointer from here; a second request would ask for a
      // drag with no button held.
      await gesture.moveBy(const Offset(40, 20));
      await tester.pump();
      expect(moves, 1);

      await gesture.up();
    });

    testWidgets('a drag on a control moves nothing and presses it', (
      WidgetTester tester,
    ) async {
      // The controls are in front of the handle, so a press that lands on one
      // never reaches it. Otherwise reaching for Stop would move the window.
      int moves = 0;
      int stops = 0;
      await mountStrip(tester, onMove: () => moves++, onStop: () => stops++);

      await tester.tap(find.bySemanticsLabel('Stop'));
      await tester.pump();

      expect(stops, 1);
      expect(moves, 0);
    });

    testWidgets('a strip that cannot be moved still renders and works', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      int stops = 0;
      await tester.pumpWidget(
        RelayTheme(
          child: Align(
            alignment: Alignment.topLeft,
            child: RecordingControlStrip(
              elapsed: Duration.zero,
              isPaused: false,
              microphoneEnabled: true,
              cameraEnabled: false,
              systemAudioEnabled: true,
              onStop: () => stops++,
            ),
          ),
        ),
      );

      await tester.tap(find.bySemanticsLabel('Stop'));
      expect(stops, 1);
    });

    testWidgets('the handle does not change the size the window is sized to', (
      WidgetTester tester,
    ) async {
      // §6: the host window is sized to what the strip measures, and a strip
      // that measured differently once it became movable would resize that
      // always-on-top window the first time it was shown.
      await loadDesignFonts();

      Future<Size> measure({required bool movable}) async {
        await tester.pumpWidget(
          RelayTheme(
            child: Align(
              alignment: Alignment.topLeft,
              child: RecordingControlStrip(
                elapsed: Duration.zero,
                isPaused: false,
                microphoneEnabled: true,
                cameraEnabled: false,
                systemAudioEnabled: true,
                onMoveRequested: movable ? () {} : null,
              ),
            ),
          ),
        );
        return tester.getSize(find.byType(RecordingControlStrip));
      }

      expect(await measure(movable: true), await measure(movable: false));
    });
  });

  group('the arrow keys', () {
    Future<TestHarness> recording() async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();
      harness.overlays.nudges.clear();
      return harness;
    }

    test('each direction moves the strip one step', () async {
      final TestHarness harness = await recording();

      harness.overlays.commandController
        ..add(OverlayCommand.nudgeStripLeft)
        ..add(OverlayCommand.nudgeStripRight)
        ..add(OverlayCommand.nudgeStripUp)
        ..add(OverlayCommand.nudgeStripDown);
      await Future<void>.delayed(Duration.zero);

      const double step = RecorderViewModel.stripNudgeStep;
      expect(harness.overlays.nudges, <Offset>[
        const Offset(-step, 0),
        const Offset(step, 0),
        const Offset(0, -step),
        const Offset(0, step),
      ]);
    });

    test('Shift takes a coarser step in the same direction', () async {
      final TestHarness harness = await recording();

      harness.overlays.commandController
        ..add(OverlayCommand.nudgeStripLeftFar)
        ..add(OverlayCommand.nudgeStripDownFar);
      await Future<void>.delayed(Duration.zero);

      const double far = RecorderViewModel.stripCoarseNudgeStep;
      expect(far, greaterThan(RecorderViewModel.stripNudgeStep));
      expect(harness.overlays.nudges, <Offset>[
        const Offset(-far, 0),
        const Offset(0, far),
      ]);
    });

    test('a nudge outside a session reaches no window', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();

      harness.overlays.commandController.add(OverlayCommand.nudgeStripLeft);
      await Future<void>.delayed(Duration.zero);

      expect(
        harness.overlays.nudges,
        isEmpty,
        reason: 'there is no strip to move between sessions',
      );
    });
  });

  group('remembering where it was left', () {
    const OverlayStripPosition somewhere = OverlayStripPosition(
      displayId: 'display:1',
      x: 0.31,
      y: 0.44,
    );

    test('a session with nothing remembered docks at the default', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.requestStart();

      final OverlayPlacement placement =
          harness.overlays.stripPlacements.single;
      expect(placement.position, isNull);
      expect(placement.anchor, OverlayAnchor.topCenter);
    });

    test('a remembered position is what the strip is shown at', () async {
      final TestHarness harness = await TestHarness.create(
        settings: const AppSettings(stripPosition: somewhere),
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.requestStart();

      final OverlayPlacement placement =
          harness.overlays.stripPlacements.single;
      expect(placement.position, somewhere);
      expect(
        placement.anchor,
        OverlayAnchor.topCenter,
        reason:
            'the anchor rides along as the fallback for a display that '
            'is no longer attached',
      );
    });

    test(
      'where it ended up is read before it is hidden, and persisted',
      () async {
        final TestHarness harness = await TestHarness.create();
        addTearDown(harness.dispose);
        await harness.initialize();
        harness.overlays.reportedStripPosition = somewhere;

        await harness.viewModel.requestStart();
        await harness.viewModel.stop();

        expect(harness.settings.settings.stripPosition, somewhere);
        final int read = harness.overlays.calls.indexOf('controlStripPosition');
        final int hidden = harness.overlays.calls.indexOf('hideControlStrip');
        expect(read, isNot(-1));
        expect(
          read,
          lessThan(hidden),
          reason: 'a hidden window has no position to report',
        );
      },
    );

    test(
      'a position the host cannot read keeps the one already stored',
      () async {
        final TestHarness harness = await TestHarness.create(
          settings: const AppSettings(stripPosition: somewhere),
        );
        addTearDown(harness.dispose);
        await harness.initialize();
        harness.overlays.reportedStripPosition = null;

        await harness.viewModel.requestStart();
        await harness.viewModel.stop();

        expect(
          harness.settings.settings.stripPosition,
          somewhere,
          reason: 'failing to ask is not the user having dragged it back',
        );
      },
    );

    test('the position survives a session that failed', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      harness.overlays.reportedStripPosition = somewhere;

      await harness.viewModel.requestStart();
      harness.recorder.emit(
        const RecorderErrorEvent(
          RecorderErrorCode.encodingFailed,
          'the encoder gave up',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(harness.settings.settings.stripPosition, somewhere);
    });
  });

  group('a stored position that cannot name a spot is not one', () {
    test('a fraction outside the unit square is clamped, not dropped', () {
      // A resolution change can leave a stored fraction a hair outside; that is
      // a rounding artefact, not a lost spot.
      final OverlayStripPosition? position = OverlayStripPosition.tryFrom(
        displayId: 'display:1',
        x: 1.02,
        y: -0.01,
      );
      expect(position?.x, 1.0);
      expect(position?.y, 0.0);
    });

    test('no display, no position', () {
      expect(
        OverlayStripPosition.tryFrom(displayId: null, x: 0.5, y: 0.5),
        isNull,
      );
      expect(
        OverlayStripPosition.tryFrom(displayId: '', x: 0.5, y: 0.5),
        isNull,
      );
    });

    test('a non-finite fraction is not a fraction', () {
      expect(
        OverlayStripPosition.tryFrom(
          displayId: 'display:1',
          x: double.nan,
          y: 0.5,
        ),
        isNull,
      );
      expect(
        OverlayStripPosition.tryFrom(
          displayId: 'display:1',
          x: 0.5,
          y: double.infinity,
        ),
        isNull,
      );
    });

    test('it round-trips through the settings document', () {
      const AppSettings settings = AppSettings(
        stripPosition: OverlayStripPosition(
          displayId: 'display:1',
          x: 0.31,
          y: 0.44,
        ),
      );

      final AppSettings restored = AppSettings.fromJson(settings.toJson());

      expect(restored, settings);
      expect(restored.hashCode, settings.hashCode);
      expect(restored.stripPosition?.displayId, 'display:1');
    });

    test('a document with no stored position means the default dock', () {
      expect(const AppSettings().stripPosition, isNull);
      expect(
        AppSettings.fromJson(<String, Object?>{
          AppSettings.keyStripPosition: 'not a map',
        }).stripPosition,
        isNull,
      );
    });
  });
}
