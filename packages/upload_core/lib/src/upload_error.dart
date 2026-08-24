/// Why an upload could not complete.
///
/// Destination-specific transport failures are mapped onto these before they
/// leave the destination, so the application never inspects an HTTP status
/// (§14, `docs/architecture/uploads.md`).
enum UploadErrorKind {
  /// The connection dropped, timed out or was refused.
  network,

  /// Not signed in, token rejected, or consent withdrawn.
  authentication,

  /// The file exceeds the destination's hard limit — known before sending.
  fileTooLarge,

  /// The destination is not configured (missing bot token, chat id, ...).
  notConfigured,

  /// A resumable session expired and could not be revived.
  sessionExpired,

  /// The destination refused the request for its own reasons.
  destinationRejected,

  /// The destination is rate limiting; retry after a delay.
  rateLimited,

  /// The local file disappeared or could not be read.
  localFileUnavailable,

  /// The user cancelled.
  cancelled,

  unknown,
}

/// A typed upload failure.
class UploadError implements Exception {
  const UploadError(
    this.kind,
    this.message, {
    this.details,
    this.retryAfter,
    this.isRetryable = false,
  });

  const UploadError.network(String message, {String? details})
    : this(
        UploadErrorKind.network,
        message,
        details: details,
        isRetryable: true,
      );

  const UploadError.authentication(String message, {String? details})
    : this(UploadErrorKind.authentication, message, details: details);

  const UploadError.fileTooLarge(String message, {String? details})
    : this(UploadErrorKind.fileTooLarge, message, details: details);

  const UploadError.cancelled([String message = 'Upload cancelled.'])
    : this(UploadErrorKind.cancelled, message);

  final UploadErrorKind kind;
  final String message;
  final String? details;

  /// Set when the destination told us how long to wait.
  final Duration? retryAfter;

  /// Whether retrying the same attempt can plausibly succeed.
  final bool isRetryable;

  @override
  String toString() => 'UploadError.${kind.name}: $message';
}
