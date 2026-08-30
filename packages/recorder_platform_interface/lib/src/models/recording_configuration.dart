import 'package:flutter/foundation.dart';

import 'camera_overlay_configuration.dart';
import 'capture_source.dart';
import 'media_device.dart';
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
    this.cameraDeviceId,
    this.microphoneDeviceId,
    this.systemAudioDeviceId,
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

  /// Which device each input opens, or null for the platform's own default
  /// (§33.2).
  ///
  /// Null is the shipped behaviour: an unconfigured session records exactly
  /// what it recorded before devices could be chosen. An id the platform can no
  /// longer resolve falls back to the default rather than failing the
  /// preparation — a wrong microphone is a degraded recording, a refused
  /// `prepare` is none at all.
  final String? cameraDeviceId;
  final String? microphoneDeviceId;

  /// Ignored where [MediaDeviceKind.systemAudio] is not in
  /// `RecorderCapabilities.selectableDeviceKinds`.
  final String? systemAudioDeviceId;

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
    Object? cameraDeviceId = _unset,
    Object? microphoneDeviceId = _unset,
    Object? systemAudioDeviceId = _unset,
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
    cameraDeviceId: identical(cameraDeviceId, _unset)
        ? this.cameraDeviceId
        : cameraDeviceId as String?,
    microphoneDeviceId: identical(microphoneDeviceId, _unset)
        ? this.microphoneDeviceId
        : microphoneDeviceId as String?,
    systemAudioDeviceId: identical(systemAudioDeviceId, _unset)
        ? this.systemAudioDeviceId
        : systemAudioDeviceId as String?,
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
    // Always present, null included: the configuration map is documented key by
    // key, and a key that disappears makes the documented example a lie.
    'cameraDeviceId': cameraDeviceId,
    'microphoneDeviceId': microphoneDeviceId,
    'systemAudioDeviceId': systemAudioDeviceId,
    'cameraOverlay': cameraOverlay.toMap(),
    'composition': composition.toMap(),
  };
}

/// Sentinel for [RecordingConfiguration.copyWith], so a nullable device id can
/// be cleared back to "the platform default" rather than only overwritten.
const Object _unset = Object();
