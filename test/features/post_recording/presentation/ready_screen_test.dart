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

  testWidgets('New recording returns to the recorder and keeps the file', (
    WidgetTester tester,
  ) async {
    await loadDesignFonts();
    final TestHarness harness = await readyHarness();
    addTearDown(harness.dispose);
    final SessionReady ready = harness.viewModel.state as SessionReady;

    await tester.pumpWidget(harness.wrap(ReadyScreen(state: ready)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('New recording'));
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
}
