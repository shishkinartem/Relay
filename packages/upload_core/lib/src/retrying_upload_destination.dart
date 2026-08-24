import 'dart:async';
import 'dart:io';

import 'retry_policy.dart';
import 'transfer.dart';
import 'upload_destination.dart';
import 'upload_error.dart';
import 'upload_event.dart';
import 'upload_file.dart';

/// The transfer loop every destination needs, written once.
///
/// Telegram and WebDAV each carried their own copy of this — the controller,
/// the `onListen`/`onCancel` wiring, the pre-flight, the missing-file check,
/// the attempt loop, the retry backoff and the exactly-one-terminal-event
/// guarantee — and the two copies had already drifted: one emitted
/// [UploadValidating] and validated twice, the other did neither.
///
/// A subclass supplies [attempt] and nothing else. Everything a destination can
/// legitimately differ about is a hook with a documented default.
///
/// The contract this enforces on every subclass:
///
/// - the stream carries **exactly one** terminal event — [UploadSucceeded],
///   [UploadFailed] or [UploadCancelled] — and then closes;
/// - a confirmed remote result outranks a cancel that arrived after it;
/// - cancelling the subscription stops the transfer rather than leaving it
///   running headless;
/// - no escape route closes the stream silently or surfaces as an unhandled
///   zone error.
abstract class RetryingUploadDestination implements UploadDestination {
  RetryingUploadDestination({this.retryPolicy = const RetryPolicy()});

  /// How failures are retried. A subclass may read it to report a
  /// server-supplied backoff.
  final RetryPolicy retryPolicy;

  final Map<String, UploadJob> _active = <String, UploadJob>{};

  /// Sends the whole file once.
  ///
  /// Called again for each retry. It must not emit a terminal event — the loop
  /// owns those — and must report what happened through [AttemptOutcome].
  /// Progress events are its own to emit.
  Future<AttemptOutcome> attempt({
    required UploadFile file,
    required UploadContext context,
    required File source,
    required UploadJob job,
    required void Function(UploadEvent event) emit,
  });

  /// How a failure with no better description is reported.
  UploadError unexpectedFailure(Object error);

  /// Whether a retry restarts the byte count.
  ///
  /// True for a destination that re-sends from byte zero, which is most of
  /// them; false for one that genuinely resumes, so the progress bar does not
  /// jump backwards on a recovered transfer.
  bool get retryRestartsProgress => true;

  @override
  Stream<UploadEvent> upload(UploadFile file, UploadContext context) {
    final StreamController<UploadEvent> controller =
        StreamController<UploadEvent>();
    final UploadJob job = UploadJob();
    controller.onListen = () => unawaited(_run(file, context, job, controller));
    // Cancelling the subscription is the idiomatic way to stop listening, so it
    // must stop the transfer too instead of leaving it running headless.
    controller.onCancel = job.cancel;
    return controller.stream;
  }

  @override
  Future<void> cancel(String uploadId) async => _active[uploadId]?.cancel();

  Future<void> _run(
    UploadFile file,
    UploadContext context,
    UploadJob job,
    StreamController<UploadEvent> controller,
  ) async {
    final String uploadId = context.uploadId;
    _active[uploadId] = job;

    bool terminated = false;

    void emit(UploadEvent event) {
      if (!controller.isClosed) {
        controller.add(event);
      }
    }

    void terminate(UploadEvent event) {
      terminated = true;
      emit(event);
    }

    try {
      // Pre-flight belongs to the destination: it is the only party that knows
      // its own limits, and `upload()` has to be safe to call directly. The
      // coordinator's own call to `validate` is a separate concern — reporting
      // a rejection to the user before any bytes move — and it emits the
      // `UploadValidating` event for it. Nothing emits one here, which is what
      // one of the two destinations used to do and the other did not.
      final UploadError? rejection = (await validate(file)).error;
      if (rejection != null) {
        terminate(UploadFailed(uploadId, rejection));
        return;
      }

      final File source = File(file.path);
      if (!source.existsSync()) {
        terminate(
          UploadFailed(
            uploadId,
            UploadError(
              UploadErrorKind.localFileUnavailable,
              'The recording ${file.displayName} is no longer on disk.',
            ),
          ),
        );
        return;
      }

      emit(UploadStarted(uploadId, totalBytes: file.sizeBytes));

      int attemptNumber = 1;
      while (true) {
        if (job.isCancelled) {
          terminate(UploadCancelled(uploadId));
          return;
        }

        final AttemptOutcome outcome = await attempt(
          file: file,
          context: context,
          source: source,
          job: job,
          emit: emit,
        );

        // A confirmation the server already sent outranks a cancel that
        // arrived after it: reporting cancelled would hide a recording that is
        // on the far side and make a retry send it twice.
        final RemoteUploadResult? result = outcome.result;
        if (result != null) {
          terminate(UploadSucceeded(uploadId, result));
          return;
        }

        if (outcome.isCancelled || job.isCancelled) {
          terminate(UploadCancelled(uploadId, bytesSent: outcome.bytesSent));
          return;
        }

        final UploadError error = outcome.error ?? unexpectedFailure(outcome);
        if (!retryPolicy.shouldRetry(error, attemptNumber)) {
          terminate(
            UploadFailed(uploadId, error, bytesSent: outcome.bytesSent),
          );
          return;
        }

        final Duration delay = retryPolicy.delayFor(
          attemptNumber,
          error: error,
        );
        emit(
          UploadRetrying(
            uploadId,
            attempt: attemptNumber + 1,
            delay: delay,
            cause: error,
          ),
        );
        await job.waitFor(delay);
        if (job.isCancelled) {
          terminate(UploadCancelled(uploadId));
          return;
        }
        if (retryRestartsProgress) {
          emit(
            UploadProgress(uploadId, bytesSent: 0, totalBytes: file.sizeBytes),
          );
        }
        attemptNumber++;
      }
    } on Object catch (error) {
      // The contract is exactly one terminal event, so no escape route may
      // close the stream silently or surface as an unhandled zone error.
      if (!terminated) {
        terminate(UploadFailed(uploadId, unexpectedFailure(error)));
      }
    } finally {
      _active.remove(uploadId);
      await controller.close();
    }
  }
}
