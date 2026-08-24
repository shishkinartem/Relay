import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:upload_core/upload_core.dart';

/// The transfer loop every destination now shares.
///
/// It used to exist twice, in two ~250-line copies that had already drifted.
/// These assert the contract the base class promises, once, for both — and for
/// any destination added later.
void main() {
  late Directory directory;
  late File recording;
  late UploadFile file;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('relay_transfer_');
    recording = File('${directory.path}/recording-abc123.mp4')
      ..writeAsBytesSync(List<int>.filled(2048, 7));
    file = UploadFile(
      path: recording.path,
      displayName: 'recording-abc123.mp4',
      sizeBytes: 2048,
      mimeType: 'video/mp4',
    );
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  const UploadContext context = UploadContext(uploadId: 'u1');

  Future<List<UploadEvent>> run(
    _ScriptedDestination destination, {
    UploadFile? uploadFile,
  }) => destination.upload(uploadFile ?? file, context).toList();

  group('exactly one terminal event', () {
    test('a success ends in UploadSucceeded and nothing after it', () async {
      final List<UploadEvent> events = await run(
        _ScriptedDestination(<_Step>[const _Step.success()]),
      );

      expect(events.whereType<UploadStarted>(), hasLength(1));
      expect(_terminals(events), hasLength(1));
      expect(events.last, isA<UploadSucceeded>());
    });

    test('a non-retryable failure ends in UploadFailed', () async {
      final List<UploadEvent> events = await run(
        _ScriptedDestination(<_Step>[
          const _Step.failure(UploadErrorKind.authentication),
        ]),
      );

      expect(_terminals(events), hasLength(1));
      expect(
        (events.last as UploadFailed).error.kind,
        UploadErrorKind.authentication,
      );
    });

    test('an attempt that throws still produces one terminal event', () async {
      // No escape route may close the stream silently or surface as an
      // unhandled zone error.
      final List<UploadEvent> events = await run(
        _ScriptedDestination(<_Step>[const _Step.explode()]),
      );

      expect(_terminals(events), hasLength(1));
      expect(events.last, isA<UploadFailed>());
      expect((events.last as UploadFailed).error.kind, UploadErrorKind.unknown);
    });

    test('a rejected pre-flight fails without starting a transfer', () async {
      final _ScriptedDestination destination = _ScriptedDestination(
        <_Step>[const _Step.success()],
        rejection: const UploadError(
          UploadErrorKind.fileTooLarge,
          'Too big for this destination.',
        ),
      );

      final List<UploadEvent> events = await run(destination);

      expect(destination.attempts, 0, reason: 'no bytes moved');
      expect(events, hasLength(1));
      expect(
        (events.single as UploadFailed).error.kind,
        UploadErrorKind.fileTooLarge,
      );
    });

    test('a recording that is gone fails before any attempt', () async {
      recording.deleteSync();

      final _ScriptedDestination destination = _ScriptedDestination(<_Step>[
        const _Step.success(),
      ]);
      final List<UploadEvent> events = await run(destination);

      expect(destination.attempts, 0);
      expect(
        (events.single as UploadFailed).error.kind,
        UploadErrorKind.localFileUnavailable,
      );
    });

    test('the destination pre-flights itself but announces nothing', () async {
      // `UploadValidating` belongs to the coordinator, which emits it once for
      // every destination. One of the two used to emit a second copy of its
      // own and validate the same file twice.
      final _ScriptedDestination destination = _ScriptedDestination(<_Step>[
        const _Step.success(),
      ]);
      final List<UploadEvent> events = await run(destination);

      expect(destination.validations, 1);
      expect(events.whereType<UploadValidating>(), isEmpty);
    });
  });

  group('retries', () {
    test('a retryable failure is attempted again and then succeeds', () async {
      final _ScriptedDestination destination = _ScriptedDestination(
        <_Step>[
          const _Step.failure(UploadErrorKind.network),
          const _Step.success(),
        ],
        retryPolicy: const RetryPolicy(
          maxAttempts: 3,
          initialDelay: Duration.zero,
        ),
      );

      final List<UploadEvent> events = await run(destination);

      expect(destination.attempts, 2);
      expect(events.whereType<UploadRetrying>(), hasLength(1));
      expect(events.last, isA<UploadSucceeded>());
      expect(_terminals(events), hasLength(1));
    });

    test('the policy cap is honoured, then it fails', () async {
      final _ScriptedDestination destination = _ScriptedDestination(
        List<_Step>.filled(6, const _Step.failure(UploadErrorKind.network)),
        retryPolicy: const RetryPolicy(
          maxAttempts: 3,
          initialDelay: Duration.zero,
        ),
      );

      final List<UploadEvent> events = await run(destination);

      expect(destination.attempts, 3);
      expect(events.last, isA<UploadFailed>());
      expect(_terminals(events), hasLength(1));
    });

    test('progress restarts at zero between attempts by default', () async {
      // A destination that re-sends from byte zero must say so, or the bar
      // appears to stall at whatever the failed attempt reached.
      final _ScriptedDestination destination = _ScriptedDestination(
        <_Step>[
          const _Step.failure(UploadErrorKind.network),
          const _Step.success(),
        ],
        retryPolicy: const RetryPolicy(
          maxAttempts: 3,
          initialDelay: Duration.zero,
        ),
      );

      final List<UploadEvent> events = await run(destination);

      expect(
        events.whereType<UploadProgress>().any(
          (UploadProgress p) => p.bytesSent == 0,
        ),
        isTrue,
      );
    });

    test('a resuming destination does not rewind the bar', () async {
      final _ScriptedDestination destination = _ScriptedDestination(
        <_Step>[
          const _Step.failure(UploadErrorKind.network),
          const _Step.success(),
        ],
        retryPolicy: const RetryPolicy(
          maxAttempts: 3,
          initialDelay: Duration.zero,
        ),
        retryRestartsProgress: false,
      );

      final List<UploadEvent> events = await run(destination);

      expect(events.whereType<UploadProgress>(), isEmpty);
      expect(events.last, isA<UploadSucceeded>());
    });
  });

  group('cancellation', () {
    test('a cancel before the first attempt ends the stream', () async {
      final _ScriptedDestination destination = _ScriptedDestination(<_Step>[
        const _Step.success(),
      ], cancelBeforeAttempt: true);

      final List<UploadEvent> events = await run(destination);

      expect(events.last, isA<UploadCancelled>());
      expect(_terminals(events), hasLength(1));
    });

    test('an aborted attempt reports how far it got', () async {
      final List<UploadEvent> events = await run(
        _ScriptedDestination(<_Step>[const _Step.aborted(900)]),
      );

      expect((events.last as UploadCancelled).bytesSent, 900);
    });

    test('a result the server confirmed outranks a later cancel', () async {
      // Reporting cancelled here would hide a recording that is already on the
      // far side, and a retry would send it twice.
      final _ScriptedDestination destination = _ScriptedDestination(<_Step>[
        const _Step.successThenCancel(),
      ]);

      final List<UploadEvent> events = await run(destination);

      expect(events.last, isA<UploadSucceeded>());
      expect(events.whereType<UploadCancelled>(), isEmpty);
    });

    test('cancel() reaches an upload in flight by id', () async {
      final _ScriptedDestination destination = _ScriptedDestination(<_Step>[
        const _Step.hang(),
      ]);

      final List<UploadEvent> seen = <UploadEvent>[];
      final Completer<void> done = Completer<void>();
      destination.upload(file, context).listen(seen.add, onDone: done.complete);

      await destination.attemptStarted.future;
      await destination.cancel('u1');
      await done.future;

      expect(seen.last, isA<UploadCancelled>());
    });

    test('cancelling the subscription stops the transfer', () async {
      final _ScriptedDestination destination = _ScriptedDestination(<_Step>[
        const _Step.hang(),
      ]);

      final StreamSubscription<UploadEvent> subscription = destination
          .upload(file, context)
          .listen((UploadEvent _) {});
      await destination.attemptStarted.future;
      await subscription.cancel();

      expect(destination.job!.isCancelled, isTrue);
    });
  });

  group('UploadJob', () {
    test('cancelling is idempotent', () {
      final UploadJob job = UploadJob();
      job.cancel();
      job.cancel();
      expect(job.isCancelled, isTrue);
    });

    test('a backoff returns early when the job is cancelled', () async {
      // A cancel during a thirty-second backoff must not sit for thirty
      // seconds before it takes effect.
      final UploadJob job = UploadJob();
      final Future<void> waiting = job.waitFor(const Duration(seconds: 30));
      job.cancel();
      await expectLater(waiting, completes);
    });
  });

  group('TransferDeadline', () {
    test('an operation that answers in time wins', () async {
      final TransferDeadline deadline = TransferDeadline(
        const Duration(seconds: 5),
      );
      addTearDown(deadline.dispose);

      expect(await deadline.guard(Future<int>.value(7)), 7);
    });

    test('a stalled operation times out', () async {
      // `dart:io` bounds neither the request nor the response, so without this
      // a server that accepts the body and never answers hangs the recording
      // forever.
      final TransferDeadline deadline = TransferDeadline(
        const Duration(milliseconds: 20),
      );
      addTearDown(deadline.dispose);

      await expectLater(
        deadline.guard(Completer<int>().future),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a cancel beats a stalled operation', () async {
      final TransferDeadline deadline = TransferDeadline(
        const Duration(seconds: 30),
      );
      addTearDown(deadline.dispose);
      final UploadJob job = UploadJob();

      final Future<int> guarded = deadline.guard(
        Completer<int>().future,
        cancelledBy: job,
      );
      job.cancel();

      await expectLater(guarded, throwsA(isA<UploadAborted>()));
    });

    test('progress re-arms the window', () async {
      final TransferDeadline deadline = TransferDeadline(
        const Duration(milliseconds: 60),
      );
      addTearDown(deadline.dispose);

      for (int i = 0; i < 4; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        deadline.touch();
      }

      // A slow but healthy upload is never cut short.
      expect(await deadline.guard(Future<int>.value(1)), 1);
    });
  });

  group('countingStream', () {
    test('every byte is counted exactly once', () async {
      final List<int> reported = <int>[];
      final List<List<int>> chunks = await countingStream(
        Stream<List<int>>.fromIterable(<List<int>>[
          <int>[1, 2, 3],
          <int>[4, 5],
        ]),
        UploadJob(),
        reported.add,
      ).toList();

      expect(chunks, hasLength(2));
      expect(reported, <int>[3, 5]);
    });

    test('a cancelled job stops the body mid-stream', () async {
      // Cancellation has to reach the body, not just the future waiting on the
      // response: a request still reading its body keeps the socket and the
      // file handle open.
      final UploadJob job = UploadJob();
      final Stream<List<int>> body = countingStream(
        Stream<List<int>>.fromIterable(<List<int>>[
          <int>[1],
          <int>[2],
          <int>[3],
        ]),
        job,
        (int _) => job.cancel(),
      );

      await expectLater(body.toList(), throwsA(isA<UploadAborted>()));
    });
  });
}

List<UploadEvent> _terminals(List<UploadEvent> events) => events
    .where(
      (UploadEvent e) =>
          e is UploadSucceeded || e is UploadFailed || e is UploadCancelled,
    )
    .toList(growable: false);

/// What one scripted attempt does.
class _Step {
  const _Step._(this.kind, {this.errorKind, this.bytesSent = 0});

  const _Step.success() : this._(_StepKind.success);
  const _Step.successThenCancel() : this._(_StepKind.successThenCancel);
  const _Step.failure(UploadErrorKind kind)
    : this._(_StepKind.failure, errorKind: kind);
  const _Step.aborted(int bytes) : this._(_StepKind.aborted, bytesSent: bytes);
  const _Step.explode() : this._(_StepKind.explode);
  const _Step.hang() : this._(_StepKind.hang);

  final _StepKind kind;
  final UploadErrorKind? errorKind;
  final int bytesSent;
}

enum _StepKind { success, successThenCancel, failure, aborted, explode, hang }

/// A destination whose attempts are a script, so the loop can be driven without
/// a socket.
class _ScriptedDestination extends RetryingUploadDestination {
  _ScriptedDestination(
    this._script, {
    super.retryPolicy,
    this.rejection,
    this.cancelBeforeAttempt = false,
    this.retryRestartsProgress = true,
  });

  final List<_Step> _script;
  final UploadError? rejection;
  final bool cancelBeforeAttempt;

  @override
  final bool retryRestartsProgress;

  int attempts = 0;
  int validations = 0;
  UploadJob? job;
  final Completer<void> attemptStarted = Completer<void>();

  @override
  Future<AttemptOutcome> attempt({
    required UploadFile file,
    required UploadContext context,
    required File source,
    required UploadJob job,
    required void Function(UploadEvent event) emit,
  }) async {
    this.job = job;
    if (!attemptStarted.isCompleted) {
      attemptStarted.complete();
    }
    final _Step step = _script[attempts.clamp(0, _script.length - 1)];
    attempts++;

    switch (step.kind) {
      case _StepKind.success:
        return AttemptOutcome.success(_result(file), file.sizeBytes);
      case _StepKind.successThenCancel:
        job.cancel();
        return AttemptOutcome.success(_result(file), file.sizeBytes);
      case _StepKind.failure:
        return AttemptOutcome.failed(
          UploadError(
            step.errorKind!,
            'scripted failure',
            // Retryability is a property of the error, not of its kind: only
            // an error the destination marked retryable is retried at all.
            isRetryable: step.errorKind == UploadErrorKind.network,
          ),
          0,
        );
      case _StepKind.aborted:
        return AttemptOutcome.aborted(step.bytesSent);
      case _StepKind.explode:
        throw StateError('the socket went away');
      case _StepKind.hang:
        await job.cancelled;
        return AttemptOutcome.aborted(0);
    }
  }

  RemoteUploadResult _result(UploadFile file) => RemoteUploadResult(
    destinationId: id,
    remoteFileId: 'remote-1',
    remoteName: file.displayName,
    bytesUploaded: file.sizeBytes,
  );

  @override
  UploadError unexpectedFailure(Object error) =>
      UploadError(UploadErrorKind.unknown, 'unexpected: $error');

  @override
  String get id => 'scripted';

  @override
  String get displayName => 'Scripted';

  @override
  UploadCapabilities get capabilities => const UploadCapabilities();

  @override
  DestinationSetup get setup => const DestinationSetup(
    kind: DestinationSetupKind.credentials,
    actionLabel: 'Connect',
    steps: <String>[],
    fields: <DestinationField>[],
  );

  @override
  Future<UploadValidationResult> validate(UploadFile file) async {
    validations++;
    if (cancelBeforeAttempt) {
      // The loop registers the job before it pre-flights, so cancelling by id
      // from here lands before the first attempt is ever considered.
      await cancel('u1');
    }
    final UploadError? error = rejection;
    return error == null
        ? const UploadValidationResult.ok()
        : UploadValidationResult.rejected(error);
  }

  @override
  Future<String?> describeAccount() async => 'scripted';

  @override
  Future<bool> isConnected() async => true;

  @override
  Future<void> connect(Map<String, String> values) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<Map<String, String>> storedSetupValues() async =>
      const <String, String>{};

  @override
  void dispose() {}
}
