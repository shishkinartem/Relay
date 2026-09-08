import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/features/recorder/domain/session_events.dart';
import 'package:relay/features/recorder/domain/session_machine.dart';
import 'package:relay/features/recorder/domain/session_state.dart';
import 'package:upload_core/upload_core.dart';

import '../../../support/fakes.dart';

const SessionMachine machine = SessionMachine();

const CaptureSource display = CaptureSource(
  id: 'display:1',
  type: CaptureSourceType.display,
  title: 'Built-in Display',
  subtitle: '2560 × 1600',
  pixelWidth: 2560,
  pixelHeight: 1600,
  isCurrentDisplay: true,
);

SessionState apply(SessionState state, SessionEvent event) =>
    machine.apply(state, event).state;

SessionTransition transition(SessionState state, SessionEvent event) =>
    machine.apply(state, event);

/// Drives a session from idle to `ready` the way the application does.
SessionReady readyState({bool everUploaded = false}) {
  SessionState state = const SessionIdle();
  state = apply(state, const PreparationStarted(display));
  state = apply(
    state,
    const RecordingStarted(
      source: display,
      microphoneEnabled: true,
      cameraEnabled: false,
      systemAudioEnabled: true,
    ),
  );
  state = apply(state, const StopRequested());
  state = apply(state, const FinalizationStarted());
  state = apply(
    state,
    RecordingFinalized(FakeRecorder.sampleRecording(), 'recording-1'),
  );
  final SessionReady ready = state as SessionReady;
  return everUploaded
      ? SessionReady(
          recording: ready.recording,
          name: ready.name,
          everUploaded: true,
        )
      : ready;
}

