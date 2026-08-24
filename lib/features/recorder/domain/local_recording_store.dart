import 'dart:async';
import 'dart:io';

import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../core/logging/app_logger.dart';
import 'recording_naming.dart';
import 'session_events.dart';

/// The recordings directory, as the session sees it (§18).
///
/// Deletion takes a stated [DeletionReason] on purpose: "never delete before a
/// confirmed remote success" is a property of the signature, not of a comment,
/// and it survives any substitution of this interface.
abstract interface class RecordingStore {
  /// What an unfinished recording is called on disk. Part of the contract, not
  /// of one implementation: startup recovery and the failure path both name a
  /// file by it (§18).
  static const String partSuffix = '.part';

  /// Where recordings are written.
  Directory get directory;

  Future<void> ensureExists();

  Future<List<IncompleteRecordingArtifact>> findIncompleteArtifacts();

  Future<RecordingFile> rename(RecordingFile recording, String newName);

  Future<void> delete(RecordingFile recording, DeletionReason reason);

  Future<void> discardArtifact(String path);

  String pathForName(String name);
}

/// Owns the local recording files (§18).
///
/// Every destructive operation states why it is happening. There is no
/// unqualified `delete(path)`, so "the upload started" or "the socket closed"
/// cannot become a deletion by accident — a caller must name one of the two
/// reasons the specification allows.
class LocalRecordingStore implements RecordingStore {
  LocalRecordingStore({required this.directory, required this._logger});

  @override
  final Directory directory;
  final Logger _logger;

  /// The interface's constant, re-exported so existing call sites keep working.
  static const String partSuffix = RecordingStore.partSuffix;

  @override
  Future<void> ensureExists() async {
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
  }

  /// Unfinished artefacts left by a crash or a forced quit.
  ///
  /// Enumeration only — nothing here deletes or finalizes anything (§18).
  @override
  Future<List<IncompleteRecordingArtifact>> findIncompleteArtifacts() async {
    if (!directory.existsSync()) {
      return const <IncompleteRecordingArtifact>[];
    }
    final List<IncompleteRecordingArtifact> found =
        <IncompleteRecordingArtifact>[];
    // Synchronous listing on purpose: these are a handful of entries in one
    // local folder, and the synchronous call is the only form that also works
    // under a widget test's fake-async zone.
    for (final FileSystemEntity entity in directory.listSync()) {
      if (entity is! File || !entity.path.endsWith(partSuffix)) {
        continue;
      }
      final FileStat stat = entity.statSync();
      if (stat.size <= 0) {
        continue;
      }
      found.add(
        IncompleteRecordingArtifact(
          path: entity.path,
          recordingId: _recordingIdFrom(entity.path),
          sizeBytes: stat.size,
          modifiedAt: stat.modified,
        ),
      );
    }
    found.sort(
      (IncompleteRecordingArtifact a, IncompleteRecordingArtifact b) =>
          b.modifiedAt.compareTo(a.modifiedAt),
    );
    return found;
  }

  /// Renames the recording on disk to match a user-edited name.
  ///
  /// Never overwrites an existing file: a colliding name gets a numeric
  /// suffix, because silently replacing another recording would be a data loss
  /// the user did not ask for.
  @override
  Future<RecordingFile> rename(RecordingFile recording, String newName) async {
    final File current = File(recording.path);
    if (!current.existsSync()) {
      throw const RecorderException(
        RecorderErrorCode.finalizationFailed,
        'The recording is no longer on disk.',
      );
    }
    final String target = _uniquePathFor(newName, exclude: recording.path);
    if (target == recording.path) {
      return recording;
    }
    final File moved = current.renameSync(target);
    _logger.info(
      'recording_renamed',
      fields: <String, Object?>{
        'recordingId': recording.recordingId,
        'name': newName,
      },
    );
    return recording.copyWith(path: moved.path);
  }

  /// Removes a finalized recording. Idempotent, and safe to call twice.
  @override
  Future<void> delete(RecordingFile recording, DeletionReason reason) async {
    final File file = File(recording.path);
    if (!file.existsSync()) {
      _logger.info(
        'local_delete_noop',
        fields: <String, Object?>{
          'recordingId': recording.recordingId,
          'reason': reason.name,
        },
      );
      return;
    }
    file.deleteSync();
    _logger.info(
      'local_delete',
      fields: <String, Object?>{
        'recordingId': recording.recordingId,
        'reason': reason.name,
        'sizeBytes': recording.sizeBytes,
      },
    );
  }

  /// Removes an unfinished artefact. Only ever called from the explicit
  /// "Discard file" action in the recovery screen (design `1n`).
  @override
  Future<void> discardArtifact(String path) async {
    final File file = File(path);
    if (file.existsSync()) {
      file.deleteSync();
    }
    _logger.info(
      'artifact_discarded',
      fields: <String, Object?>{'recordingId': _recordingIdFrom(path)},
    );
  }

  @override
  String pathForName(String name) =>
      '${directory.path}${Platform.pathSeparator}${RecordingNaming.fileName(name)}';

  String _uniquePathFor(String name, {String? exclude}) {
    String candidate = pathForName(name);
    int suffix = 2;
    while (candidate != exclude && File(candidate).existsSync()) {
      candidate = pathForName('$name-$suffix');
      suffix++;
    }
    return candidate;
  }

  static String _recordingIdFrom(String path) {
    final String base = path.split(Platform.pathSeparator).last;
    final RegExpMatch? match = RegExp(r'^recording-(.+?)\.part$')
        .firstMatch(base);
    return match?.group(1) ?? base;
  }
}
