import 'package:test/test.dart';
import 'package:upload_core/upload_core.dart';

void main() {
  group('UploadCapabilities', () {
    test('a destination with no limit accepts anything', () {
      const UploadCapabilities capabilities = UploadCapabilities();
      expect(capabilities.accepts(0), isTrue);
      expect(capabilities.accepts(64 * 1024 * 1024 * 1024), isTrue);
    });

    test('a limit is inclusive at the boundary', () {
      const int limit = 50 * 1024 * 1024;
      const UploadCapabilities capabilities = UploadCapabilities(
        maxFileSizeBytes: limit,
      );
      expect(capabilities.accepts(limit - 1), isTrue);
      expect(capabilities.accepts(limit), isTrue);
      expect(capabilities.accepts(limit + 1), isFalse);
    });
  });

  group('RetryPolicy', () {
    test('only retryable errors are retried', () {
      const RetryPolicy policy = RetryPolicy();
      expect(
        policy.shouldRetry(const UploadError.network('dropped'), 1),
        isTrue,
      );
      expect(
        policy.shouldRetry(const UploadError.authentication('no'), 1),
        isFalse,
      );
      expect(
        policy.shouldRetry(const UploadError.fileTooLarge('too big'), 1),
        isFalse,
      );
    });

    test('cancellation is never retried, even if marked retryable', () {
      const RetryPolicy policy = RetryPolicy();
      const UploadError cancelled = UploadError(
        UploadErrorKind.cancelled,
        'stopped',
        isRetryable: true,
      );
      expect(policy.shouldRetry(cancelled, 1), isFalse);
    });

    test('attempts are capped', () {
      const RetryPolicy policy = RetryPolicy(maxAttempts: 3);
      const UploadError error = UploadError.network('dropped');
      expect(policy.shouldRetry(error, 1), isTrue);
      expect(policy.shouldRetry(error, 2), isTrue);
      expect(policy.shouldRetry(error, 3), isFalse);
    });

    test('RetryPolicy.none never retries', () {
      expect(
        RetryPolicy.none.shouldRetry(const UploadError.network('x'), 1),
        isFalse,
      );
    });

    test('backoff grows and is clamped to maxDelay', () {
      const RetryPolicy policy = RetryPolicy(
        initialDelay: Duration(seconds: 1),
        maxDelay: Duration(seconds: 5),
      );
      expect(policy.delayFor(1), const Duration(seconds: 1));
      expect(policy.delayFor(2), const Duration(seconds: 2));
      expect(policy.delayFor(3), const Duration(seconds: 4));
      expect(policy.delayFor(4), const Duration(seconds: 5));
      expect(policy.delayFor(9), const Duration(seconds: 5));
    });

    test('a destination-supplied retryAfter wins when it is longer', () {
      const RetryPolicy policy = RetryPolicy(
        initialDelay: Duration(seconds: 1),
        maxDelay: Duration(seconds: 30),
      );
      const UploadError rateLimited = UploadError(
        UploadErrorKind.rateLimited,
        'slow down',
        retryAfter: Duration(seconds: 12),
        isRetryable: true,
      );
      expect(
        policy.delayFor(1, error: rateLimited),
        const Duration(seconds: 12),
      );
      // ...but never past the ceiling.
      const UploadError absurd = UploadError(
        UploadErrorKind.rateLimited,
        'slow down',
        retryAfter: Duration(minutes: 10),
        isRetryable: true,
      );
      expect(policy.delayFor(1, error: absurd), const Duration(seconds: 30));
    });

    test('a shorter retryAfter does not shrink the backoff', () {
      const RetryPolicy policy = RetryPolicy(
        initialDelay: Duration(seconds: 4),
      );
      const UploadError hint = UploadError(
        UploadErrorKind.rateLimited,
        'x',
        retryAfter: Duration(seconds: 1),
        isRetryable: true,
      );
      expect(policy.delayFor(1, error: hint), const Duration(seconds: 4));
    });
  });

  group('UploadProgress', () {
    test('fraction is clamped and safe at zero total', () {
      expect(
        const UploadProgress('u', bytesSent: 50, totalBytes: 100).fraction,
        0.5,
      );
      expect(
        const UploadProgress('u', bytesSent: 500, totalBytes: 100).fraction,
        1.0,
      );
      expect(
        const UploadProgress('u', bytesSent: 10, totalBytes: 0).fraction,
        0.0,
      );
    });
  });

  group('UploadValidationResult', () {
    test('carries the typed rejection', () {
      const UploadValidationResult ok = UploadValidationResult.ok();
      expect(ok.isValid, isTrue);
      expect(ok.error, isNull);

      const UploadValidationResult rejected = UploadValidationResult.rejected(
        UploadError.fileTooLarge('50 MB limit'),
      );
      expect(rejected.isValid, isFalse);
      expect(rejected.error!.kind, UploadErrorKind.fileTooLarge);
    });
  });

  group('InMemoryCredentialStore', () {
    test('writes, reads and deletes', () async {
      final CredentialStore store = InMemoryCredentialStore();
      expect(await store.read('k'), isNull);
      await store.write('k', 'v');
      expect(await store.read('k'), 'v');
      await store.delete('k');
      expect(await store.read('k'), isNull);
    });
  });
}
