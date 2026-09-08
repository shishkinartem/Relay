import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/features/post_recording/presentation/ready_screen.dart';
import 'package:relay/features/recorder/domain/session_state.dart';
import 'package:relay/features/settings/presentation/settings_screen.dart';

import '../../../support/harness.dart';

/// The three ways out of a finalized recording (design `1i`, §13, §18).
///
/// Send and Delete were the only two; leaving the recording alone and going
/// back to the recorder had no affordance at all.
void main() {
  /// Drives a real session to `ready` with a real file on disk.
  Future<TestHarness> readyHarness() async {
    final TestHarness harness = await TestHarness.create();
    await harness.initialize();
    await harness.viewModel.requestStart();
    final File file = File(
      '${harness.directory.path}${Platform.pathSeparator}'
      'recording-8f2a11.mp4',
    )..writeAsBytesSync(List<int>.filled(2048, 7));
    harness.recorder.stopResult = RecordingFile(
      path: file.path,
      recordingId: '8f2a11',
      sizeBytes: 2048,
      duration: const Duration(minutes: 14, seconds: 32),
      createdAt: DateTime.utc(2026, 8, 22, 14, 22),
      width: 1920,
      height: 1080,
      frameRate: 30,
    );
    await harness.viewModel.stop();
    return harness;
  }

  testWidgets('Keep without sending returns to the recorder, file intact', (
    WidgetTester tester,
  ) async {
    await loadDesignFonts();
    final TestHarness harness = await readyHarness();
    addTearDown(harness.dispose);
    final SessionReady ready = harness.viewModel.state as SessionReady;

    await tester.pumpWidget(harness.wrap(ReadyScreen(state: ready)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Keep without sending'));
    await tester.pumpAndSettle();

    expect(harness.viewModel.state, isA<SessionIdle>());
    expect(
      File(ready.recording.path).existsSync(),
      isTrue,
      reason: 'this is not Delete: §18 deletes on Delete or a confirmed upload',
    );
  });

  testWidgets('Change destination opens Settings', (WidgetTester tester) async {
    await loadDesignFonts();
    final TestHarness harness = await readyHarness();
    addTearDown(harness.dispose);
    final SessionReady ready = harness.viewModel.state as SessionReady;

    await tester.pumpWidget(harness.wrap(ReadyScreen(state: ready)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();

    // One place chooses the destination and connects it, rather than a picker
    // that could only choose.
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Upload destination'.toUpperCase()), findsOneWidget);
  });

  group('keeping the recording is stated, not inferred (§13)', () {
    testWidgets('the folder is named on the screen', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.wrap(
          ReadyScreen(state: harness.viewModel.state as SessionReady),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('ON THIS COMPUTER'), findsOneWidget);
      expect(find.text(harness.directory.path), findsOneWidget);
    });

    testWidgets('Open folder hands the platform that folder', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.wrap(
          ReadyScreen(state: harness.viewModel.state as SessionReady),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open folder'));
      await tester.pumpAndSettle();

      expect(harness.folders.opened, <String>[harness.directory.path]);
    });

    testWidgets('a file manager that will not open is not an error', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);
      harness.folders.result = false;

      await tester.pumpWidget(
        harness.wrap(
          ReadyScreen(state: harness.viewModel.state as SessionReady),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open folder'));
      await tester.pumpAndSettle();

      // The folder is named on screen either way, so the worst case is that
      // the user opens it themselves — not a dialog they have to dismiss.
      expect(tester.takeException(), isNull);
      expect(find.text(harness.directory.path), findsOneWidget);
    });

    testWidgets('the keep-after-sending switch says what Send will do', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);

      await tester.pumpWidget(
        harness.wrap(
          ReadyScreen(state: harness.viewModel.state as SessionReady),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Keep a copy on this computer'), findsOneWidget);
      expect(
        find.textContaining('is removed from the folder above'),
        findsOneWidget,
        reason: 'off is the default, and a send is a move',
      );

      // The `On` inside this control, not the launch screen's — the Ready
      // screen has exactly one On/Off, so scoping by the semantics container
      // is enough and does not depend on ordering.
      await tester.tap(
        find.descendant(
          of: find.bySemanticsLabel(
            'Keep a copy on this computer after sending',
          ),
          matching: find.text('On'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        harness.settings.settings.keepLocalCopyAfterSending,
        isTrue,
        reason: 'remembered for every recording, as the caption says',
      );
      expect(find.textContaining('stays in the folder above'), findsOneWidget);
    });

    testWidgets('a confirmed send with the switch on keeps the file', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);
      await harness.settings.setKeepLocalCopyAfterSending(true);
      final SessionReady before = harness.viewModel.state as SessionReady;

      await tester.pumpWidget(harness.wrap(ReadyScreen(state: before)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      // The whole point of the feature: §18 permits the post-upload deletion,
      // it has never required it, and the user said not to.
      expect(
        File(before.recording.path).existsSync(),
        isTrue,
        reason: 'the user asked for the copy to stay',
      );
      final SessionReady after = harness.viewModel.state as SessionReady;
      expect(after.everUploaded, isTrue);
    });

    testWidgets('a confirmed send with it off still deletes, as before', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);
      final SessionReady before = harness.viewModel.state as SessionReady;

      await tester.pumpWidget(harness.wrap(ReadyScreen(state: before)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();

      // §24's release criterion, on the default install. The preference
      // narrows this path; it does not replace it.
      expect(File(before.recording.path).existsSync(), isFalse);
      expect(harness.viewModel.state, isA<SessionIdle>());
    });
  });
}
