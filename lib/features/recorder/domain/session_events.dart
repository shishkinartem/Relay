import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:upload_core/upload_core.dart';

/// Everything that can move the session (§19).
sealed class SessionEvent {
  const SessionEvent();
}

class SourcePickerOpened extends SessionEvent {
  const SourcePickerOpened();
}

class SourcesLoaded extends SessionEvent {
  const SourcesLoaded(this.sources, {this.preselect});

  final List<CaptureSource> sources;
  final CaptureSource? preselect;
}

class SourceEnumerationFailed extends SessionEvent {
  const SourceEnumerationFailed(this.code);

  final RecorderErrorCode code;
}

class SourceChosen extends SessionEvent {
  const SourceChosen(this.source);

  final CaptureSource source;
}

class SourcePickerDismissed extends SessionEvent {
  const SourcePickerDismissed();
}

class PreflightCompleted extends SessionEvent {
  const PreflightCompleted({
    required this.source,
    required this.report,
    required this.blockingDenials,
    this.degradedInputs = const <PermissionKind>{},
  });

  final CaptureSource source;
  final PermissionReport report;
  final Set<PermissionKind> blockingDenials;
  final Set<PermissionKind> degradedInputs;
}

class PreparationStarted extends SessionEvent {
  const PreparationStarted(this.source);

  final CaptureSource source;
}

class RecordingStarted extends SessionEvent {
  const RecordingStarted({
    required this.source,
    required this.microphoneEnabled,
    required this.cameraEnabled,
    required this.systemAudioEnabled,
    this.microphoneAvailable = true,
    this.cameraAvailable = true,
    this.systemAudioAvailable = true,
  });

  final CaptureSource source;
  final bool microphoneEnabled;
  final bool cameraEnabled;
  final bool systemAudioEnabled;

  /// Whether the platform can offer the input at all, as opposed to whether the
  /// user asked for it.
  ///
  /// The session used to start with all three assumed available, because the
  /// state defaulted them to true and nothing passed anything else. On a
  /// machine reporting `supportsCamera: false` the strip then rendered a live
  /// camera button whose only possible outcome was a mid-session error.
  final bool microphoneAvailable;
  final bool cameraAvailable;
  final bool systemAudioAvailable;
}

class RecordingTicked extends SessionEvent {
  const RecordingTicked(this.elapsed);

  final Duration elapsed;
}

class RecordingPaused extends SessionEvent {
  const RecordingPaused();
}

class RecordingResumed extends SessionEvent {
  const RecordingResumed();
}

class InputsChanged extends SessionEvent {
  const InputsChanged({
    required this.microphoneEnabled,
    required this.cameraEnabled,
    required this.systemAudioEnabled,
  });

  final bool microphoneEnabled;
  final bool cameraEnabled;
  final bool systemAudioEnabled;
}

class InputBecameUnavailable extends SessionEvent {
  const InputBecameUnavailable(this.code);

  final RecorderErrorCode code;
}

class StopRequested extends SessionEvent {
  const StopRequested();
}

class FinalizationStarted extends SessionEvent {
  const FinalizationStarted();
}

class RecordingFinalized extends SessionEvent {
  const RecordingFinalized(this.recording, this.name);

  final RecordingFile recording;
  final String name;
}

class CaptureFailed extends SessionEvent {
  const CaptureFailed({
    required this.code,
    required this.message,
    this.retainedArtifactPath,
  });

  final RecorderErrorCode code;
  final String message;
  final String? retainedArtifactPath;
}

class RecordingRenamed extends SessionEvent {
  const RecordingRenamed(this.name, {this.recording});

  final String name;

  /// Set once the file on disk has actually been renamed.
  final RecordingFile? recording;
}

class UploadRequested extends SessionEvent {
  const UploadRequested(this.destinationId);

  final String destinationId;
}

class UploadBegan extends SessionEvent {
  const UploadBegan({required this.totalBytes, required this.resumed});

  final int totalBytes;
  final bool resumed;
}

class UploadProgressed extends SessionEvent {
  const UploadProgressed({
    required this.bytesSent,
    required this.totalBytes,
    this.chunkIndex,
    this.chunkCount,
  });

  final int bytesSent;
  final int totalBytes;
  final int? chunkIndex;
  final int? chunkCount;
}

class UploadRetried extends SessionEvent {
  const UploadRetried();
}

class UploadCancellationRequested extends SessionEvent {
  const UploadCancellationRequested();
}

class UploadEnded extends SessionEvent {
  const UploadEnded.succeeded(this.result)
    : error = null,
      bytesConfirmed = 0,
      cancelled = false;

  const UploadEnded.failed(this.error, {this.bytesConfirmed = 0})
    : result = null,
      cancelled = false;

  const UploadEnded.cancelled({this.bytesConfirmed = 0})
    : result = null,
      error = null,
      cancelled = true;

  final RemoteUploadResult? result;
  final UploadError? error;
  final int bytesConfirmed;
  final bool cancelled;
}

/// Why a local recording is being removed.
///
/// The only two legitimate reasons in §18. Nothing else can produce a
/// [LocalDeletionStarted], which is what keeps "upload started" or "connection
/// closed" from ever deleting a file.
enum DeletionReason { userRequested, confirmedUploadSuccess }

class LocalDeletionStarted extends SessionEvent {
  const LocalDeletionStarted(this.reason);

  final DeletionReason reason;
}

class LocalDeletionCompleted extends SessionEvent {
  const LocalDeletionCompleted();
}

class LocalDeletionFailed extends SessionEvent {
  const LocalDeletionFailed(this.message);

  final String message;
}

/// Returns to `idle` from a terminal state.
class SessionReset extends SessionEvent {
  const SessionReset();
}