void main() {
  group('§19 happy path', () {
    test('idle → preparing → recording → stopping → finalizing → ready', () {
      SessionState state = const SessionIdle();
      expect(state.phase, SessionPhase.idle);

      state = apply(state, const SourcePickerOpened());
      expect(state.phase, SessionPhase.selectingSource);

      state = apply(
        state,
        const PreflightCompleted(
          source: display,
          report: PermissionReport(<PermissionKind, PermissionStatus>{}),
          blockingDenials: <PermissionKind>{},
        ),
      );
      expect(state.phase, SessionPhase.preflight);

      state = apply(state, const PreparationStarted(display));
      expect(state.phase, SessionPhase.preparing);

      state = apply(
        state,
        const RecordingStarted(
          source: display,
          microphoneEnabled: true,
          cameraEnabled: false,
          systemAudioEnabled: true,
        ),
      );
      expect(state.phase, SessionPhase.recording);

      state = apply(state, const RecordingTicked(Duration(seconds: 5)));
      expect((state as SessionActive).elapsed, const Duration(seconds: 5));

      state = apply(state, const RecordingPaused());
      expect(state.phase, SessionPhase.paused);
      state = apply(state, const RecordingResumed());
      expect(state.phase, SessionPhase.recording);

      state = apply(state, const StopRequested());
      expect(state.phase, SessionPhase.stopping);

      state = apply(state, const FinalizationStarted());
      expect(state.phase, SessionPhase.finalizing);

      state = apply(
        state,
        RecordingFinalized(FakeRecorder.sampleRecording(), 'recording-1'),
      );
      expect(state.phase, SessionPhase.ready);
      expect(state.file, isNotNull);
    });

    test('the default source and inputs match the specification', () {
      final SessionState state = apply(
        const SessionPreparing(display),
        const RecordingStarted(
          source: display,
          microphoneEnabled: true,
          cameraEnabled: false,
          systemAudioEnabled: true,
        ),
      );
      final SessionActive active = state as SessionActive;
      expect(active.source.type, CaptureSourceType.display);
      expect(active.microphoneEnabled, isTrue);
      expect(active.systemAudioEnabled, isTrue);
      expect(active.cameraEnabled, isFalse);
    });
  });

  group('pause and resume (§9)', () {
    SessionActive recording() => apply(
      const SessionPreparing(display),
      const RecordingStarted(
        source: display,
        microphoneEnabled: true,
        cameraEnabled: false,
        systemAudioEnabled: true,
      ),
    ) as SessionActive;

    test('a tick while paused is rejected so the timer holds', () {
      final SessionState paused = apply(recording(), const RecordingPaused());
      final SessionTransition result = transition(
        paused,
        const RecordingTicked(Duration(minutes: 3)),
      );
      expect(result.rejected, isTrue);
      expect((result.state as SessionActive).elapsed, Duration.zero);
    });

    test('pausing twice is rejected rather than double counted', () {
      final SessionState paused = apply(recording(), const RecordingPaused());
      expect(transition(paused, const RecordingPaused()).rejected, isTrue);
    });

    test('resuming while recording is rejected', () {
      expect(
        transition(recording(), const RecordingResumed()).rejected,
        isTrue,
      );
    });
  });

  group('idempotency and race safety', () {
    test('a second Stop is absorbed, not doubled', () {
      SessionState state = apply(
        const SessionPreparing(display),
        const RecordingStarted(
          source: display,
          microphoneEnabled: true,
          cameraEnabled: false,
          systemAudioEnabled: true,
        ),
      );
      state = apply(state, const StopRequested());
      final SessionTransition second = transition(state, const StopRequested());
      expect(second.rejected, isFalse);
      expect(second.state.phase, SessionPhase.stopping);
    });

    test('a late tick after finalization does not revive the session', () {
      final SessionReady ready = readyState();
      final SessionTransition result = transition(
        ready,
        const RecordingTicked(Duration(seconds: 99)),
      );
      expect(result.rejected, isTrue);
      expect(result.state, same(ready));
    });

    test('an out-of-order RecordingStarted in idle is rejected', () {
      expect(
        transition(
          const SessionIdle(),
          const RecordingStarted(
            source: display,
            microphoneEnabled: true,
            cameraEnabled: false,
            systemAudioEnabled: true,
          ),
        ).rejected,
        isTrue,
      );
    });
  });

  group('deletion rules (§18)', () {
    test('an explicit Delete from ready is allowed', () {
      final SessionState state = apply(
        readyState(),
        const LocalDeletionStarted(DeletionReason.userRequested),
      );
      expect(state.phase, SessionPhase.deleting);
      expect((state as SessionDeleting).afterUpload, isFalse);
    });

    test('post-upload cleanup cannot be claimed from ready', () {
      final SessionTransition result = transition(
        readyState(),
        const LocalDeletionStarted(DeletionReason.confirmedUploadSuccess),
      );
      expect(result.rejected, isTrue);
      expect(result.state.phase, SessionPhase.ready);
    });

    test('deletion only follows a confirmed remote success', () {
      SessionState state = apply(
        readyState(),
        const UploadRequested('drive', keepLocalCopy: false),
      );
      state = apply(state, const UploadBegan(totalBytes: 100, resumed: false));
      // Bytes on the wire are not success.
      state = apply(
        state,
        const UploadProgressed(bytesSent: 100, totalBytes: 100),
      );
      expect(state.phase, SessionPhase.uploading);

      state = apply(
        state,
        const UploadEnded.succeeded(
          RemoteUploadResult(
            destinationId: 'drive',
            remoteFileId: 'r1',
            remoteName: 'r.mp4',
          ),
        ),
      );
      expect(state.phase, SessionPhase.deleting);
      expect((state as SessionDeleting).afterUpload, isTrue);
      expect(
        apply(state, const LocalDeletionCompleted()).phase,
        SessionPhase.idle,
      );
    });

    group('keeping the local copy after a confirmed send (§13)', () {
      /// The whole path, `UploadBegan` included, because that leg rebuilds
      /// `SessionUploading` from scratch rather than copying it — a field
      /// forwarded only on the request would be reset the instant the transfer
      /// started, and the file deleted despite the user's choice.
      SessionState sendAndSucceed({required bool keepLocalCopy}) {
        SessionState state = apply(
          readyState(),
          UploadRequested('drive', keepLocalCopy: keepLocalCopy),
        );
        state = apply(
          state,
          const UploadBegan(totalBytes: 100, resumed: false),
        );
        return apply(
          state,
          const UploadEnded.succeeded(
            RemoteUploadResult(
              destinationId: 'drive',
              remoteFileId: 'r1',
              remoteName: 'r.mp4',
            ),
          ),
        );
      }

      test('keeps the file and never enters deleting', () {
        final SessionState state = sendAndSucceed(keepLocalCopy: true);

        expect(state.phase, SessionPhase.ready);
        expect(state, isNot(isA<SessionDeleting>()));
        expect(state.file, isNotNull);
      });

      test('marks it sent, which stands the delete confirmation down', () {
        // The local file is no longer the only copy, so removing it is not the
        // irreversible act the dialog exists to guard
        // (`docs/adr/2026-08-22-delete-confirmation.md`).
        expect(
          (sendAndSucceed(keepLocalCopy: true) as SessionReady).everUploaded,
          isTrue,
        );
      });

      test('deletes as before when the preference is off', () {
        final SessionState state = sendAndSucceed(keepLocalCopy: false);

        expect(state.phase, SessionPhase.deleting);
        expect((state as SessionDeleting).afterUpload, isTrue);
      });

      test('the choice survives the transfer starting', () {
        SessionState state = apply(
          readyState(),
          const UploadRequested('drive', keepLocalCopy: true),
        );
        state = apply(
          state,
          const UploadBegan(totalBytes: 100, resumed: false),
        );

        expect((state as SessionUploading).keepLocalCopy, isTrue);
      });

      test(
        'a cancelled second send does not claim the first never happened',
        () {
          // `everUploaded: false` here would re-arm a confirmation dialog that
          // calls the deletion irreversible when the file is already at the
          // destination.
          SessionState state = apply(
            readyState(everUploaded: true),
            const UploadRequested('drive', keepLocalCopy: false),
          );
          state = apply(
            state,
            const UploadBegan(totalBytes: 100, resumed: false),
          );
          state = apply(state, const UploadEnded.cancelled(bytesConfirmed: 10));

          expect((state as SessionReady).everUploaded, isTrue);
        },
      );

      test('a failed second send does not either', () {
        SessionState state = apply(
          readyState(everUploaded: true),
          const UploadRequested('drive', keepLocalCopy: false),
        );
        state = apply(
          state,
          const UploadBegan(totalBytes: 100, resumed: false),
        );
        state = apply(
          state,
          const UploadEnded.failed(
            UploadError.network('dropped'),
            bytesConfirmed: 40,
          ),
        );

        expect((state as SessionUploadFailed).everUploaded, isTrue);
      });
    });

    test('a failed upload keeps the recording and never deletes', () {
      SessionState state = apply(
        readyState(),
        const UploadRequested('drive', keepLocalCopy: false),
      );
      state = apply(state, const UploadBegan(totalBytes: 100, resumed: false));
      state = apply(
        state,
        const UploadEnded.failed(
          UploadError.network('dropped'),
          bytesConfirmed: 40,
        ),
      );
      expect(state.phase, SessionPhase.uploadFailed);
      expect(state.file, isNotNull);
      final SessionUploadFailed failed = state as SessionUploadFailed;
      expect(failed.bytesConfirmed, 40);
      expect(failed.canResume, isTrue);

      expect(
        transition(
          failed,
          const LocalDeletionStarted(DeletionReason.confirmedUploadSuccess),
        ).rejected,
        isTrue,
      );
    });

    test('a cancelled upload returns to ready with the file intact', () {
      SessionState state = apply(
        readyState(),
        const UploadRequested('drive', keepLocalCopy: false),
      );
      state = apply(state, const UploadBegan(totalBytes: 100, resumed: false));
      state = apply(state, const UploadCancellationRequested());
      expect((state as SessionUploading).cancelling, isTrue);
      state = apply(state, const UploadEnded.cancelled(bytesConfirmed: 40));
      expect(state.phase, SessionPhase.ready);
      expect(state.file, isNotNull);
    });
  });

  group('upload progress', () {
    SessionUploading uploading() {
      SessionState state = apply(
        readyState(),
        const UploadRequested('drive', keepLocalCopy: false),
      );
      state = apply(state, const UploadBegan(totalBytes: 100, resumed: false));
      return state as SessionUploading;
    }

    test('progress never goes backwards', () {
      SessionState state = apply(
        uploading(),
        const UploadProgressed(bytesSent: 60, totalBytes: 100),
      );
      state = apply(
        state,
        const UploadProgressed(bytesSent: 20, totalBytes: 100),
      );
      expect((state as SessionUploading).bytesSent, 60);
    });

    test('progress never exceeds the total', () {
      final SessionState state = apply(
        uploading(),
        const UploadProgressed(bytesSent: 500, totalBytes: 100),
      );
      expect((state as SessionUploading).bytesSent, 100);
      expect(state.fraction, 1.0);
    });

    test('a resumed session is reported as resumed', () {
      final SessionState state = apply(
        uploading(),
        const UploadBegan(totalBytes: 100, resumed: true),
      );
      expect((state as SessionUploading).resumed, isTrue);
    });
  });

  group('capture failures (§19)', () {
    test('a fatal error from any live state ends the session and keeps the artefact', () {
      for (final SessionState live in <SessionState>[
        const SessionSelectingSource(),
        const SessionPreparing(display),
        const SessionFinalizing(),
      ]) {
        final SessionState state = apply(
          live,
          const CaptureFailed(
            code: RecorderErrorCode.diskFull,
            message: 'no space',
            retainedArtifactPath: '/tmp/recording-1.part',
          ),
        );
        expect(state.phase, SessionPhase.failed);
        expect(
          (state as SessionFailed).retainedArtifactPath,
          '/tmp/recording-1.part',
        );
      }
    });

    test(
      'a non-fatal input loss degrades the session instead of ending it',
      () {
        final SessionState recording = apply(
          const SessionPreparing(display),
          const RecordingStarted(
            source: display,
            microphoneEnabled: true,
            cameraEnabled: true,
            systemAudioEnabled: true,
          ),
        );
        final SessionActive degraded = apply(
          recording,
          const InputBecameUnavailable(RecorderErrorCode.microphoneUnavailable),
        ) as SessionActive;
        expect(degraded.phase, SessionPhase.recording);
        expect(degraded.microphoneAvailable, isFalse);
        expect(degraded.microphoneEnabled, isFalse);
        expect(degraded.cameraEnabled, isTrue);
        expect(degraded.systemAudioEnabled, isTrue);
      },
    );

    test('a capture failure cannot be raised when nothing is capturing', () {
      expect(
        transition(
          const SessionIdle(),
          const CaptureFailed(
            code: RecorderErrorCode.captureFailed,
            message: 'x',
          ),
        ).rejected,
        isTrue,
      );
    });
  });

  group('post-recording navigation', () {
    test('"keep the file and decide later" returns to ready, not idle', () {
      SessionState state = apply(
        readyState(),
        const UploadRequested('drive', keepLocalCopy: false),
      );
      state = apply(state, const UploadBegan(totalBytes: 100, resumed: false));
      state = apply(
        state,
        const UploadEnded.failed(UploadError.network('dropped')),
      );
      state = apply(state, const SessionReset());
      expect(state.phase, SessionPhase.ready);
      expect(state.file, isNotNull);
    });

    test('retrying from uploadFailed starts a fresh upload', () {
      SessionState state = apply(
        readyState(),
        const UploadRequested('drive', keepLocalCopy: false),
      );
      state = apply(state, const UploadBegan(totalBytes: 100, resumed: false));
      state = apply(
        state,
        const UploadEnded.failed(UploadError.network('dropped')),
      );
      state = apply(
        state,
        const UploadRequested('telegram', keepLocalCopy: false),
      );
      expect(state.phase, SessionPhase.uploading);
      expect((state as SessionUploading).destinationId, 'telegram');
      expect(state.bytesSent, 0);
    });

    test('renaming in ready keeps the phase and carries the new file', () {
      final SessionReady ready = readyState();
      final RecordingFile renamed = FakeRecorder.sampleRecording(
        path: '/tmp/relay/demo.mp4',
      );
      final SessionState state = apply(
        ready,
        RecordingRenamed('demo', recording: renamed),
      );
      expect(state.phase, SessionPhase.ready);
      expect((state as SessionReady).name, 'demo');
      expect(state.recording.path, '/tmp/relay/demo.mp4');
    });

    test('a reset while recording is refused', () {
      final SessionState recording = apply(
        const SessionPreparing(display),
        const RecordingStarted(
          source: display,
          microphoneEnabled: true,
          cameraEnabled: false,
          systemAudioEnabled: true,
        ),
      );
      expect(transition(recording, const SessionReset()).rejected, isTrue);
    });

    test('a reset leaves a blocking preflight', () {
      // The preflight is a question, not a live session. Granting the
      // permission it was blocking on is the answer, and refusing the reset
      // here leaves the user on a screen they can never dismiss.
      const SessionPreflight blocked = SessionPreflight(
        report: PermissionReport(<PermissionKind, PermissionStatus>{
          PermissionKind.screenRecording: PermissionStatus.denied,
        }),
        blockingDenials: <PermissionKind>{PermissionKind.screenRecording},
        source: display,
      );
      final SessionTransition result = transition(
        blocked,
        const SessionReset(),
      );
      expect(result.rejected, isFalse);
      expect(result.state, isA<SessionIdle>());
    });
  });

  group('preflight gating (§23)', () {
    test('a blocking denial refuses to start', () {
      const SessionPreflight blocked = SessionPreflight(
        report: PermissionReport(<PermissionKind, PermissionStatus>{
          PermissionKind.screenRecording: PermissionStatus.denied,
        }),
        blockingDenials: <PermissionKind>{PermissionKind.screenRecording},
        source: display,
      );
      expect(blocked.canStart, isFalse);
      expect(
        transition(blocked, const PreparationStarted(display)).rejected,
        isTrue,
      );
    });

    test('an unblocked preflight starts', () {
      const SessionPreflight ok = SessionPreflight(
        report: PermissionReport(<PermissionKind, PermissionStatus>{
          PermissionKind.screenRecording: PermissionStatus.granted,
        }),
        blockingDenials: <PermissionKind>{},
        source: display,
      );
      expect(ok.canStart, isTrue);
      expect(
        apply(ok, const PreparationStarted(display)).phase,
        SessionPhase.preparing,
      );
    });
  });

  group('the pre-roll (§6)', () {
    const CaptureSource source = CaptureSource(
      id: 'display:1',
      type: CaptureSourceType.display,
      title: 'Built-in',
      subtitle: '3024 × 1964',
      pixelWidth: 3024,
      pixelHeight: 1964,
    );

    CountdownStarted started(int seconds) => CountdownStarted(
      source: source,
      remaining: Duration(seconds: seconds),
      microphoneEnabled: true,
      cameraEnabled: false,
      systemAudioEnabled: true,
      microphoneAvailable: true,
      cameraAvailable: true,
      systemAudioAvailable: true,
    );

    const RecordingStarted recordingStarted = RecordingStarted(
      source: source,
      microphoneEnabled: true,
      cameraEnabled: false,
      systemAudioEnabled: true,
      microphoneAvailable: true,
      cameraAvailable: true,
      systemAudioAvailable: true,
    );

    SessionCountingDown counting({int seconds = 3}) =>
        apply(SessionPreparing(source), started(seconds))
            as SessionCountingDown;

    test('preparing counts down, and counting down records', () {
      final SessionCountingDown down = counting();
      expect(down.remaining, const Duration(seconds: 3));

      final SessionState live = apply(down, recordingStarted);
      expect(live, isA<SessionActive>());
      expect(
        (live as SessionActive).elapsed,
        Duration.zero,
        reason: 'the pre-roll writes no frames, so the clock starts at zero',
      );
    });

    test('a countdown is not a recording, so the strip controls are not live', () {
      // The reason this is its own state rather than a flag on SessionActive:
      // every strip command and the overlay push test for SessionActive, and a
      // pre-roll wearing that type would make Pause and Stop live over a
      // session that has not started.
      expect(counting(), isNot(isA<SessionActive>()));
      expect(counting().phase, SessionPhase.countingDown);
    });

    test('ticks only ever move down, and never to zero', () {
      final SessionCountingDown down = counting();

      expect(
        (apply(
          down,
          const CountdownTicked(Duration(seconds: 2)),
        ) as SessionCountingDown).remaining,
        const Duration(seconds: 2),
      );
      // Zero is not a countdown state — reaching it *is* RecordingStarted.
      expect(
        transition(down, const CountdownTicked(Duration.zero)).rejected,
        isTrue,
      );
      // A tick that did not move is a duplicate the strip must never render.
      expect(
        transition(down, const CountdownTicked(Duration(seconds: 3))).rejected,
        isTrue,
      );
      expect(
        transition(down, const CountdownTicked(Duration(seconds: 9))).rejected,
        isTrue,
      );
    });

    test('cancelling ends the session without failing it', () {
      // Not a CaptureFailed: nothing failed, and that routes to the failure
      // screen, which would put an error in front of someone who simply
      // changed their mind.
      final SessionState after = apply(counting(), const CountdownCancelled());
      expect(after, isA<SessionIdle>());
      expect(after, isNot(isA<SessionFailed>()));
    });

    test('a capture failure during the pre-roll is legal', () {
      // Without the allowlist entry this is rejected as "no capture in
      // progress", and the session wedges with the main window hidden.
      expect(
        apply(
          counting(),
          const CaptureFailed(
            code: RecorderErrorCode.cameraUnavailable,
            message: 'gone',
          ),
        ),
        isA<SessionFailed>(),
      );
    });

    test('a reset cannot abandon a prepared platform handle', () {
      // The pre-roll holds a prepared session with the camera already open, so
      // it has to leave through the path that aborts and releases it.
      final SessionTransition result = transition(
        counting(),
        const SessionReset(),
      );
      expect(result.rejected, isTrue);
      expect(result.state, isA<SessionCountingDown>());
    });

    test('nothing else is legal while counting down', () {
      final SessionCountingDown down = counting();
      for (final SessionEvent event in <SessionEvent>[
        const RecordingTicked(Duration(seconds: 1)),
        const RecordingPaused(),
        const RecordingResumed(),
        const StopRequested(),
        const FinalizationStarted(),
        const UploadRequested('telegram', keepLocalCopy: false),
        const LocalDeletionStarted(DeletionReason.userRequested),
      ]) {
        expect(
          transition(down, event).rejected,
          isTrue,
          reason: '${event.runtimeType} must not be legal while counting down',
        );
      }
    });

    test('a countdown can only begin from preparing', () {
      for (final SessionState state in <SessionState>[
        const SessionIdle(),
        const SessionSelectingSource(),
        const SessionFinalizing(),
      ]) {
        expect(transition(state, started(3)).rejected, isTrue);
      }
    });
  });
}
