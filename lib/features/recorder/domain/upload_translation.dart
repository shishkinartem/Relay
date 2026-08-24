import 'package:upload_core/upload_core.dart';

import 'session_events.dart';

/// The session event an upload's own event means (§14).
///
/// A pure function in the domain, so the mapping can be asserted without a
/// session, a platform or a destination — and so the translation cannot
/// quietly acquire a side effect. The one side effect this mapping *would*
/// need, deleting the local file after a confirmed remote success, is
/// deliberately not here: removal requires a stated [DeletionReason] and lives
/// behind `RecordingStore`, which keeps "never delete before confirmed remote
/// success" a property of the code rather than of a comment.
///
/// Returns null for an upload event that moves nothing. [UploadValidating] is
/// the only one: the session entered `uploading` when the transfer was
/// requested, and pre-flight happens inside that state.
SessionEvent? sessionEventForUpload(UploadEvent event) => switch (event) {
  UploadValidating() => null,
  UploadStarted(:final int totalBytes, :final bool resumed) => UploadBegan(
    totalBytes: totalBytes,
    resumed: resumed,
  ),
  UploadProgress(
    :final int bytesSent,
    :final int totalBytes,
    :final int? chunkIndex,
    :final int? chunkCount,
  ) =>
    UploadProgressed(
      bytesSent: bytesSent,
      totalBytes: totalBytes,
      chunkIndex: chunkIndex,
      chunkCount: chunkCount,
    ),
  UploadRetrying() => const UploadRetried(),
  UploadSucceeded(:final RemoteUploadResult result) => UploadEnded.succeeded(
    result,
  ),
  UploadFailed(:final UploadError error, :final int bytesSent) =>
    UploadEnded.failed(error, bytesConfirmed: bytesSent),
  UploadCancelled(:final int bytesSent) => UploadEnded.cancelled(
    bytesConfirmed: bytesSent,
  ),
};
