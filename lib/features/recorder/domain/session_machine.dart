import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:upload_core/upload_core.dart';

import 'session_events.dart';
import 'session_state.dart';

/// Outcome of applying an event.
class SessionTransition {
  const SessionTransition(this.state, {this.rejected = false, this.reason});

  final SessionState state;

  /// True when the event was not legal in the current state. The state is
  /// returned unchanged — an out-of-order platform callback or a double click
  /// cannot corrupt the session.
  final bool rejected;

  final String? reason;
}

/// The pure §19 state machine.
///
/// No I/O, no timers, no platform calls: given a state and an event it returns
/// the next state. Everything destructive is gated here, so the deletion rules
/// in §18 are enforced in one place that a unit test can exhaust.
class SessionMachine {
  const SessionMachine();

  SessionTransition apply(SessionState state, SessionEvent event) {
    // Fatal capture errors are legal from any live capture state.
    if (event is CaptureFailed) {
      return switch (state) {
        SessionSelectingSource() ||
        SessionPreflight() ||
        SessionPreparing() ||
        SessionActive() ||
        SessionFinalizing() => SessionTransition(
          SessionFailed(
            code: event.code,
            message: event.message,
            retainedArtifactPath: event.retainedArtifactPath,
          ),
        ),
        _ => _reject(state, event, 'no capture in progress'),
      };
    }

    if (event is SessionReset) {
      return switch (state) {
        SessionIdle() ||
        SessionFailed() ||
        SessionReady() ||
        SessionSelectingSource() ||
        // A preflight is a question, not a live session. Once the permission it
        // was blocking on is granted there is nothing left to answer, and
        // without this the screen it puts up can never be dismissed.
        SessionPreflight() => const SessionTransition(SessionIdle()),
        // "Keep the file and decide later" (design `1k`): the recording is
        // still on disk, so this returns to `ready`, never to `idle`.
        final SessionUploadFailed failed => SessionTransition(
          SessionReady(
            recording: failed.recording,
            name: failed.name,
            everUploaded: failed.everUploaded,
            lastError: failed.error,
          ),
        ),
        _ => _reject(state, event, 'session is still live'),
      };
    }

    return switch (state) {
      SessionIdle() => _fromIdle(state, event),
      SessionSelectingSource() => _fromSelecting(state, event),
      SessionPreflight() => _fromPreflight(state, event),
      SessionPreparing() => _fromPreparing(state, event),
      SessionActive() => _fromActive(state, event),
      SessionFinalizing() => _fromFinalizing(state, event),
      SessionReady() => _fromReady(state, event),
      SessionUploading() => _fromUploading(state, event),
      SessionUploadFailed() => _fromUploadFailed(state, event),
      SessionDeleting() => _fromDeleting(state, event),
      SessionFailed() => _reject(state, event, 'session failed'),
    };
  }

  SessionTransition _fromIdle(
    SessionIdle state,
    SessionEvent event,
  ) => switch (event) {
    SourcePickerOpened() => const SessionTransition(SessionSelectingSource()),
    PreflightCompleted(
      :final CaptureSource source,
      :final PermissionReport report,
      :final Set<PermissionKind> blockingDenials,
      :final Set<PermissionKind> degradedInputs,
    ) =>
      SessionTransition(
        SessionPreflight(
          report: report,
          blockingDenials: blockingDenials,
          degradedInputs: degradedInputs,
          source: source,
        ),
      ),
    PreparationStarted(:final CaptureSource source) => SessionTransition(
      SessionPreparing(source),
    ),
    // Startup recovery hands a finalized file straight to `ready`.
    RecordingFinalized(:final RecordingFile recording, :final String name) =>
      SessionTransition(SessionReady(recording: recording, name: name)),
    _ => _reject(state, event, 'idle'),
  };

  SessionTransition _fromSelecting(
    SessionSelectingSource state,
    SessionEvent event,
  ) => switch (event) {
    SourcesLoaded(
      :final List<CaptureSource> sources,
      :final CaptureSource? preselect,
    ) =>
      SessionTransition(
        state.copyWith(
          sources: sources,
          loading: false,
          selected: preselect ?? state.selected,
        ),
      ),
    SourceEnumerationFailed(:final RecorderErrorCode code) => SessionTransition(
      state.copyWith(loading: false, error: code),
    ),
    SourceChosen(:final CaptureSource source) => SessionTransition(
      state.copyWith(selected: source),
    ),
    SourcePickerDismissed() => const SessionTransition(SessionIdle()),
    PreflightCompleted(
      :final CaptureSource source,
      :final PermissionReport report,
      :final Set<PermissionKind> blockingDenials,
      :final Set<PermissionKind> degradedInputs,
    ) =>
      SessionTransition(
        SessionPreflight(
          report: report,
          blockingDenials: blockingDenials,
          degradedInputs: degradedInputs,
          source: source,
        ),
      ),
    PreparationStarted(:final CaptureSource source) => SessionTransition(
      SessionPreparing(source),
    ),
    _ => _reject(state, event, 'selectingSource'),
  };

