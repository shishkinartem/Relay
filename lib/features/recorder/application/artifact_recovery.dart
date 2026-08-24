import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/local_recording_store.dart';

/// Unfinished `.part` artefacts found at launch (§18, design `1n`).
///
/// Declared next to its consumer. Split out of `RecorderViewModel` because
/// recovery is the one concern in the recorder that is entirely about files
/// that a *previous* process left behind — it has no session, no overlays and
/// no capture, and it runs once before anything else starts.
///
/// Nothing here deletes or finalizes on its own initiative. Every method is a
/// choice the user made on the recovery screen, which is the whole point of
/// that screen existing.
abstract interface class ArtifactRecovery {
  /// Artefacts still waiting for the user's decision, oldest first.
  List<IncompleteRecordingArtifact> get pending;

  /// Re-reads the recordings directory.
  Future<void> scan();

  /// Asks the platform to finalize [artifact].
  ///
  /// Returns the recovered file, or null when the artefact held nothing
  /// readable. The artefact is never deleted either way: an unreadable one
  /// stays on disk for the user to look at.
  Future<RecordingFile?> finalize(IncompleteRecordingArtifact artifact);

  /// Removes [artifact] from disk on the user's explicit instruction.
  Future<void> discard(IncompleteRecordingArtifact artifact);

  /// Stops offering the artefacts without touching them ("Keep as is").
  void dismiss();
}

/// [ArtifactRecovery] against the platform and the local store.
class PlatformArtifactRecovery implements ArtifactRecovery {
  PlatformArtifactRecovery({
    required this._recorder,
    required this._store,
    required this._logger,
  });

  /// The whole recorder contract for one method, because finalizing a
  /// half-written file is platform work: it is the encoder that knows what a
  /// readable fragment is.
  final Recorder _recorder;
  final RecordingStore _store;
  final Logger _logger;

  List<IncompleteRecordingArtifact> _pending =
      const <IncompleteRecordingArtifact>[];

  @override
  List<IncompleteRecordingArtifact> get pending => _pending;

  @override
  Future<void> scan() async {
    _pending = await _store.findIncompleteArtifacts();
    if (_pending.isNotEmpty) {
      _logger.warn(
        'incomplete_artifacts_found',
        fields: <String, Object?>{'count': _pending.length},
      );
    }
  }

  @override
  Future<RecordingFile?> finalize(IncompleteRecordingArtifact artifact) async {
    RecordingFile? recovered;
    try {
      recovered = await _recorder.recoverArtifact(artifact.path);
      if (recovered == null) {
        _logger.warn(
          'artifact_unrecoverable',
          fields: <String, Object?>{'recordingId': artifact.recordingId},
        );
      }
    } on RecorderException catch (e) {
      _logger.warn(
        'artifact_recovery_failed',
        fields: <String, Object?>{'code': e.code.name},
      );
    }
    // Rescanned either way: a successful finalize removes the `.part`, and a
    // failed one may still have changed what is on disk.
    await scan();
    return recovered;
  }

  @override
  Future<void> discard(IncompleteRecordingArtifact artifact) async {
    await _store.discardArtifact(artifact.path);
    await scan();
  }

  @override
  void dismiss() => _pending = const <IncompleteRecordingArtifact>[];
}
