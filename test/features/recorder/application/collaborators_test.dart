import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/logging/app_logger.dart';
import 'package:relay/features/recorder/application/artifact_recovery.dart';
import 'package:relay/features/recorder/application/permission_coordinator.dart';
import 'package:relay/features/recorder/application/source_catalog.dart';
import 'package:relay/features/recorder/domain/session_events.dart';
import 'package:relay/features/recorder/domain/upload_translation.dart';
import 'package:upload_core/upload_core.dart';

import '../../../support/fakes.dart';

/// The collaborators `RecorderViewModel` was split into.
///
/// Each is now testable on its own, which is the point of the split: the
/// enumeration latch, the permission failure rule and the recovery scan used to
/// be reachable only by driving a whole session.
void main() {
  late AppLogger logger;

  setUp(() => logger = AppLogger(sinks: <LogSink>[MemoryLogSink()]));

  group('SourceCatalog', () {
    PlatformSourceCatalog catalogFor(
      FakeRecorder recorder, {
      Duration timeout = const Duration(seconds: 8),
    }) => PlatformSourceCatalog(
      provider: recorder,
      logger: logger,
      timeout: timeout,
    );

    test(
      'a load replaces the list and preselects the current display',
      () async {
        final PlatformSourceCatalog catalog = catalogFor(FakeRecorder());

        expect(
          await catalog.load(refreshThumbnails: false),
          SourceLoadResult.loaded,
        );
        expect(catalog.sources, hasLength(3));
        expect(catalog.selected?.id, 'display:1', reason: '§5');
        expect(catalog.lastFailure, isNull);
      },
    );

    test('a second load while one is running is skipped, not queued', () async {
      // Two overlapping enumerations against ScreenCaptureKit is the case the
      // latch exists for.
      final FakeRecorder recorder = FakeRecorder();
      final PlatformSourceCatalog catalog = catalogFor(recorder);

      final Future<SourceLoadResult> first = catalog.load(
        refreshThumbnails: true,
      );
      final SourceLoadResult second = await catalog.load(
        refreshThumbnails: true,
      );

      expect(second, SourceLoadResult.skipped);
      expect(await first, SourceLoadResult.loaded);
      expect(
        recorder.calls.where((String c) => c.startsWith('getAvailableSources')),
        hasLength(1),
      );
    });

    test('the latch is released after a failure, so a retry can run', () async {
      // Left set, the first enumeration would be the only one that ever runs
      // and the picker would keep showing the launch-time snapshot forever.
      final FakeRecorder recorder = FakeRecorder()
        ..failOnEnumerate = const RecorderException(
          RecorderErrorCode.sourceUnavailable,
          'gone',
        );
      final PlatformSourceCatalog catalog = catalogFor(recorder);

      expect(
        await catalog.load(refreshThumbnails: true),
        SourceLoadResult.failed,
      );
      expect(catalog.isLoading, isFalse);

      recorder.failOnEnumerate = null;
      expect(
        await catalog.load(refreshThumbnails: true),
        SourceLoadResult.loaded,
      );
    });

    test('a refusal is reported by code, not by throwing', () async {
      final PlatformSourceCatalog catalog = catalogFor(
        FakeRecorder()
          ..failOnEnumerate = const RecorderException(
            RecorderErrorCode.permissionDenied,
            'no',
          ),
      );

      expect(
        await catalog.load(refreshThumbnails: true),
        SourceLoadResult.failed,
      );
      expect(catalog.lastFailure, RecorderErrorCode.permissionDenied);
    });

    test('a deadline is a failure, not an escaped exception', () async {
      // The timeout is not a `RecorderException`. Without its own clause it
      // escaped the load entirely and the caller never heard back.
      final FakeRecorder recorder = FakeRecorder()..hangOnEnumerate = true;
      final PlatformSourceCatalog catalog = catalogFor(
        recorder,
        timeout: const Duration(milliseconds: 20),
      );

      expect(
        await catalog.load(refreshThumbnails: true),
        SourceLoadResult.failed,
      );
      expect(catalog.lastFailure, RecorderErrorCode.sourceUnavailable);
      expect(catalog.isLoading, isFalse);
    });

    test(
      'a still-present selection survives a refresh with a new instance',
      () async {
        final FakeRecorder recorder = FakeRecorder();
        final PlatformSourceCatalog catalog = catalogFor(recorder);
        await catalog.load(refreshThumbnails: false);
        catalog.select(catalog.sources.last);
        final CaptureSource chosen = catalog.selected!;

        // A fresh snapshot: same ids, new values, which is what a re-captured
        // thumbnail looks like. The choice survives and the *instance* is
        // replaced, so the picker shows the new still rather than the old one.
        recorder.sources = <CaptureSource>[
          for (final CaptureSource source in FakeRecorder.defaultSources)
            CaptureSource(
              id: source.id,
              type: source.type,
              title: source.title,
              subtitle: '${source.subtitle} (refreshed)',
              pixelWidth: source.pixelWidth,
              pixelHeight: source.pixelHeight,
              isCurrentDisplay: source.isCurrentDisplay,
            ),
        ];
        await catalog.load(refreshThumbnails: true);

        expect(catalog.selected?.id, chosen.id);
        expect(catalog.selected?.subtitle, endsWith('(refreshed)'));
      },
    );

    test('a selection that has gone falls back to the default', () async {
      // A window the user closed. Keeping it selected fails `prepare` with
      // `sourceClosed` at the worst possible moment.
      final FakeRecorder recorder = FakeRecorder();
      final PlatformSourceCatalog catalog = catalogFor(recorder);
      await catalog.load(refreshThumbnails: false);
      catalog.select(catalog.sources.last);

      recorder.sources = <CaptureSource>[FakeRecorder.defaultSources.first];
      await catalog.load(refreshThumbnails: true);

      expect(catalog.selected?.id, 'display:1');
    });

    test('an empty platform selects nothing rather than guessing', () async {
      final PlatformSourceCatalog catalog = catalogFor(
        FakeRecorder()..sources = <CaptureSource>[],
      );
      await catalog.load(refreshThumbnails: false);

      expect(catalog.selected, isNull);
      expect(catalog.defaultSource, isNull);
      expect(catalog.preferredDisplay, isNull);
    });
  });

  group('PermissionCoordinator', () {
    PermissionCoordinator coordinatorFor(
      FakeRecorderPermissions permissions, {
      Duration checkTimeout = const Duration(seconds: 8),
    }) => PermissionCoordinator(
      permissions: permissions,
      logger: logger,
      checkTimeout: checkTimeout,
      promptTimeout: const Duration(minutes: 2),
    );

    test('the report is empty until it has been read once', () {
      final PermissionCoordinator coordinator = coordinatorFor(
        FakeRecorderPermissions(),
      );
      expect(coordinator.report.canRecordScreen, isFalse);
    });

    test(
      'a check that fails reports nothing granted, not the last answer',
      () async {
        // Degrading is safe; carrying a stale grant forward would start a
        // recording on an assumption.
        final FakeRecorderPermissions permissions = FakeRecorderPermissions();
        final PermissionCoordinator coordinator = coordinatorFor(permissions);
        await coordinator.refresh();
        expect(coordinator.report.canRecordScreen, isTrue);

        permissions.failOnCheck = true;
        await coordinator.refresh();

        expect(coordinator.report.canRecordScreen, isFalse);
      },
    );

    test('a check that never answers degrades rather than hanging', () async {
      final FakeRecorderPermissions permissions = FakeRecorderPermissions()
        ..hangOnCheck = true;
      final PermissionCoordinator coordinator = coordinatorFor(
        permissions,
        checkTimeout: const Duration(milliseconds: 20),
      );

      await coordinator.refresh();
      expect(coordinator.report.canRecordScreen, isFalse);
    });

    test('requestAndRefresh prompts, then re-reads', () async {
      // The prompt says what the user tapped; the report says what the system
      // now permits. On macOS those differ for screen recording.
      final FakeRecorderPermissions permissions = FakeRecorderPermissions();
      final PermissionCoordinator coordinator = coordinatorFor(permissions);

      await coordinator.requestAndRefresh(PermissionKind.microphone);

      expect(permissions.calls, contains('request(microphone)'));
      expect(permissions.calls.last, 'check');
    });

    test('a quiet request only asks about an unanswered permission', () async {
      final FakeRecorderPermissions permissions = FakeRecorderPermissions(
        statuses: <PermissionKind, PermissionStatus>{
          PermissionKind.screenRecording: PermissionStatus.granted,
          PermissionKind.microphone: PermissionStatus.denied,
          PermissionKind.camera: PermissionStatus.notDetermined,
        },
      );
      final PermissionCoordinator coordinator = coordinatorFor(permissions);
      await coordinator.refresh();
      permissions.calls.clear();

      await coordinator.requestQuietly(PermissionKind.microphone);
      expect(
        permissions.calls,
        isEmpty,
        reason: 'a denial is not re-prompted; that is what Settings is for',
      );

      await coordinator.requestQuietly(PermissionKind.camera);
      expect(permissions.calls, contains('request(camera)'));
    });

    test('a prompt that throws is swallowed, not propagated', () async {
      // It runs while the user is starting a recording. An exception here
      // would replace a start with a crash.
      final FakeRecorderPermissions permissions = FakeRecorderPermissions()
        ..failOnRequest = true;
      final PermissionCoordinator coordinator = coordinatorFor(permissions);

      await expectLater(coordinator.prompt(PermissionKind.camera), completes);
    });

    test('opening the privacy pane never throws at the caller', () async {
      final FakeRecorderPermissions permissions = FakeRecorderPermissions()
        ..failOnOpenSettings = true;
      final PermissionCoordinator coordinator = coordinatorFor(permissions);

      await expectLater(
        coordinator.openSettings(PermissionKind.screenRecording),
        completes,
      );
    });
  });

  group('ArtifactRecovery', () {
    test('a scan reports what the store found', () async {
      final FakeRecordingStore store = FakeRecordingStore(
        artifacts: <IncompleteRecordingArtifact>[_artifact('abc123')],
      );
      final PlatformArtifactRecovery recovery = PlatformArtifactRecovery(
        recorder: FakeRecorder(),
        store: store,
        logger: logger,
      );

      await recovery.scan();
      expect(recovery.pending, hasLength(1));
    });

    test('an unrecoverable artefact stays on disk', () async {
      // §18: nothing is deleted because it could not be read.
      final FakeRecordingStore store = FakeRecordingStore(
        artifacts: <IncompleteRecordingArtifact>[_artifact('abc123')],
      );
      final PlatformArtifactRecovery recovery = PlatformArtifactRecovery(
        recorder: FakeRecorder()..recoverResult = null,
        store: store,
        logger: logger,
      );
      await recovery.scan();

      expect(await recovery.finalize(recovery.pending.first), isNull);
      expect(store.discarded, isEmpty);
    });

    test(
      'a platform failure is reported as nothing recovered, not a throw',
      () async {
        final PlatformArtifactRecovery recovery = PlatformArtifactRecovery(
          recorder: FakeRecorder()
            ..failOnRecover = const RecorderException(
              RecorderErrorCode.finalizationFailed,
              'nope',
            ),
          store: FakeRecordingStore(
            artifacts: <IncompleteRecordingArtifact>[_artifact('abc123')],
          ),
          logger: logger,
        );
        await recovery.scan();

        expect(await recovery.finalize(recovery.pending.first), isNull);
      },
    );

    test('discarding removes only the artefact named', () async {
      final FakeRecordingStore store = FakeRecordingStore(
        artifacts: <IncompleteRecordingArtifact>[
          _artifact('abc123'),
          _artifact('def456'),
        ],
      );
      final PlatformArtifactRecovery recovery = PlatformArtifactRecovery(
        recorder: FakeRecorder(),
        store: store,
        logger: logger,
      );
      await recovery.scan();

      await recovery.discard(recovery.pending.first);
      expect(store.discarded, <String>['/tmp/recording-abc123.part']);
    });

    test('dismissing keeps every file and stops offering them', () async {
      final FakeRecordingStore store = FakeRecordingStore(
        artifacts: <IncompleteRecordingArtifact>[_artifact('abc123')],
      );
      final PlatformArtifactRecovery recovery = PlatformArtifactRecovery(
        recorder: FakeRecorder(),
        store: store,
        logger: logger,
      );
      await recovery.scan();

      recovery.dismiss();

      expect(recovery.pending, isEmpty);
      expect(store.discarded, isEmpty, reason: '"Keep as is" deletes nothing');
    });
  });

  group('upload translation (§14)', () {
    test('validation moves nothing', () {
      // The session entered `uploading` when the transfer was requested.
      expect(sessionEventForUpload(const UploadValidating('u1')), isNull);
    });

    test('every other event maps to exactly one session event', () {
      final List<UploadEvent> events = <UploadEvent>[
        const UploadStarted('u1', totalBytes: 2048),
        const UploadProgress('u1', bytesSent: 1024, totalBytes: 2048),
        const UploadRetrying(
          'u1',
          attempt: 2,
          delay: Duration(seconds: 1),
          cause: UploadError(UploadErrorKind.network, 'gone'),
        ),
        UploadSucceeded(
          'u1',
          const RemoteUploadResult(
            destinationId: 'fake',
            remoteFileId: 'r1',
            remoteName: 'a.mp4',
            bytesUploaded: 2048,
          ),
        ),
        const UploadFailed('u1', UploadError(UploadErrorKind.network, 'gone')),
        const UploadCancelled('u1'),
      ];

      for (final UploadEvent event in events) {
        expect(
          sessionEventForUpload(event),
          isNotNull,
          reason: '${event.runtimeType} must move the session',
        );
      }
    });

    test('progress carries the chunk counters through unchanged', () {
      final SessionEvent? mapped = sessionEventForUpload(
        const UploadProgress(
          'u1',
          bytesSent: 1024,
          totalBytes: 4096,
          chunkIndex: 2,
          chunkCount: 4,
        ),
      );

      expect(mapped, isA<UploadProgressed>());
      final UploadProgressed progress = mapped! as UploadProgressed;
      expect(progress.bytesSent, 1024);
      expect(progress.chunkIndex, 2);
      expect(progress.chunkCount, 4);
    });

    test('a failure keeps the confirmed byte count for a resume', () {
      final SessionEvent? mapped = sessionEventForUpload(
        const UploadFailed(
          'u1',
          UploadError(UploadErrorKind.network, 'gone'),
          bytesSent: 900,
        ),
      );

      expect((mapped! as UploadEnded).bytesConfirmed, 900);
    });

    test('the translation never deletes anything', () {
      // Deletion needs a stated reason and lives behind `RecordingStore`. A
      // pure mapping is what keeps that true by construction.
      final SessionEvent? mapped = sessionEventForUpload(
        UploadSucceeded(
          'u1',
          const RemoteUploadResult(
            destinationId: 'fake',
            remoteFileId: 'r1',
            remoteName: 'a.mp4',
            bytesUploaded: 2048,
          ),
        ),
      );
      expect(mapped, isA<UploadEnded>());
    });
  });
}

IncompleteRecordingArtifact _artifact(String id) => IncompleteRecordingArtifact(
  path: '/tmp/recording-$id.part',
  recordingId: id,
  sizeBytes: 4096,
  modifiedAt: DateTime.utc(2026, 8, 23, 10),
);
