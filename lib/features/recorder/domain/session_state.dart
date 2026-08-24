import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:upload_core/upload_core.dart';

/// Coarse phase of the session, for presentation and logging.
enum SessionPhase {
  idle,
  selectingSource,
  preflight,
  preparing,
  recording,
  paused,
  stopping,
  finalizing,
  ready,
  uploading,
  uploadFailed,
  deleting,
  failed,
}

/// The recording session state machine of `TECHNICAL_SPEC.md` §19.
///
/// A sealed hierarchy rather than a bag of booleans: `paused` cannot coexist
/// with `uploading`, and `ready` always carries a file
/// (`docs/ARCHITECTURE.md` → *State and ownership*).
sealed class SessionState {
  const SessionState();

  SessionPhase get phase;

  /// The finalized file, once one exists. Null before finalization.
  RecordingFile? get file => null;
}

class SessionIdle extends SessionState {
  const SessionIdle();

  @override
  SessionPhase get phase => SessionPhase.idle;
}

class SessionSelectingSource extends SessionState {
  const SessionSelectingSource({
    this.sources = const <CaptureSource>[],
    this.selected,
    this.loading = true,
    this.error,
  });

  final List<CaptureSource> sources;
  final CaptureSource? selected;
  final bool loading;
  final RecorderErrorCode? error;

  SessionSelectingSource copyWith({
    List<CaptureSource>? sources,
    CaptureSource? selected,
    bool? loading,
    RecorderErrorCode? error,
  }) => SessionSelectingSource(
    sources: sources ?? this.sources,
    selected: selected ?? this.selected,
    loading: loading ?? this.loading,
    error: error ?? this.error,
  );

  @override
  SessionPhase get phase => SessionPhase.selectingSource;
}

/// Permission preflight (design `1d`).
class SessionPreflight extends SessionState {
  const SessionPreflight({
    required this.report,
    required this.blockingDenials,
    required this.source,
    this.degradedInputs = const <PermissionKind>{},
  });

  final PermissionReport report;

  /// Non-empty means recording is impossible — in practice, screen recording
  /// itself was refused (§23).
  final Set<PermissionKind> blockingDenials;

  /// Optional inputs that will be switched off for this session because the OS
  /// will not deliver them. These never block Start.
  final Set<PermissionKind> degradedInputs;

  final CaptureSource source;

  bool get canStart => blockingDenials.isEmpty;

  @override
  SessionPhase get phase => SessionPhase.preflight;
}

class SessionPreparing extends SessionState {
  const SessionPreparing(this.source);

  final CaptureSource source;

  @override
  SessionPhase get phase => SessionPhase.preparing;
}

/// `recording ⇄ paused`, plus the brief `stopping` window.
class SessionActive extends SessionState {
  const SessionActive({
    required this.source,
    required this.elapsed,
    required this.microphoneEnabled,
    required this.cameraEnabled,
    required this.systemAudioEnabled,
    this.microphoneAvailable = true,
    this.cameraAvailable = true,
    this.systemAudioAvailable = true,
    this.isPaused = false,
    this.isStopping = false,
    this.degradedReason,
  });

  final CaptureSource source;
  final Duration elapsed;
  final bool microphoneEnabled;
  final bool cameraEnabled;
  final bool systemAudioEnabled;
  final bool microphoneAvailable;
  final bool cameraAvailable;
  final bool systemAudioAvailable;
  final bool isPaused;
  final bool isStopping;

  /// A non-fatal capture error that degraded the session but did not end it.
  final RecorderErrorCode? degradedReason;

  SessionActive copyWith({
    Duration? elapsed,
    bool? microphoneEnabled,
    bool? cameraEnabled,
    bool? systemAudioEnabled,
    bool? microphoneAvailable,
    bool? cameraAvailable,
    bool? systemAudioAvailable,
    bool? isPaused,
    bool? isStopping,
    RecorderErrorCode? degradedReason,
  }) => SessionActive(
    source: source,
    elapsed: elapsed ?? this.elapsed,
    microphoneEnabled: microphoneEnabled ?? this.microphoneEnabled,
    cameraEnabled: cameraEnabled ?? this.cameraEnabled,
    systemAudioEnabled: systemAudioEnabled ?? this.systemAudioEnabled,
    microphoneAvailable: microphoneAvailable ?? this.microphoneAvailable,
    cameraAvailable: cameraAvailable ?? this.cameraAvailable,
    systemAudioAvailable: systemAudioAvailable ?? this.systemAudioAvailable,
    isPaused: isPaused ?? this.isPaused,
    isStopping: isStopping ?? this.isStopping,
    degradedReason: degradedReason ?? this.degradedReason,
  );

