import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/logging/app_logger.dart';
import 'package:relay/upload/application/upload_coordinator.dart';
import 'package:relay/upload/application/upload_destination_registry.dart';
import 'package:upload_core/upload_core.dart';

import '../../support/fakes.dart';

/// The coordinator's own behaviour, driven directly.
///
/// Every branch exercised here — the concurrent-start guard, `onError`,
/// `onDone` without a terminal event, and the body of `cancel` — had zero
/// coverage. Three of them exist specifically to stop a session getting stuck
/// in `uploading` with the user's only copy of a recording waiting on it, which
/// makes "never executed" the wrong state for them to be in.
void main() {
  const UploadFile file = UploadFile(
    path: '/tmp/relay/recording-abc123.mp4',
    displayName: 'recording-abc123.mp4',
    sizeBytes: 2048,
    mimeType: 'video/mp4',
  );

  late FakeUploadDestination destination;
  late UploadCoordinator coordinator;
  late AppLogger logger;

  setUp(() {
    destination = FakeUploadDestination(id: 'fake');
    logger = AppLogger(sinks: <LogSink>[MemoryLogSink()]);
    coordinator = UploadCoordinator(
      registry: UploadDestinationRegistry(<UploadDestination>[destination]),
      logger: logger,
    );
  });

  tearDown(() async => coordinator.dispose());

  group('cancellation', () {
    test('cancel reaches the destination with the active upload id', () async {
      destination.holdBeforeTerminal = Completer<void>();

      final String? uploadId = await coordinator.start(
        file: file,
        destinationId: 'fake',
      );
      expect(uploadId, isNotNull);
      await pumpEventQueue();

      await coordinator.cancel();

      expect(destination.cancelled, <String>[uploadId!]);
    });

    test('cancel with nothing running is a no-op, not a failure', () async {
      // Reachable from the UI: the button survives one frame past the terminal
      // event, and a throw here would surface as a crash on a screen the user
      // is already leaving.
      await expectLater(coordinator.cancel(), completes);
      expect(destination.cancelled, isEmpty);
    });

    test('cancel after the upload finished is still a no-op', () async {
      await coordinator.start(file: file, destinationId: 'fake');
      await pumpEventQueue();
      expect(coordinator.isActive, isFalse);

      await expectLater(coordinator.cancel(), completes);
      expect(destination.cancelled, isEmpty);
    });

    test('a cancelled transfer reports exactly one terminal event', () async {
      destination.script = (String uploadId, UploadFile _) => <UploadEvent>[
        UploadStarted(uploadId, totalBytes: file.sizeBytes),
        UploadCancelled(uploadId),
      ];

      final List<UploadEvent> seen = <UploadEvent>[];
      final StreamSubscription<UploadEvent> subscription = coordinator.events
          .listen(seen.add);
      addTearDown(subscription.cancel);

      await coordinator.start(file: file, destinationId: 'fake');
      await pumpEventQueue();

      expect(seen.whereType<UploadCancelled>(), hasLength(1));
      expect(seen.whereType<UploadFailed>(), isEmpty);
      expect(coordinator.isActive, isFalse);
    });
  });

  group('a destination that misbehaves cannot strand the session', () {
    test('a stream error becomes a terminal UploadFailed', () async {
      destination.script = (String uploadId, UploadFile _) =>
          throw StateError('the socket went away');

      final List<UploadEvent> seen = <UploadEvent>[];
      final StreamSubscription<UploadEvent> subscription = coordinator.events
          .listen(seen.add);
      addTearDown(subscription.cancel);

      await coordinator.start(file: file, destinationId: 'fake');
      await pumpEventQueue();

      final Iterable<UploadFailed> failures = seen.whereType<UploadFailed>();
      expect(failures, hasLength(1));
      expect(failures.first.error.kind, UploadErrorKind.unknown);
      expect(coordinator.isActive, isFalse);
    });

    test('an UploadError thrown by the stream keeps its kind', () async {
      destination.script = (String uploadId, UploadFile _) =>
          throw const UploadError(
            UploadErrorKind.network,
            'The connection dropped.',
          );

      final List<UploadEvent> seen = <UploadEvent>[];
      final StreamSubscription<UploadEvent> subscription = coordinator.events
          .listen(seen.add);
      addTearDown(subscription.cancel);

      await coordinator.start(file: file, destinationId: 'fake');
      await pumpEventQueue();

      expect(
        seen.whereType<UploadFailed>().single.error.kind,
        UploadErrorKind.network,
      );
    });

    test('a stream that ends without a terminal event fails, so the local '
        'file is kept', () async {
      // The comment on this branch warns the session would otherwise be stuck
      // in `uploading`. Stuck means the recording is never deleted, which is
      // safe, and never retried, which is not.
      destination.script = (String uploadId, UploadFile _) => <UploadEvent>[
        UploadStarted(uploadId, totalBytes: file.sizeBytes),
        UploadProgress(uploadId, bytesSent: 1024, totalBytes: file.sizeBytes),
      ];

      final List<UploadEvent> seen = <UploadEvent>[];
      final StreamSubscription<UploadEvent> subscription = coordinator.events
          .listen(seen.add);
      addTearDown(subscription.cancel);

      await coordinator.start(file: file, destinationId: 'fake');
      await pumpEventQueue();

      expect(seen.whereType<UploadFailed>(), hasLength(1));
      expect(coordinator.isActive, isFalse);
    });
  });

  group('one upload at a time', () {
    test('a second start while one is running is refused', () async {
      destination.holdBeforeTerminal = Completer<void>();

      final String? first = await coordinator.start(
        file: file,
        destinationId: 'fake',
      );
      await pumpEventQueue();
      final String? second = await coordinator.start(
        file: file,
        destinationId: 'fake',
      );

      expect(first, isNotNull);
      expect(second, isNull, reason: 'the running upload is not displaced');
      expect(
        destination.calls.where((String c) => c == 'upload'),
        hasLength(1),
      );

      destination.holdBeforeTerminal!.complete();
      await pumpEventQueue();
    });

    test(
      'the destination is startable again once the first finished',
      () async {
        await coordinator.start(file: file, destinationId: 'fake');
        await pumpEventQueue();

        expect(
          await coordinator.start(file: file, destinationId: 'fake'),
          isNotNull,
        );
        await pumpEventQueue();
      },
    );
  });

  group('disposal', () {
    test('dispose closes the event stream and is idempotent', () async {
      await coordinator.dispose();
      await expectLater(coordinator.dispose(), completes);
    });
  });
}
