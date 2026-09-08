import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/app/relay_app.dart';
import 'package:relay/core/settings/app_settings.dart';
import 'package:relay/features/post_recording/presentation/ready_screen.dart';
import 'package:relay/features/post_recording/presentation/upload_failed_screen.dart';
import 'package:relay/features/post_recording/presentation/uploading_screen.dart';
import 'package:relay/features/recorder/domain/session_state.dart';
import 'package:relay/features/recorder/presentation/launch_screen.dart';
import 'package:relay/features/recorder/presentation/transient_screens.dart';
import 'package:upload_core/upload_core.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

/// No screen in this application shows the user its own source code.
///
/// `preflight_screen_test.dart` has asserted this for one screen since the
/// launch screen shipped a mono line reading
/// `showCursor = true · §4.3 requires it in the output` — a Dart field
/// assignment and a specification chapter number, rendered as product copy,
/// under a toggle that could set the value it asserted to false.
///
/// That guard only ever pumped the preflight, so it could not have caught the
/// line that motivated it. This one sweeps every screen a session can put up,
/// which is what makes the defect class non-recurring rather than fixed once.
///
/// **Deliberately mechanical.** It cannot judge whether copy is *good*; it
/// catches the four shapes that are never product copy in any voice: a
/// specification reference, an assignment, a Dart enum path, and a camelCase
/// identifier.
void main() {
  /// A finalized recording on disk, so the post-recording screens are real.
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

  /// Every rendered string on screen, with the four shapes asserted against it.
  void expectNoSourceCode(WidgetTester tester, String screen) {
    // A camelCase identifier: two or more inner words, so `1080p` and ordinary
    // sentences never match, and `showCursor` or `fileTooLarge` always do.
    final RegExp camelCase = RegExp(r'\b[a-z]+[A-Z][a-zA-Z]*\b');
    // A Dart enum path: `UploadError.network`, `RecorderErrorCode.diskFull`.
    final RegExp enumPath = RegExp(r'\b[A-Z][A-Za-z]+\.[a-z][A-Za-z]*\b');

    for (final Text text in tester.widgetList<Text>(find.byType(Text))) {
      final String value = text.data ?? '';
      if (value.isEmpty) {
        continue;
      }
      expect(value, isNot(contains('§')), reason: '$screen cites the spec');
      expect(
        value,
        isNot(contains('=')),
        reason: '$screen shows an assignment',
      );
      expect(
        value,
        isNot(matches(camelCase)),
        reason: '$screen shows an identifier',
      );
      expect(
        value,
        isNot(matches(enumPath)),
        reason: '$screen shows an enum path',
      );
    }
  }

  testWidgets('the launch screen, with every section open', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await TestHarness.create(
      settings: const AppSettings(
        expandedInputs: <MediaDeviceKind>{
          MediaDeviceKind.microphone,
          MediaDeviceKind.camera,
          MediaDeviceKind.systemAudio,
        },
      ),
    );
    addTearDown(harness.dispose);
    await harness.initialize();

    await tester.pumpWidget(harness.wrap(const LaunchScreen()));
    await tester.pumpAndSettle();
    expectNoSourceCode(tester, 'the launch screen');

    // Advanced is collapsed by default, which is exactly why the `§4.3` line
    // survived design review: no golden render ever contained it.
    await tester.tap(find.text('ADVANCED'));
    await tester.pumpAndSettle();
    expectNoSourceCode(tester, 'the launch screen with Advanced open');
  });

  testWidgets('the transient screens', (WidgetTester tester) async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();

    for (final (String kicker, String message) copy in <(String, String)>[
      ('Preparing', 'Getting ready to record.'),
      ('Saving', 'Writing the video file.'),
      ('Deleting', 'Removing the local recording.'),
    ]) {
      await tester.pumpWidget(
        harness.wrap(TransientScreen(kicker: copy.$1, message: copy.$2)),
      );
      // Not `pumpAndSettle`: these screens carry an indeterminate progress bar,
      // which never settles by design.
      await tester.pump();
      expectNoSourceCode(tester, 'the ${copy.$1} screen');
    }
  });

  testWidgets('the capture-failure screen, for every error code', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();

    for (final RecorderErrorCode code in RecorderErrorCode.values) {
      await tester.pumpWidget(
        harness.wrap(
          CaptureFailureScreen(
            state: SessionFailed(
              code: code,
              message: 'the platform said something',
              retainedArtifactPath: '/tmp/relay/recording-8f2a11.part',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expectNoSourceCode(tester, 'the failure screen for ${code.name}');
    }
  });

  testWidgets('the ready screen', (WidgetTester tester) async {
    final TestHarness harness = await readyHarness();
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      harness.wrap(ReadyScreen(state: harness.viewModel.state as SessionReady)),
    );
    await tester.pumpAndSettle();
    expectNoSourceCode(tester, 'the ready screen');
  });

  testWidgets('the uploading screen', (WidgetTester tester) async {
    final TestHarness harness = await readyHarness();
    addTearDown(harness.dispose);
    final SessionReady ready = harness.viewModel.state as SessionReady;

    await tester.pumpWidget(
      harness.wrap(
        UploadingScreen(
          state: SessionUploading(
            recording: ready.recording,
            name: ready.name,
            destinationId: 'telegram',
            bytesSent: 512,
            totalBytes: 2048,
            keepLocalCopy: false,
            chunkIndex: 42,
            chunkCount: 68,
            retries: 1,
            resumed: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expectNoSourceCode(tester, 'the uploading screen');
  });

  testWidgets('the upload-failed screen, for every error kind', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await readyHarness();
    addTearDown(harness.dispose);
    final SessionReady ready = harness.viewModel.state as SessionReady;

    for (final UploadErrorKind kind in UploadErrorKind.values) {
      await tester.pumpWidget(
        harness.wrap(
          UploadFailedScreen(
            state: SessionUploadFailed(
              recording: ready.recording,
              name: ready.name,
              destinationId: 'telegram',
              error: UploadError(kind, 'the server said no'),
              bytesConfirmed: 512,
              canResume: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expectNoSourceCode(tester, 'the upload-failed screen for ${kind.name}');
    }
  });

  testWidgets('the recovery screen', (WidgetTester tester) async {
    final FakeRecorder recorder = FakeRecorder();
    final TestHarness harness = await TestHarness.create(recorder: recorder);
    addTearDown(harness.dispose);
    await harness.initialize();

    // An artefact on disk is what puts the recovery screen up at all, and
    // `RelayApp`'s router is what chooses it — so this also proves the router
    // still reaches it.
    File(
      '${harness.directory.path}${Platform.pathSeparator}'
      'recording-8f2a11.part',
    ).writeAsBytesSync(List<int>.filled(4096, 3));
    await harness.viewModel.initialize();

    await tester.pumpWidget(harness.wrap(const RelayHome()));
    await tester.pumpAndSettle();
    expectNoSourceCode(tester, 'the recovery screen');
  });
}
