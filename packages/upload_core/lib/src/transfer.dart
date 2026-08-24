import 'dart:async';

import 'package:meta/meta.dart';

import 'upload_error.dart';
import 'upload_event.dart';

/// A cancellable transfer.
///
/// One per upload, handed to the destination so a cancel can reach the socket
/// rather than only the stream the caller is listening to. Cancelling is
/// idempotent and safe after the transfer has already finished.
class UploadJob {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when the upload is cancelled. Never completes otherwise.
  Future<void> get cancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }

  /// Waits out a retry backoff, returning early when the upload is cancelled.
  ///
  /// A cancel during a thirty-second backoff must not sit for thirty seconds
  /// before it takes effect.
  Future<void> waitFor(Duration delay) => Future.any(<Future<void>>[
    Future<void>.delayed(delay),
    _cancelled.future,
  ]);
}

/// Thrown inside an attempt when the job was cancelled. Never escapes it.
class UploadAborted implements Exception {
  const UploadAborted();
}

/// Bounds an attempt that stops making progress.
///
/// `dart:io` applies no request or response timeout by default, so without this
/// a server that accepts the body and never answers hangs the upload — and with
/// it the recording — forever.
class TransferDeadline {
  TransferDeadline(this._window) {
    _arm();
  }

  final Duration _window;
  final Completer<void> _expired = Completer<void>();
  Timer? _timer;

  /// Restarts the window: any byte that moves counts as progress.
  void touch() => _arm();

  /// Completes with [operation] unless the transfer stalls first, or — when
  /// [cancelledBy] is given — unless the upload is cancelled first.
  ///
  /// A late result or error from the loser is discarded by [Future.any], so an
  /// operation that answers after the deadline cannot resurrect the attempt.
  Future<T> guard<T>(
    Future<T> operation, {
    UploadJob? cancelledBy,
  }) => Future.any(<Future<T>>[
    operation,
    _expired.future.then<T>(
      (void _) =>
          throw TimeoutException('The server stalled for $_window.', _window),
    ),
    if (cancelledBy != null)
      cancelledBy.cancelled.then<T>((void _) => throw const UploadAborted()),
  ]);

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  void _arm() {
    if (_expired.isCompleted) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(_window, () {
      if (!_expired.isCompleted) {
        _expired.complete();
      }
    });
  }
}

/// Counts bytes as they leave, and stops the moment the job is cancelled.
///
/// Cancellation has to reach the body stream, not just the future waiting on
/// the response: a request whose body is still being read keeps the socket and
/// the file handle open however loudly the caller has stopped listening.
Stream<List<int>> countingStream(
  Stream<List<int>> source,
  UploadJob job,
  void Function(int bytesSent) onBytes,
) async* {
  int sent = 0;
  await for (final List<int> chunk in source) {
    if (job.isCancelled) {
      throw const UploadAborted();
    }
    yield chunk;
    sent += chunk.length;
    onBytes(sent);
  }
}

/// What one attempt produced.
///
/// Four outcomes, and the order the caller must resolve them in is a rule, not
/// a preference: a [result] outranks a cancel that arrived after the server
/// confirmed it. Reporting cancelled there would hide a recording that is
/// already on the far side and make a retry send it twice.
@immutable
class AttemptOutcome {
  const AttemptOutcome._({
    required this.bytesSent,
    this.result,
    this.error,
    this.isCancelled = false,
  });

  const AttemptOutcome.success(RemoteUploadResult result, int bytesSent)
    : this._(result: result, bytesSent: bytesSent);

  const AttemptOutcome.failed(UploadError error, int bytesSent)
    : this._(error: error, bytesSent: bytesSent);

  const AttemptOutcome.aborted(int bytesSent)
    : this._(isCancelled: true, bytesSent: bytesSent);

  final RemoteUploadResult? result;
  final UploadError? error;
  final bool isCancelled;
  final int bytesSent;
}