  @override
  SessionPhase get phase => isStopping
      ? SessionPhase.stopping
      : isPaused
      ? SessionPhase.paused
      : SessionPhase.recording;
}

class SessionFinalizing extends SessionState {
  const SessionFinalizing();

  @override
  SessionPhase get phase => SessionPhase.finalizing;
}

/// The recording exists on disk and is waiting for Send or Delete (§13).
class SessionReady extends SessionState {
  const SessionReady({
    required this.recording,
    required this.name,
    this.everUploaded = false,
    this.lastError,
  });

  final RecordingFile recording;

  /// The editable name, without extension (design `1i`).
  final String name;

  /// Drives the Delete confirmation rule: confirm only while the recording has
  /// never reached a destination
  /// (`docs/adr/2026-08-22-delete-confirmation.md`).
  final bool everUploaded;

  /// Set after a cancelled upload returns here.
  final UploadError? lastError;

  SessionReady copyWith({
    RecordingFile? recording,
    String? name,
    bool? everUploaded,
    UploadError? lastError,
  }) => SessionReady(
    recording: recording ?? this.recording,
    name: name ?? this.name,
    everUploaded: everUploaded ?? this.everUploaded,
    lastError: lastError,
  );

  @override
  SessionPhase get phase => SessionPhase.ready;

  @override
  RecordingFile? get file => recording;
}

class SessionUploading extends SessionState {
  const SessionUploading({
    required this.recording,
    required this.name,
    required this.destinationId,
    required this.bytesSent,
    required this.totalBytes,
    this.chunkIndex,
    this.chunkCount,
    this.retries = 0,
    this.resumed = false,
    this.cancelling = false,
  });

  final RecordingFile recording;
  final String name;
  final String destinationId;

  /// Bytes the destination confirmed, never bytes handed to a socket.
  final int bytesSent;

  final int totalBytes;
  final int? chunkIndex;
  final int? chunkCount;
  final int retries;
  final bool resumed;
  final bool cancelling;

  double get fraction =>
      totalBytes <= 0 ? 0 : (bytesSent / totalBytes).clamp(0.0, 1.0);

  SessionUploading copyWith({
    int? bytesSent,
    int? chunkIndex,
    int? chunkCount,
    int? retries,
    bool? resumed,
    bool? cancelling,
  }) => SessionUploading(
    recording: recording,
    name: name,
    destinationId: destinationId,
    bytesSent: bytesSent ?? this.bytesSent,
    totalBytes: totalBytes,
    chunkIndex: chunkIndex ?? this.chunkIndex,
    chunkCount: chunkCount ?? this.chunkCount,
    retries: retries ?? this.retries,
    resumed: resumed ?? this.resumed,
    cancelling: cancelling ?? this.cancelling,
  );

  @override
  SessionPhase get phase => SessionPhase.uploading;

  @override
  RecordingFile? get file => recording;
}

/// Upload failed. The local file is untouched (§13 failure rule).
class SessionUploadFailed extends SessionState {
  const SessionUploadFailed({
    required this.recording,
    required this.name,
    required this.destinationId,
    required this.error,
    required this.bytesConfirmed,
    this.canResume = false,
    this.everUploaded = false,
  });

  final RecordingFile recording;
  final String name;
  final String destinationId;
  final UploadError error;
  final int bytesConfirmed;
  final bool canResume;
  final bool everUploaded;

  @override
  SessionPhase get phase => SessionPhase.uploadFailed;

  @override
  RecordingFile? get file => recording;
}

/// The local file is being removed — either on explicit Delete, or as the
/// silent post-upload cleanup (§18).
class SessionDeleting extends SessionState {
  const SessionDeleting({required this.recording, required this.afterUpload});

  final RecordingFile recording;
  final bool afterUpload;

  @override
  SessionPhase get phase => SessionPhase.deleting;

  @override
  RecordingFile? get file => recording;
}

/// A fatal capture error. Any partial artefact is left on disk for recovery.
class SessionFailed extends SessionState {
  const SessionFailed({
    required this.code,
    required this.message,
    this.retainedArtifactPath,
  });

  final RecorderErrorCode code;
  final String message;
  final String? retainedArtifactPath;

  @override
  SessionPhase get phase => SessionPhase.failed;
}
