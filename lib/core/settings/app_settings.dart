import 'package:flutter/foundation.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

/// User settings persisted between launches (§10, §15).
///
/// Values here are session *defaults*: the launch screen may override quality,
/// fps and the input toggles for one session without writing them back.
@immutable
class AppSettings {
  const AppSettings({
    this.uploadDestinationId = defaultUploadDestinationId,
    this.localRecordingsDirectory,
    this.quality = RecordingQuality.hd720,
    this.frameRate = defaultFrameRate,
    this.microphoneEnabled = true,
    this.systemAudioEnabled = true,
    this.cameraEnabled = false,
    this.showCursor = true,
    this.preferredSourceType = CaptureSourceType.display,
  });

  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
    uploadDestinationId:
        _string(json, keyUploadDestinationId) ?? defaultUploadDestinationId,
    localRecordingsDirectory: _string(json, keyLocalRecordingsDirectory),
    quality: _quality(json[keyQuality]),
    frameRate: _frameRate(json[keyFrameRate]),
    microphoneEnabled: _bool(json, keyMicrophoneEnabled, true),
    systemAudioEnabled: _bool(json, keySystemAudioEnabled, true),
    cameraEnabled: _bool(json, keyCameraEnabled, false),
    showCursor: _bool(json, keyShowCursor, true),
    preferredSourceType: _sourceType(json[keyPreferredSourceType]),
  );

  /// Schema version of the document [toJson] writes.
  static const int currentSchemaVersion = 2;

  /// Telegram is the only destination this build ships (§15, §16, and
  /// `docs/adr/2026-08-23-telegram-only-destination.md`).
  static const String defaultUploadDestinationId = 'telegram';

  static const int defaultFrameRate = 30;

  static const String keySchemaVersion = 'schemaVersion';
  static const String keyUploadDestinationId = 'uploadDestinationId';
  static const String keyLocalRecordingsDirectory = 'localRecordingsDirectory';
  static const String keyQuality = 'quality';
  static const String keyFrameRate = 'frameRate';
  static const String keyMicrophoneEnabled = 'microphoneEnabled';
  static const String keySystemAudioEnabled = 'systemAudioEnabled';
  static const String keyCameraEnabled = 'cameraEnabled';
  static const String keyShowCursor = 'showCursor';
  static const String keyPreferredSourceType = 'preferredSourceType';

  /// Identifier of the single active upload destination (§15).
  final String uploadDestinationId;

  /// Null means "the platform default directory", resolved at use time.
  final String? localRecordingsDirectory;

  final RecordingQuality quality;
  final int frameRate;
  final bool microphoneEnabled;
  final bool systemAudioEnabled;
  final bool cameraEnabled;
  final bool showCursor;
  final CaptureSourceType preferredSourceType;

  AppSettings copyWith({
    String? uploadDestinationId,
    Object? localRecordingsDirectory = _unset,
    RecordingQuality? quality,
    int? frameRate,
    bool? microphoneEnabled,
    bool? systemAudioEnabled,
    bool? cameraEnabled,
    bool? showCursor,
    CaptureSourceType? preferredSourceType,
  }) => AppSettings(
    uploadDestinationId: uploadDestinationId ?? this.uploadDestinationId,
    localRecordingsDirectory: identical(localRecordingsDirectory, _unset)
        ? this.localRecordingsDirectory
        : localRecordingsDirectory as String?,
    quality: quality ?? this.quality,
    frameRate: frameRate ?? this.frameRate,
    microphoneEnabled: microphoneEnabled ?? this.microphoneEnabled,
    systemAudioEnabled: systemAudioEnabled ?? this.systemAudioEnabled,
    cameraEnabled: cameraEnabled ?? this.cameraEnabled,
    showCursor: showCursor ?? this.showCursor,
    preferredSourceType: preferredSourceType ?? this.preferredSourceType,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    keySchemaVersion: currentSchemaVersion,
    keyUploadDestinationId: uploadDestinationId,
    keyLocalRecordingsDirectory: localRecordingsDirectory,
    keyQuality: quality.name,
    keyFrameRate: frameRate,
    keyMicrophoneEnabled: microphoneEnabled,
    keySystemAudioEnabled: systemAudioEnabled,
    keyCameraEnabled: cameraEnabled,
    keyShowCursor: showCursor,
    keyPreferredSourceType: preferredSourceType.name,
  };

  static const Object _unset = Object();

  static String? _string(Map<String, Object?> json, String key) {
    final Object? value = json[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  static bool _bool(Map<String, Object?> json, String key, bool fallback) {
    final Object? value = json[key];
    return value is bool ? value : fallback;
  }

  static RecordingQuality _quality(Object? value) => value is String
      ? RecordingQuality.fromName(value)
      : RecordingQuality.hd720;

  static int _frameRate(Object? value) =>
      value is int && value > 0 ? value : defaultFrameRate;

  static CaptureSourceType _sourceType(Object? value) => value is String
      ? CaptureSourceType.values.firstWhere(
          (CaptureSourceType type) => type.name == value,
          orElse: () => CaptureSourceType.display,
        )
      : CaptureSourceType.display;

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.uploadDestinationId == uploadDestinationId &&
      other.localRecordingsDirectory == localRecordingsDirectory &&
      other.quality == quality &&
      other.frameRate == frameRate &&
      other.microphoneEnabled == microphoneEnabled &&
      other.systemAudioEnabled == systemAudioEnabled &&
      other.cameraEnabled == cameraEnabled &&
      other.showCursor == showCursor &&
      other.preferredSourceType == preferredSourceType;

  @override
  int get hashCode => Object.hash(
    uploadDestinationId,
    localRecordingsDirectory,
    quality,
    frameRate,
    microphoneEnabled,
    systemAudioEnabled,
    cameraEnabled,
    showCursor,
    preferredSourceType,
  );

  @override
  String toString() =>
      'AppSettings(${quality.label}@$frameRate, $uploadDestinationId, '
      'mic: $microphoneEnabled, systemAudio: $systemAudioEnabled, '
      'camera: $cameraEnabled, cursor: $showCursor, '
      'source: ${preferredSourceType.name})';
}