  SessionTransition _fromPreflight(
    SessionPreflight state,
    SessionEvent event,
  ) => switch (event) {
    PreflightCompleted(
      :final CaptureSource source,
      :final PermissionReport report,
      :final Set<PermissionKind> blockingDenials,
      :final Set<PermissionKind> degradedInputs,
    ) =>
      SessionTransition(
        SessionPreflight(
          report: report,
          blockingDenials: blockingDenials,
          degradedInputs: degradedInputs,
          source: source,
        ),
      ),
    PreparationStarted(:final CaptureSource source) =>
      state.canStart
          ? SessionTransition(SessionPreparing(source))
          : _reject(state, event, 'blocking permission denial'),
    SourcePickerOpened() => const SessionTransition(SessionSelectingSource()),
    SourcePickerDismissed() => const SessionTransition(SessionIdle()),
    _ => _reject(state, event, 'preflight'),
  };

  SessionTransition _fromPreparing(
    SessionPreparing state,
    SessionEvent event,
  ) => switch (event) {
    RecordingStarted(
      :final CaptureSource source,
      :final bool microphoneEnabled,
      :final bool cameraEnabled,
      :final bool systemAudioEnabled,
      :final bool microphoneAvailable,
      :final bool cameraAvailable,
      :final bool systemAudioAvailable,
    ) =>
      SessionTransition(
        SessionActive(
          source: source,
          elapsed: Duration.zero,
          microphoneEnabled: microphoneEnabled,
          cameraEnabled: cameraEnabled,
          systemAudioEnabled: systemAudioEnabled,
          microphoneAvailable: microphoneAvailable,
          cameraAvailable: cameraAvailable,
          systemAudioAvailable: systemAudioAvailable,
        ),
      ),
    _ => _reject(state, event, 'preparing'),
  };

  SessionTransition _fromActive(SessionActive state, SessionEvent event) =>
      switch (event) {
        RecordingTicked(:final Duration elapsed) =>
          state.isPaused
              // A tick while paused would advance a timer that must hold.
              ? _reject(state, event, 'paused')
              : SessionTransition(state.copyWith(elapsed: elapsed)),
        RecordingPaused() =>
          state.isPaused || state.isStopping
              ? _reject(state, event, 'already paused')
              : SessionTransition(state.copyWith(isPaused: true)),
        RecordingResumed() =>
          state.isPaused
              ? SessionTransition(state.copyWith(isPaused: false))
              : _reject(state, event, 'not paused'),
        InputsChanged(
          :final bool microphoneEnabled,
          :final bool cameraEnabled,
          :final bool systemAudioEnabled,
        ) =>
          SessionTransition(
            state.copyWith(
              microphoneEnabled: microphoneEnabled,
              cameraEnabled: cameraEnabled,
              systemAudioEnabled: systemAudioEnabled,
            ),
          ),
        InputBecameUnavailable(:final RecorderErrorCode code) =>
          SessionTransition(_degrade(state, code)),
        StopRequested() =>
          state.isStopping
              // Idempotent: a second Stop click is absorbed.
              ? SessionTransition(state)
              : SessionTransition(state.copyWith(isStopping: true)),
        FinalizationStarted() => const SessionTransition(SessionFinalizing()),
        _ => _reject(state, event, 'active'),
      };

  SessionTransition _fromFinalizing(
    SessionFinalizing state,
    SessionEvent event,
  ) => switch (event) {
    RecordingFinalized(:final RecordingFile recording, :final String name) =>
      SessionTransition(SessionReady(recording: recording, name: name)),
    _ => _reject(state, event, 'finalizing'),
  };

  SessionTransition _fromReady(SessionReady state, SessionEvent event) =>
      switch (event) {
        RecordingRenamed(:final String name, :final RecordingFile? recording) =>
          SessionTransition(state.copyWith(name: name, recording: recording)),
        UploadRequested(:final String destinationId) => SessionTransition(
          SessionUploading(
            recording: state.recording,
            name: state.name,
            destinationId: destinationId,
            bytesSent: 0,
            totalBytes: state.recording.sizeBytes,
          ),
        ),
        LocalDeletionStarted(:final DeletionReason reason) =>
          reason == DeletionReason.userRequested
              ? SessionTransition(
                  SessionDeleting(
                    recording: state.recording,
                    afterUpload: false,
                  ),
                )
              // A post-upload cleanup can only follow a confirmed success,
              // which never passes through `ready` (§18).
              : _reject(state, event, 'no confirmed upload success'),
        _ => _reject(state, event, 'ready'),
      };

