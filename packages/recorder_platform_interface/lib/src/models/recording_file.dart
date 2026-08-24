import 'package:flutter/foundation.dart';

/// A finalized recording on local disk (§18).
@immutable
class RecordingFile {
  const RecordingFile({
    required this.path,
    required this.recordingId,
    required this.sizeBytes,
    required this.duration,
    required this.createdAt,
    required this.width,
    required this.height,
    required this.frameRate,
    this.hasAudio = true,
    this.hasCamera = false,
  });

  final String path;
  final String recordingId;
  final int sizeBytes;

  /// Duration of the produced file. Paused intervals are not part of it.
  final Duration duration;

  final DateTime createdAt;
  final int width;
  final int height;
  final int frameRate;
  final bool hasAudio;
  final bool hasCamera;

  RecordingFile copyWith({String? path, int? sizeBytes}) => RecordingFile(
    path: path ?? this.path,
    recordingId: recordingId,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    duration: duration,
    createdAt: createdAt,
    width: width,
    height: height,
    frameRate: frameRate,
    hasAudio: hasAudio,
    hasCamera: hasCamera,
  );

  static RecordingFile fromMap(Map<String, Object?> map) => RecordingFile(
    path: map['path']! as String,
    recordingId: map['recordingId'] as String? ?? '',
    sizeBytes: (map['sizeBytes'] as num? ?? 0).toInt(),
    duration: Duration(milliseconds: (map['durationMs'] as num? ?? 0).toInt()),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      (map['createdAtMs'] as num? ?? 0).toInt(),
    ),
    width: (map['width'] as num? ?? 0).toInt(),
    height: (map['height'] as num? ?? 0).toInt(),
    frameRate: (map['frameRate'] as num? ?? 0).toInt(),
    hasAudio: map['hasAudio'] as bool? ?? true,
    hasCamera: map['hasCamera'] as bool? ?? false,
  );

  @override
  String toString() => 'RecordingFile($path, $sizeBytes bytes, $duration)';
}

/// An unfinished `.part` artefact discovered at startup (§18).
@immutable
class IncompleteRecordingArtifact {
  const IncompleteRecordingArtifact({
    required this.path,
    required this.recordingId,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String path;
  final String recordingId;
  final int sizeBytes;
  final DateTime modifiedAt;
}
