import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/features/post_recording/presentation/upload_failed_screen.dart';
import 'package:relay/features/post_recording/presentation/uploading_screen.dart';
import 'package:relay/features/recorder/domain/session_state.dart';
import 'package:relay/features/recorder/presentation/recovery_screen.dart';
import 'package:upload_core/upload_core.dart';

import '../../../support/fakes.dart';
import '../../../support/harness.dart';

/// The screens the user sees once something has already gone wrong.
///
/// All three had zero executed lines. They are the ones that have to be right:
/// by the time any of them is on screen the user is already worried about a
/// recording, and every one of them makes a promise about what happened to the
/// local file (§13, §18).
void main() {
  final RecordingFile recording = FakeRecorder.sampleRecording();

  group('uploading (design 1j)', () {
    testWidgets('progress is what the destination confirmed', (
      WidgetTester tester,
    ) async {
      // Never 100% before the remote object exists: the fraction comes from
      // bytes the destination acknowledged, not bytes handed to the socket.
      await loadDesignFonts();
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();

      await tester.pumpWidget(
        harness.wrap(
          UploadingScreen(
            state: SessionUploading(
              recording: recording,
              name: 'Team standup',
              destinationId: 'telegram',
              bytesSent: 512,
              totalBytes: 2048,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('25%'), findsOneWidget);
      expect(find.textContaining('Telegram'), findsWidgets);
    });

    testWidgets('the destination is named, not its id', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();

      await tester.pumpWidget(
        harness.wrap(
          UploadingScreen(
            state: SessionUploading(
              recording: recording,
              name: 'Team standup',
              destinationId: 'webdav',
              bytesSent: 2048,
              totalBytes: 2048,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('WebDAV'), findsWidgets);
      expect(find.text('webdav'), findsNothing);
    });
  });

  group('upload failed (design 1k, §13)', () {
    Future<TestHarness> mount(
      WidgetTester tester,
      UploadError error, {
      bool canResume = false,
    }) async {
      await loadDesignFonts();
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();

      await tester.pumpWidget(
        harness.wrap(
          UploadFailedScreen(
            state: SessionUploadFailed(
              recording: recording,
              name: 'Team standup',
              destinationId: 'telegram',
              error: error,
              bytesConfirmed: 0,
              canResume: canResume,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets('a network failure offers a retry first', (
      WidgetTester tester,
    ) async {
      await mount(
        tester,
        const UploadError(UploadErrorKind.network, 'The connection dropped.'),
      );

      expect(find.text('Try again'), findsOneWidget);
      expect(find.text('Change destination'), findsOneWidget);
    });

    testWidgets('a resumable failure offers to resume rather than restart', (
      WidgetTester tester,
    ) async {
      await mount(
        tester,
        const UploadError(UploadErrorKind.network, 'The connection dropped.'),
        canResume: true,
      );

      expect(find.text('Resume upload'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a file the destination can never take does not offer a retry '
        'as the first action', (WidgetTester tester) async {
      // Retrying a 60 MB file against a 50 MB cap fails identically every
      // time. Changing destination is the only way forward (§16).
      await mount(
        tester,
        const UploadError(
          UploadErrorKind.fileTooLarge,
          'The recording is larger than this destination accepts.',
        ),
      );

      expect(find.text('Change destination'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('the screen states that the recording was kept', (
      WidgetTester tester,
    ) async {
      // §13: a failed upload preserves the local recording. The user has to be
      // told, or the only reasonable assumption is that it is gone.
      await mount(
        tester,
        const UploadError(UploadErrorKind.network, 'The connection dropped.'),
      );

      expect(find.text('Keep the file and decide later'), findsOneWidget);
      expect(
        find.textContaining(
          RegExp('kept|retained|not.*delet', caseSensitive: false),
        ),
        findsWidgets,
        reason: 'the copy must say the local file survived',
      );
    });

    testWidgets('a credential is never rendered into the technical line', (
      WidgetTester tester,
    ) async {
      await mount(
        tester,
        const UploadError(
          UploadErrorKind.authentication,
          'The destination refused the credentials.',
          details: 'bearer sk-abcdefghijklmnopqrstuvwxyz0123456789',
        ),
      );

      expect(find.textContaining('sk-abcdefghij'), findsNothing);
    });
  });

  group('recovery (design 1n, §18)', () {
    Future<TestHarness> mount(WidgetTester tester) async {
      await loadDesignFonts();
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();

      await tester.pumpWidget(
        harness.wrap(
          RecoveryScreen(
            artifact: IncompleteRecordingArtifact(
              path: '${harness.directory.path}/recording-abc123.part',
              recordingId: 'abc123',
              sizeBytes: 4096,
              modifiedAt: DateTime.now().subtract(const Duration(minutes: 12)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets('all three choices are offered and none is automatic', (
      WidgetTester tester,
    ) async {
      // The screen exists precisely so that nothing is finalized or deleted
      // without the user saying so.
      await mount(tester);

      expect(find.text('Try to finalize'), findsOneWidget);
      expect(find.text('Keep as is'), findsOneWidget);
      expect(find.text('Discard file'), findsOneWidget);
    });

    testWidgets('the artefact is identified by name and size', (
      WidgetTester tester,
    ) async {
      await mount(tester);

      expect(find.textContaining('recording-abc123.part'), findsOneWidget);
      expect(find.textContaining('not finalized'), findsOneWidget);
    });

    testWidgets('merely showing the screen deletes nothing', (
      WidgetTester tester,
    ) async {
      final TestHarness harness = await mount(tester);

      expect(harness.recorder.calls, isNot(contains('recoverArtifact')));
    });

    testWidgets('Keep as is finalizes nothing', (WidgetTester tester) async {
      final TestHarness harness = await mount(tester);

      await tester.tap(find.text('Keep as is'));
      await tester.pumpAndSettle();

      expect(harness.recorder.calls, isNot(contains('recoverArtifact')));
      expect(harness.viewModel.hasRecoverableArtifacts, isFalse);
    });

    testWidgets('Try to finalize asks the platform to recover it', (
      WidgetTester tester,
    ) async {
      final TestHarness harness = await mount(tester);

      await tester.tap(find.text('Try to finalize'));
      await tester.pumpAndSettle();

      expect(harness.recorder.calls, contains('recoverArtifact'));
    });
  });
}
