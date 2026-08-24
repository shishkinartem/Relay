import 'package:meta/meta.dart';

import 'upload_error.dart';

/// Where one upload attempt currently is (§14).
///
/// `succeeded` is emitted only once the destination has confirmed the remote
/// object exists. Local deletion is driven from that event and nothing else
/// (§18).
@immutable
sealed class UploadEvent {
  const UploadEvent(this.uploadId);

  final String uploadId;
}

class UploadValidating extends UploadEvent {
  const UploadValidating(super.uploadId);
}

class UploadStarted extends UploadEvent {
  const UploadStarted(
    super.uploadId, {
    required this.totalBytes,
    this.resumed = false,
  });

  final int totalBytes;

  /// True when an interrupted session was continued rather than restarted.
  final bool resumed;
}

/// How far the transfer has got.
///
/// [bytesSent] is what the destination can account for. A resumable
/// destination reports the offset its server acknowledged, which is what
/// design `1j` means by never showing 100% before the remote object exists. A
/// destination that cannot resume has no such signal and reports bytes written
/// to the request body; it says so through
/// [UploadCapabilities.supportsResume].
///
/// Either way, progress is a display value and nothing more. It never
/// authorizes anything: local deletion follows [UploadSucceeded] alone
/// (`TECHNICAL_SPEC.md` §18), so a non-resumable destination reaching 100%
/// before its response arrives cannot cause a premature delete.
class UploadProgress extends UploadEvent {
  const UploadProgress(
    super.uploadId, {
    required this.bytesSent,
    required this.totalBytes,
    this.chunkIndex,
    this.chunkCount,
  });

  final int bytesSent;
  final int totalBytes;
  final int? chunkIndex;
  final int? chunkCount;

  double get fraction =>
      totalBytes <= 0 ? 0 : (bytesSent / totalBytes).clamp(0.0, 1.0);
}

class UploadRetrying extends UploadEvent {
  const UploadRetrying(
    super.uploadId, {
    required this.attempt,
    required this.delay,
    required this.cause,
  });

  final int attempt;
  final Duration delay;
  final UploadError cause;
}

class UploadSucceeded extends UploadEvent {
  const UploadSucceeded(super.uploadId, this.result);

  final RemoteUploadResult result;
}

class UploadFailed extends UploadEvent {
  const UploadFailed(super.uploadId, this.error, {this.bytesSent = 0});

  final UploadError error;

  /// How far the attempt got, so a resumable destination can report it.
  final int bytesSent;
}

class UploadCancelled extends UploadEvent {
  const UploadCancelled(super.uploadId, {this.bytesSent = 0});

  final int bytesSent;
}

/// What the destination created (§17).
@immutable
class RemoteUploadResult {
  const RemoteUploadResult({
    required this.destinationId,
    required this.remoteFileId,
    required this.remoteName,
    this.remoteUrl,
    this.bytesUploaded = 0,
  });

  final String destinationId;
  final String remoteFileId;
  final String remoteName;
  final String? remoteUrl;
  final int bytesUploaded;
}
