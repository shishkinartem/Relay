/// Capture-side failures, as typed states rather than free-form strings (§19).
enum RecorderErrorCode {
  permissionDenied,
  sourceUnavailable,
  sourceClosed,
  cameraUnavailable,
  microphoneUnavailable,
  systemAudioUnavailable,
  captureFailed,
  encodingFailed,
  diskFull,
  finalizationFailed,
  invalidState,
  unsupported,
  unknown;

  static RecorderErrorCode fromName(String? name) => values.firstWhere(
    (RecorderErrorCode c) => c.name == name,
    orElse: () => RecorderErrorCode.unknown,
  );

  /// Whether the session can keep running after this error.
  ///
  /// An optional input failing (camera, microphone, system audio) degrades the
  /// session; anything touching the video track or the file ends it.
  bool get isRecoverableDuringSession => switch (this) {
    RecorderErrorCode.cameraUnavailable ||
    RecorderErrorCode.microphoneUnavailable ||
    RecorderErrorCode.systemAudioUnavailable => true,
    _ => false,
  };
}

/// A capture failure crossing the platform boundary.
class RecorderException implements Exception {
  const RecorderException(this.code, this.message, {this.details});

  final RecorderErrorCode code;
  final String message;
  final String? details;

  @override
  String toString() => 'RecorderException(${code.name}: $message)';
}
