import 'package:flutter/foundation.dart';

import 'camera_overlay_configuration.dart';
import 'capture_source.dart';
import 'recording_quality.dart';
import 'video_composition_configuration.dart';

/// Everything the platform needs to open a capture session (§20).
@immutable
class RecordingConfiguration {
  const RecordingConfiguration({
    required this.source,
    required this.recordingId,
    required this.outputDirectoryPath,
    this.quality = RecordingQuality.hd720,
    this.frameRate = 30,
    this.cameraEnabled = false,
    this.microphoneEnabled = true,
    this.systemAudioEnabled = true,
    this.showCursor = true,
    this.cameraOverlay = const CameraOverlayConfiguration(),
    this.composition = const VideoCompositionConfiguration(),
  });

  final CaptureSource source;

  /// Identifies the on-disk artefacts: `recording-<id>.part` then
  /// `recording-<id>.mp4` (§18).
  final String recordingId;

  final String outputDirectoryPath;
  final RecordingQuality quality;
  final int frameRate;

  /// Camera default is OFF (§7).
  final bool cameraEnabled;

  /// Microphone default is ON (§8).
  final bool microphoneEnabled;

  /// System audio default is ON (§8).
  final bool systemAudioEnabled;

  /// The cursor is part of the recording (§4.3).
  final bool showCursor;

  final CameraOverlayConfiguration cameraOverlay;
  final VideoCompositionConfiguration composition;

  RecordingConfiguration copyWith({
    CaptureSource? source,
    String? recordingId,
    String? outputDirectoryPath,
    RecordingQuality? quality,
    int? frameRate,
    bool? cameraEnabled,
    bool? microphoneEnabled,
    bool? systemAudioEnabled,
    bool? showCursor,
    CameraOverlayConfiguration? cameraOverlay,
    VideoCompositionConfiguration? composition,
  }) => RecordingConfiguration(
    source: source ?? this.source,
    recordingId: recordingId ?? this.recordingId,
    outputDirectoryPath: outputDirectoryPath ?? this.outputDirectoryPath,
    quality: quality ?? this.quality,
    frameRate: frameRate ?? this.frameRate,
    cameraEnabled: cameraEnabled ?? this.cameraEnabled,
    microphoneEnabled: microphoneEnabled ?? this.microphoneEnabled,
    systemAudioEnabled: systemAudioEnabled ?? this.systemAudioEnabled,
    showCursor: showCursor ?? this.showCursor,
    cameraOverlay: cameraOverlay ?? this.cameraOverlay,
    composition: composition ?? this.composition,
  );

  Map<String, Object?> toMap() => <String, Object?>{
    'sourceId': source.id,
    'sourceType': source.type.name,
    'sourceWidth': source.pixelWidth,
    'sourceHeight': source.pixelHeight,
    'recordingId': recordingId,
    'outputDirectoryPath': outputDirectoryPath,
    'quality': quality.name,
    'targetHeight': quality.targetHeight,
    'frameRate': frameRate,
    'cameraEnabled': cameraEnabled,
    'microphoneEnabled': microphoneEnabled,
    'systemAudioEnabled': systemAudioEnabled,
    'showCursor': showCursor,
    'cameraOverlay': cameraOverlay.toMap(),
    'composition': composition.toMap(),
  };
}
