import 'dart:math' as math;

import 'upload_error.dart';

/// Bounded exponential backoff for transient upload failures (§14).
///
/// Deliberately not a broad retry loop: only errors the destination marked
/// retryable are retried, and only [maxAttempts] times
/// (`docs/development/testing.md`).
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 4,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.multiplier = 2.0,
  }) : assert(maxAttempts >= 1, 'maxAttempts must be at least 1');

  /// No retries — used by destinations that cannot resume a partial transfer.
  static const RetryPolicy none = RetryPolicy(maxAttempts: 1);

  final int maxAttempts;
  final Duration initialDelay;
  final Duration maxDelay;
  final double multiplier;

  bool shouldRetry(UploadError error, int attempt) =>
      attempt < maxAttempts &&
      error.isRetryable &&
      error.kind != UploadErrorKind.cancelled;

  /// Delay before [attempt] (1-based). Honours a destination-supplied
  /// `retryAfter` when it is longer than the computed backoff.
  Duration delayFor(int attempt, {UploadError? error}) {
    final double scaled =
        initialDelay.inMilliseconds *
        math.pow(multiplier, attempt - 1).toDouble();
    final Duration backoff = Duration(
      milliseconds: math.min(scaled.round(), maxDelay.inMilliseconds),
    );
    final Duration? hinted = error?.retryAfter;
    if (hinted != null && hinted > backoff) {
      return hinted > maxDelay ? maxDelay : hinted;
    }
    return backoff;
  }
}
