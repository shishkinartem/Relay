import 'package:meta/meta.dart';

/// The local artefact handed to a destination.
///
/// Deliberately not the recorder's `RecordingFile`: the upload packages know
/// nothing about capture, and the recorder feature knows nothing about
/// Telegram or Drive (§14). The application maps between the two.
@immutable
class UploadFile {
  const UploadFile({
    required this.path,
    required this.sizeBytes,
    required this.displayName,
    this.mimeType = 'video/mp4',
    this.duration,
  });

  final String path;
  final int sizeBytes;

  /// Name shown at the destination, including extension.
  final String displayName;

  final String mimeType;
  final Duration? duration;

  @override
  bool operator ==(Object other) =>
      other is UploadFile &&
      other.path == path &&
      other.sizeBytes == sizeBytes &&
      other.displayName == displayName &&
      other.mimeType == mimeType;

  @override
  int get hashCode => Object.hash(path, sizeBytes, displayName, mimeType);

  @override
  String toString() => 'UploadFile($displayName, $sizeBytes bytes)';
}

/// Per-upload context that is not a property of the file itself.
@immutable
class UploadContext {
  const UploadContext({required this.uploadId, this.caption});

  /// Correlates progress, cancellation and logs for one attempt.
  final String uploadId;

  final String? caption;
}