  SessionTransition _fromUploading(
    SessionUploading state,
    SessionEvent event,
  ) => switch (event) {
    UploadBegan(:final int totalBytes, :final bool resumed) =>
      SessionTransition(
        SessionUploading(
          recording: state.recording,
          name: state.name,
          destinationId: state.destinationId,
          bytesSent: 0,
          totalBytes: totalBytes,
          retries: state.retries,
          resumed: resumed,
        ),
      ),
    UploadProgressed(
      :final int bytesSent,
      :final int totalBytes,
      :final int? chunkIndex,
      :final int? chunkCount,
    ) =>
      // Confirmed progress never moves backwards on screen, and never exceeds
      // the total (design `1j`).
      SessionTransition(
        state.copyWith(
          bytesSent: bytesSent.clamp(state.bytesSent, totalBytes),
          chunkIndex: chunkIndex,
          chunkCount: chunkCount,
        ),
      ),
    UploadRetried() => SessionTransition(
      state.copyWith(retries: state.retries + 1),
    ),
    UploadCancellationRequested() => SessionTransition(
      state.copyWith(cancelling: true),
    ),
    UploadEnded(:final RemoteUploadResult? result, :final bool cancelled)
        when result != null && !cancelled =>
      SessionTransition(
        SessionDeleting(recording: state.recording, afterUpload: true),
      ),
    UploadEnded(:final bool cancelled, :final int bytesConfirmed)
        when cancelled =>
      SessionTransition(
        SessionReady(
          recording: state.recording,
          name: state.name,
          everUploaded: false,
          lastError: UploadError.cancelled(
            'Upload cancelled at $bytesConfirmed bytes.',
          ),
        ),
      ),
    UploadEnded(:final UploadError? error, :final int bytesConfirmed)
        when error != null =>
      SessionTransition(
        SessionUploadFailed(
          recording: state.recording,
          name: state.name,
          destinationId: state.destinationId,
          error: error,
          bytesConfirmed: bytesConfirmed,
          canResume: bytesConfirmed > 0 && error.isRetryable,
        ),
      ),
    _ => _reject(state, event, 'uploading'),
  };

  SessionTransition _fromUploadFailed(
    SessionUploadFailed state,
    SessionEvent event,
  ) => switch (event) {
    UploadRequested(:final String destinationId) => SessionTransition(
      SessionUploading(
        recording: state.recording,
        name: state.name,
        destinationId: destinationId,
        bytesSent: 0,
        totalBytes: state.recording.sizeBytes,
      ),
    ),
    RecordingRenamed(:final String name, :final RecordingFile? recording) =>
      SessionTransition(
        SessionReady(
          recording: recording ?? state.recording,
          name: name,
          everUploaded: state.everUploaded,
        ),
      ),
    SourcePickerDismissed() => SessionTransition(
      SessionReady(
        recording: state.recording,
        name: state.name,
        everUploaded: state.everUploaded,
        lastError: state.error,
      ),
    ),
    LocalDeletionStarted(:final DeletionReason reason) =>
      reason == DeletionReason.userRequested
          ? SessionTransition(
              SessionDeleting(recording: state.recording, afterUpload: false),
            )
          : _reject(state, event, 'no confirmed upload success'),
    _ => _reject(state, event, 'uploadFailed'),
  };

  SessionTransition _fromDeleting(SessionDeleting state, SessionEvent event) =>
      switch (event) {
        LocalDeletionCompleted() => const SessionTransition(SessionIdle()),
        LocalDeletionFailed(:final String message) => SessionTransition(
          SessionFailed(
            code: RecorderErrorCode.unknown,
            message: message,
            retainedArtifactPath: state.recording.path,
          ),
        ),
        _ => _reject(state, event, 'deleting'),
      };

  SessionActive _degrade(SessionActive state, RecorderErrorCode code) =>
      switch (code) {
        RecorderErrorCode.microphoneUnavailable => state.copyWith(
          microphoneAvailable: false,
          microphoneEnabled: false,
          degradedReason: code,
        ),
        RecorderErrorCode.cameraUnavailable => state.copyWith(
          cameraAvailable: false,
          cameraEnabled: false,
          degradedReason: code,
        ),
        RecorderErrorCode.systemAudioUnavailable => state.copyWith(
          systemAudioAvailable: false,
          systemAudioEnabled: false,
          degradedReason: code,
        ),
        _ => state.copyWith(degradedReason: code),
      };

  SessionTransition _reject(
    SessionState state,
    SessionEvent event,
    String reason,
  ) => SessionTransition(
    state,
    rejected: true,
    reason: '${event.runtimeType} is not legal in $reason',
  );
}
