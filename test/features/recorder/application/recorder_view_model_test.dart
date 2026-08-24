import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/settings/app_settings.dart';
import 'package:relay/features/recorder/application/recorder_view_model.dart';
import 'package:relay/features/recorder/domain/session_state.dart';
import 'package:upload_core/upload_core.dart';

import '../../../support/fakes.dart';
import '../../../support/harness.dart';

/// Writes a stand-in recording so the store's file operations are exercised
/// against a real file rather than a mock.
RecordingFile seedRecording(TestHarness harness, {int sizeBytes = 2048}) {
  final File file = File('${harness.directory.path}/recording-abc123.mp4')
    ..writeAsBytesSync(List<int>.filled(sizeBytes, 7));
  return FakeRecorder.sampleRecording(path: file.path, sizeBytes: sizeBytes);
}

void main() {
  group('initialization', () {
    test(
      'reads capabilities, the current display and the source list',
      () async {
        final TestHarness harness = await TestHarness.create();
        addTearDown(harness.dispose);
        await harness.initialize();

        expect(harness.viewModel.capabilities.isSupported, isTrue);
        expect(harness.viewModel.currentDisplay, isNotNull);
        expect(harness.viewModel.sources, isNotEmpty);
        expect(harness.recorder.calls, contains('getCapabilities'));
      },
    );

    test('preselects the display that holds the main window (§5)', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();

      expect(harness.viewModel.selectedSource?.type, CaptureSourceType.display);
      expect(harness.viewModel.selectedSource?.isCurrentDisplay, isTrue);
    });

    test(
      'a denied screen permission surfaces as the blocking preflight',
      () async {
        final TestHarness harness = await TestHarness.create(
          permissions: FakeRecorderPermissions(
            statuses: <PermissionKind, PermissionStatus>{
              PermissionKind.screenRecording: PermissionStatus.denied,
              PermissionKind.microphone: PermissionStatus.granted,
              PermissionKind.camera: PermissionStatus.granted,
            },
          ),
        );
        addTearDown(harness.dispose);
        await harness.initialize();

        expect(harness.viewModel.state, isA<SessionPreflight>());
        final SessionPreflight state =
            harness.viewModel.state as SessionPreflight;
        expect(state.canStart, isFalse);
        expect(state.blockingDenials, contains(PermissionKind.screenRecording));
      },
    );

    test(
      'an unfinished artefact is reported and never touched (§18)',
      () async {
        final Directory directory = Directory.systemTemp.createTempSync(
          'relay_recovery_',
        );
        final File part = File('${directory.path}/recording-8f2a11.part')
          ..writeAsBytesSync(List<int>.filled(4096, 3));
        final TestHarness harness = await TestHarness.create(
          directory: directory,
        );
        addTearDown(harness.dispose);
        await harness.initialize();

        expect(harness.viewModel.hasRecoverableArtifacts, isTrue);
        expect(harness.viewModel.pendingArtifacts.single.sizeBytes, 4096);
        expect(part.existsSync(), isTrue);

        harness.viewModel.keepArtifacts();
        expect(part.existsSync(), isTrue);
      },
    );
  });

  group('permission remedies (§23)', () {
    Future<TestHarness> harnessWith(PermissionStatus screenRecording) =>
        TestHarness.create(
          permissions: FakeRecorderPermissions(
            statuses: <PermissionKind, PermissionStatus>{
              PermissionKind.screenRecording: screenRecording,
              PermissionKind.microphone: PermissionStatus.granted,
              PermissionKind.camera: PermissionStatus.granted,
            },
          ),
        );

    test('the relaunch and the quit reach the platform', () async {
      final TestHarness harness = await harnessWith(
        PermissionStatus.pendingRelaunch,
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.relaunchApplication();
      await harness.viewModel.quitApplication();

      expect(harness.permissions.calls, contains('relaunchApplication'));
      expect(harness.permissions.calls, contains('quitApplication'));
    });

    test(
      'a platform that cannot reopen itself leaves the app running',
      () async {
        // The remedy failing must not take the application with it.
        final TestHarness harness = await harnessWith(
          PermissionStatus.pendingRelaunch,
        );
        addTearDown(harness.dispose);
        await harness.initialize();
        harness.permissions.failOnRelaunch = true;

        await harness.viewModel.relaunchApplication();

        expect(harness.viewModel.state, isA<SessionPreflight>());
        expect(harness.viewModel.isBusy, isFalse);
      },
    );

    test('a granted permission ends the blocking preflight with a real source', () async {
      final TestHarness harness = await harnessWith(PermissionStatus.denied);
      addTearDown(harness.dispose);
      await harness.initialize();
      expect(harness.viewModel.state, isA<SessionPreflight>());

      // The preflight carries a fabricated placeholder source while nothing can
      // be enumerated; leaving it in place would hand `prepare` an empty id.
      harness.permissions.statuses[PermissionKind.screenRecording] =
          PermissionStatus.granted;
      await harness.viewModel.requestPermission(PermissionKind.screenRecording);

      expect(harness.viewModel.state, isNot(isA<SessionPreflight>()));
      expect(harness.viewModel.selectedSource?.id, isNotEmpty);
    });

    test(
      'asking for an optional input does not abandon the preflight',
      () async {
        // The row buttons of the degraded preflight call the same method as the
        // blocking screen's primary. Leaving the preflight whenever screen
        // recording is usable would throw away the Start the user just pressed.
        final TestHarness harness = await TestHarness.create(
          settings: const AppSettings(cameraEnabled: true),
          permissions: FakeRecorderPermissions(
            statuses: <PermissionKind, PermissionStatus>{
              PermissionKind.screenRecording: PermissionStatus.granted,
              PermissionKind.microphone: PermissionStatus.granted,
              PermissionKind.camera: PermissionStatus.notDetermined,
            },
          ),
        );
        addTearDown(harness.dispose);
        await harness.initialize();
        await harness.viewModel.requestStart();
        expect(harness.viewModel.state, isA<SessionPreflight>());

        await harness.viewModel.requestPermission(PermissionKind.camera);

        expect(
          harness.viewModel.state,
          isA<SessionPreflight>(),
          reason:
              'the user is still one button from the recording they asked for',
        );
      },
    );

    test('Back leaves the preflight without starting anything', () async {
      final TestHarness harness = await TestHarness.create(
        settings: const AppSettings(cameraEnabled: true),
        permissions: FakeRecorderPermissions(
          statuses: <PermissionKind, PermissionStatus>{
            PermissionKind.screenRecording: PermissionStatus.granted,
            PermissionKind.microphone: PermissionStatus.granted,
            PermissionKind.camera: PermissionStatus.denied,
          },
        ),
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();
      expect(harness.viewModel.state, isA<SessionPreflight>());

      harness.viewModel.cancelPreflight();

      expect(harness.viewModel.state, isA<SessionIdle>());
      expect(harness.recorder.calls, isNot(contains('prepare')));
    });

    test('re-reading permissions reports itself as busy', () async {
      // The screen passes this to its button; without it the only feedback for
      // "Try again" was the screen not changing.
      final TestHarness harness = await harnessWith(PermissionStatus.denied);
      addTearDown(harness.dispose);
      await harness.initialize();

      final List<bool> observed = <bool>[];
      harness.viewModel.addListener(
        () => observed.add(harness.viewModel.isRefreshingPermissions),
      );
      await harness.viewModel.refreshPermissionsAndSources();

      expect(observed.first, isTrue);
      expect(harness.viewModel.isRefreshingPermissions, isFalse);
    });

    test(
      'a platform that cannot be asked is not reported as a first run',
      () async {
        final TestHarness harness = await TestHarness.create(
          permissions: FakeRecorderPermissions()..failOnCheck = true,
        );
        addTearDown(harness.dispose);
        await harness.initialize();

        expect(harness.viewModel.permissionCheckFailed, isTrue);
        expect(harness.viewModel.state, isA<SessionPreflight>());
      },
    );
  });

  group('starting a session', () {
    test('skips the preflight when nothing needs reporting', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.requestStart();

      expect(harness.viewModel.state, isA<SessionActive>());
      expect(
        harness.recorder.calls,
        containsAllInOrder(<String>['prepare', 'start']),
      );
    });

    test('configures the platform from the persisted settings', () async {
      final TestHarness harness = await TestHarness.create(
        settings: const AppSettings(
          quality: RecordingQuality.fullHd1080,
          frameRate: 60,
          cameraEnabled: false,
          microphoneEnabled: false,
          systemAudioEnabled: true,
        ),
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      final RecordingConfiguration configuration =
          harness.recorder.lastConfiguration!;
      expect(configuration.quality, RecordingQuality.fullHd1080);
      expect(configuration.frameRate, 60);
      expect(configuration.microphoneEnabled, isFalse);
      expect(configuration.systemAudioEnabled, isTrue);
      expect(configuration.showCursor, isTrue, reason: '§4.3');
      expect(configuration.outputDirectoryPath, harness.directory.path);
      expect(configuration.recordingId, isNotEmpty);
    });

    test('shows the strip, hides the panel, and restores it on stop', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.requestStart();
      // The strip is up before the panel goes away: if creating it failed, the
      // panel must still be on screen.
      expect(
        harness.overlays.calls,
        containsAllInOrder(<String>[
          'showControlStrip',
          'setMainWindowVisible(false)',
        ]),
      );

      harness.recorder.stopResult = seedRecording(harness);
      await harness.viewModel.stop();
      expect(
        harness.overlays.calls,
        containsAllInOrder(<String>[
          'hideCameraPreview',
          'hideControlStrip',
          'setMainWindowVisible(true)',
        ]),
      );
    });

    test('a failure while starting always brings the panel back', () async {
      // Anything that is not a RecorderException used to escape the catch and
      // leave the window hidden with no way to restore it — indistinguishable
      // from a crash.
      final FakeRecorder recorder = FakeRecorder()
        ..failOnStart = StateError('the platform misbehaved');
      final TestHarness harness = await TestHarness.create(recorder: recorder);
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.requestStart();

      expect(harness.viewModel.state, isA<SessionFailed>());
      expect(harness.overlays.calls.last, 'setMainWindowVisible(true)');
      expect(harness.recorder.calls, contains('abort'));
    });

    test('a start that never returns is not a hung window', () async {
      final FakeRecorder recorder = FakeRecorder()..hangOnStart = true;
      final TestHarness harness = await TestHarness.create(recorder: recorder);
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.requestStart();

      expect(harness.viewModel.state, isA<SessionFailed>());
      expect(harness.overlays.calls, contains('setMainWindowVisible(true)'));
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a failed prepare tears the overlays back down', () async {
      final FakeRecorder recorder = FakeRecorder()
        ..failOnPrepare = const RecorderException(
          RecorderErrorCode.sourceUnavailable,
          'gone',
        );
      final TestHarness harness = await TestHarness.create(recorder: recorder);
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.requestStart();

      expect(harness.viewModel.state, isA<SessionFailed>());
      expect(harness.overlays.calls, contains('setMainWindowVisible(true)'));
      expect(harness.recorder.calls, isNot(contains('start')));
    });

    test('the camera preview opens only when the camera is on', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();
      expect(harness.overlays.calls, isNot(contains('showCameraPreview')));

      await harness.viewModel.toggleCamera();
      expect(harness.overlays.calls, contains('showCameraPreview'));
      expect(harness.recorder.calls, contains('setCameraEnabled(true)'));
    });

    test(
      'the display-mode preview sits where the compositor draws the PiP',
      () async {
        final TestHarness harness = await TestHarness.create();
        addTearDown(harness.dispose);
        await harness.initialize();
        await harness.viewModel.requestStart();
        await harness.viewModel.toggleCamera();

        final OverlayPlacement placement =
            harness.overlays.cameraPlacements.single;
        // 1512 x 982 display, 0.16 width ratio, 0.01 margin (§7).
        expect(placement.frame, isNotNull);
        expect(placement.frame!.width, closeTo(1512 * 0.16, 0.01));
        expect(
          placement.frame!.width / placement.frame!.height,
          closeTo(16 / 9, 0.01),
          reason: 'the fallback shape until the host knows the camera',
        );
        expect(
          placement.frame!.right,
          closeTo(1512 - 1512 * 0.01, 0.01),
          reason: 'lower-right corner',
        );
        expect(placement.frame!.bottom, closeTo(982 - 1512 * 0.01, 0.01));
        // The host re-resolves the tile against the camera's real shape, so the
        // configuration has to travel with the placement (design `1p`).
        expect(
          harness.overlays.cameraOverlays.single,
          const CameraOverlayConfiguration(),
        );
      },
    );
  });

  group('runtime toggles (§8)', () {
    test('the strip snapshot follows every toggle', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      await harness.viewModel.toggleMicrophone();
      await harness.viewModel.toggleSystemAudio();

      final RecordingOverlayState pushed = harness.overlays.pushed.last;
      expect(pushed.microphoneEnabled, isFalse);
      expect(pushed.systemAudioEnabled, isFalse);
      expect(harness.recorder.calls, contains('setMicrophoneEnabled(false)'));
      expect(harness.recorder.calls, contains('setSystemAudioEnabled(false)'));
    });

    test('a strip command is routed to the session', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      harness.overlays.commandController.add(OverlayCommand.pauseOrResume);
      await pumpEventQueue();
      expect((harness.viewModel.state as SessionActive).isPaused, isTrue);

      harness.overlays.commandController.add(OverlayCommand.pauseOrResume);
      await pumpEventQueue();
      expect((harness.viewModel.state as SessionActive).isPaused, isFalse);
    });

    test('a second click while a pause is in flight is dropped', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      // A platform round trip is long enough to click through twice. The
      // second click used to read the state the first had not finished
      // changing and ask the platform to pause an already-paused session.
      harness.recorder.holdPause = Completer<void>();
      final Future<void> first = harness.viewModel.pauseOrResume();
      await pumpEventQueue();
      await harness.viewModel.pauseOrResume();
      harness.recorder.holdPause!.complete();
      await first;

      expect(
        harness.recorder.calls.where((String c) => c == 'pause'),
        hasLength(1),
      );
      expect((harness.viewModel.state as SessionActive).isPaused, isTrue);
    });

    test('a slow toggle does not disable the rest of the strip', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      // One latch used to guard all four controls, so a microphone toggle the
      // platform had not answered yet also swallowed Pause and Stop's
      // siblings. The strip floats over someone else's work: a control that
      // stops answering because another one is busy is indistinguishable from
      // a broken application.
      harness.recorder.holdMicrophone = Completer<void>();
      final Future<void> microphone = harness.viewModel.toggleMicrophone();
      await pumpEventQueue();

      await harness.viewModel.pauseOrResume();
      expect(
        (harness.viewModel.state as SessionActive).isPaused,
        isTrue,
        reason: 'Pause must not wait behind an unrelated control',
      );

      await harness.viewModel.toggleSystemAudio();
      expect(
        harness.recorder.calls,
        contains('setSystemAudioEnabled(false)'),
        reason: 'nor must any other input',
      );

      harness.recorder.holdMicrophone!.complete();
      await microphone;
    });

    test('a second click on the same control is still dropped', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      // The reason the latch exists at all: both clicks read the state before
      // either wrote it, and the second asks for a change that has already
      // been made.
      harness.recorder.holdMicrophone = Completer<void>();
      final Future<void> first = harness.viewModel.toggleMicrophone();
      await pumpEventQueue();
      await harness.viewModel.toggleMicrophone();
      harness.recorder.holdMicrophone!.complete();
      await first;

      expect(
        harness.recorder.calls.where(
          (String c) => c.startsWith('setMicrophoneEnabled'),
        ),
        hasLength(1),
      );
    });

    testWidgets('a platform call that never answers frees its control again', (
      WidgetTester tester,
    ) async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      // These four were the only platform calls in the view model without a
      // deadline. A call that never came back held the control's latch for the
      // rest of the recording, and nothing in the log said why.
      harness.recorder.holdMicrophone = Completer<void>();
      final Future<void> stuck = harness.viewModel.toggleMicrophone();
      await tester.pump(
        RecorderViewModel.platformCallTimeout + const Duration(seconds: 1),
      );
      await stuck;

      expect(
        (harness.viewModel.state as SessionActive).microphoneEnabled,
        isTrue,
        reason: 'a call that never answered changed nothing',
      );
      expect(
        harness.viewModel.state,
        isA<SessionActive>(),
        reason: 'and it must not have ended a healthy recording',
      );

      // The control answers the next click, which is the whole point.
      harness.recorder.holdMicrophone = null;
      await harness.viewModel.toggleMicrophone();
      expect(
        (harness.viewModel.state as SessionActive).microphoneEnabled,
        isFalse,
      );
    });

    test('an input the platform refuses is left exactly as it was', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      // Guessing that the input is gone would mute a microphone that still
      // works. Only the platform's own non-fatal error event degrades a
      // session, and that path is tested separately.
      harness.recorder.failOnMicrophoneToggle = const RecorderException(
        RecorderErrorCode.microphoneUnavailable,
        'device busy',
      );
      await harness.viewModel.toggleMicrophone();

      final SessionActive state = harness.viewModel.state as SessionActive;
      expect(state.phase, SessionPhase.recording);
      expect(state.microphoneEnabled, isTrue);
      expect(state.microphoneAvailable, isTrue);
      expect(
        harness.overlays.pushed.last.microphoneEnabled,
        isTrue,
        reason:
            'the snapshot the strip holds must still say the microphone is on',
      );
    });

    test('a refused pause loses the click, not the recording', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      // The platform reports it is not in a state to pause — it is already
      // paused, or already stopping. That is a lost click.
      harness.recorder.failOnPause = const RecorderException(
        RecorderErrorCode.invalidState,
        'The session is not recording.',
      );
      await harness.viewModel.pauseOrResume();

      expect(
        harness.viewModel.state,
        isA<SessionActive>(),
        reason: 'a healthy session must survive a refused pause',
      );
      expect(harness.overlays.pushed, isNotEmpty);
    });

    test('a lost input degrades the session without ending it', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      harness.recorder.emit(
        const RecorderErrorEvent(
          RecorderErrorCode.systemAudioUnavailable,
          'device removed',
          fatal: false,
        ),
      );
      await pumpEventQueue();

      final SessionActive state = harness.viewModel.state as SessionActive;
      expect(state.phase, SessionPhase.recording);
      expect(state.systemAudioAvailable, isFalse);
    });

    test(
      'a fatal capture error ends the session and restores the panel',
      () async {
        final TestHarness harness = await TestHarness.create();
        addTearDown(harness.dispose);
        await harness.initialize();
        await harness.viewModel.requestStart();

        harness.recorder.emit(
          const RecorderErrorEvent(RecorderErrorCode.diskFull, 'full'),
        );
        await pumpEventQueue();

        expect(harness.viewModel.state, isA<SessionFailed>());
        expect(harness.overlays.calls, contains('setMainWindowVisible(true)'));
      },
    );

    test('a fatal capture error releases the platform session', () async {
      // Without this the session stays live on the other side of the channel:
      // the capture keeps running, the camera light stays on and the power
      // assertion is held for the rest of the process. The application used to
      // hide its overlays and consider the matter closed.
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();
      harness.recorder.calls.clear();

      harness.recorder.emit(
        const RecorderErrorEvent(RecorderErrorCode.diskFull, 'full'),
      );
      await pumpEventQueue();

      expect(harness.recorder.calls, contains('abort'));
    });

    test('a non-fatal error leaves the platform session alone', () async {
      // The mirror of the rule above: a microphone that went away degrades the
      // session, it does not end a recording that is still writing frames.
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();
      harness.recorder.calls.clear();

      harness.recorder.emit(
        const RecorderErrorEvent(
          RecorderErrorCode.microphoneUnavailable,
          'gone',
          fatal: false,
        ),
      );
      await pumpEventQueue();

      expect(harness.recorder.calls, isNot(contains('abort')));
      expect(harness.viewModel.state, isA<SessionActive>());
    });
  });

  group('capability negotiation (§28)', () {
    /// A platform that reports an input it does not have.
    FakeRecorder recorderWithout({
      bool camera = true,
      bool microphone = true,
      bool systemAudio = true,
    }) {
      final FakeRecorder recorder = FakeRecorder();
      recorder.capabilities = RecorderCapabilities(
        qualities: recorder.capabilities.qualities,
        supportedFrameRates: recorder.capabilities.supportedFrameRates,
        supportedSourceTypes: recorder.capabilities.supportedSourceTypes,
        supportsCamera: camera,
        supportsMicrophone: microphone,
        supportsSystemAudio: systemAudio,
        supportsPause: true,
        supportsCursorCapture: true,
        supportsHardwareEncoding: true,
        platformName: 'fake',
      );
      return recorder;
    }

    test('an input the platform does not have is never prepared', () async {
      // The permission is granted and the setting is on; the hardware is the
      // thing that is missing. Preparing with `cameraEnabled: true` here asks
      // a platform that said "no such device" to open one.
      final TestHarness harness = await TestHarness.create(
        recorder: recorderWithout(camera: false),
        settings: const AppSettings(cameraEnabled: true),
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.requestStart();

      expect(harness.recorder.lastConfiguration!.cameraEnabled, isFalse);
    });

    test('the strip is told the control is unavailable, not merely off', () async {
      // `SessionActive` used to default all three to available because nothing
      // ever passed anything else, so the overlay drew a live camera button
      // whose only possible outcome was a mid-session error.
      final TestHarness harness = await TestHarness.create(
        recorder: recorderWithout(camera: false),
        settings: const AppSettings(cameraEnabled: true),
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.requestStart();

      final SessionActive state = harness.viewModel.state as SessionActive;
      expect(state.cameraAvailable, isFalse);
      expect(state.microphoneAvailable, isTrue);
      expect(state.systemAudioAvailable, isTrue);
    });

    test('system audio the platform cannot mix is dropped too', () async {
      final TestHarness harness = await TestHarness.create(
        recorder: recorderWithout(systemAudio: false),
        settings: const AppSettings(),
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.requestStart();

      expect(harness.recorder.lastConfiguration!.systemAudioEnabled, isFalse);
      expect(
        (harness.viewModel.state as SessionActive).systemAudioAvailable,
        isFalse,
      );
    });

    test(
      'a fully capable platform keeps every input the user asked for',
      () async {
        final TestHarness harness = await TestHarness.create(
          settings: const AppSettings(cameraEnabled: true),
        );
        addTearDown(harness.dispose);
        await harness.initialize();

        await harness.viewModel.requestStart();

        final RecordingConfiguration configuration =
            harness.recorder.lastConfiguration!;
        expect(configuration.cameraEnabled, isTrue);
        expect(configuration.microphoneEnabled, isTrue);
        expect(configuration.systemAudioEnabled, isTrue);
      },
    );

    test(
      'a missing input degrades the session rather than blocking it',
      () async {
        // CLAUDE.md and the ADR both say optional inputs degrade. The session
        // must still start.
        final TestHarness harness = await TestHarness.create(
          recorder: recorderWithout(camera: false, microphone: false),
          settings: const AppSettings(cameraEnabled: true),
        );
        addTearDown(harness.dispose);
        await harness.initialize();

        await harness.viewModel.requestStart();

        expect(harness.viewModel.state, isA<SessionActive>());
        expect(harness.recorder.calls, contains('start'));
      },
    );
  });

  group('disposal', () {
    test('disposing the view model disposes the platform recorder', () async {
      // `Recorder.dispose` had no caller anywhere in lib/ or test/. The one
      // route that releases a session the application no longer owns was dead
      // code, which is why a quit mid-recording left the capture running.
      final TestHarness harness = await TestHarness.create();
      await harness.initialize();

      harness.viewModel.dispose();
      await pumpEventQueue();

      expect(harness.recorder.calls, contains('dispose'));
    });

    test('a platform that refuses to be disposed does not throw', () async {
      // Disposal runs while the application is going away. There is nowhere to
      // report to, and an exception here would be an unhandled one.
      final FakeRecorder recorder = FakeRecorder()..failOnDispose = true;
      final TestHarness harness = await TestHarness.create(recorder: recorder);
      await harness.initialize();

      expect(harness.viewModel.dispose, returnsNormally);
      await pumpEventQueue();
    });
  });

  group('post-recording file lifecycle (§18)', () {
    Future<TestHarness> readyHarness({
      List<UploadDestination>? destinations,
      int sizeBytes = 2048,
    }) async {
      final TestHarness harness = await TestHarness.create(
        destinations: destinations,
      );
      await harness.initialize();
      await harness.viewModel.requestStart();
      harness.recorder.stopResult = seedRecording(
        harness,
        sizeBytes: sizeBytes,
      );
      await harness.viewModel.stop();
      return harness;
    }

    test('stop finalizes and renames onto the user-facing name', () async {
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);

      final SessionReady ready = harness.viewModel.state as SessionReady;
      expect(ready.name, 'recording-2026-08-22-1422');
      expect(File(ready.recording.path).existsSync(), isTrue);
      expect(ready.recording.path, endsWith('recording-2026-08-22-1422.mp4'));
    });

    test('renaming moves the file and never re-finalizes it', () async {
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);
      final String before =
          (harness.viewModel.state as SessionReady).recording.path;

      await harness.viewModel.renameRecording('demo clip');

      final SessionReady ready = harness.viewModel.state as SessionReady;
      expect(ready.name, 'demo clip');
      expect(File(ready.recording.path).existsSync(), isTrue);
      expect(File(before).existsSync(), isFalse);
      expect(harness.recorder.stopCount, 1);
    });

    test('an unusable name is refused rather than written', () async {
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);
      final SessionReady before = harness.viewModel.state as SessionReady;

      await harness.viewModel.renameRecording('   ///   ');

      expect((harness.viewModel.state as SessionReady).name, before.name);
      expect(File(before.recording.path).existsSync(), isTrue);
    });

    test('explicit Delete removes the file and returns to idle', () async {
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);
      final String path =
          (harness.viewModel.state as SessionReady).recording.path;

      await harness.viewModel.deleteRecording();

      expect(File(path).existsSync(), isFalse);
      expect(harness.viewModel.state, isA<SessionIdle>());
    });

    test('Delete is idempotent', () async {
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);
      await harness.viewModel.deleteRecording();
      await harness.viewModel.deleteRecording();
      expect(harness.viewModel.state, isA<SessionIdle>());
    });

    test('a confirmed upload deletes the local file', () async {
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);
      final String path =
          (harness.viewModel.state as SessionReady).recording.path;

      await harness.viewModel.send();
      await pumpEventQueue();

      expect(File(path).existsSync(), isFalse);
      expect(harness.viewModel.state, isA<SessionIdle>());
    });

    test('a failed upload preserves the local file (§13)', () async {
      final FakeUploadDestination failing =
          FakeUploadDestination(id: 'telegram', displayName: 'Telegram')
            ..script = (String uploadId, UploadFile file) => <UploadEvent>[
              UploadStarted(uploadId, totalBytes: file.sizeBytes),
              UploadProgress(
                uploadId,
                bytesSent: file.sizeBytes ~/ 2,
                totalBytes: file.sizeBytes,
              ),
              UploadFailed(
                uploadId,
                const UploadError.network('the network dropped'),
                bytesSent: file.sizeBytes ~/ 2,
              ),
            ];
      final TestHarness harness = await readyHarness(
        destinations: <UploadDestination>[failing],
      );
      addTearDown(harness.dispose);
      final String path =
          (harness.viewModel.state as SessionReady).recording.path;

      await harness.viewModel.send();
      await pumpEventQueue();

      expect(harness.viewModel.state, isA<SessionUploadFailed>());
      expect(File(path).existsSync(), isTrue);
      final SessionUploadFailed failed =
          harness.viewModel.state as SessionUploadFailed;
      expect(failed.error.kind, UploadErrorKind.network);
      expect(failed.bytesConfirmed, greaterThan(0));
    });

    test(
      'a rejected pre-flight never starts a transfer and keeps the file',
      () async {
        final FakeUploadDestination tooSmall =
            FakeUploadDestination(id: 'telegram', displayName: 'Telegram')
              ..validation = const UploadValidationResult.rejected(
                UploadError.fileTooLarge('50 MB limit, file is 1.02 GB'),
              );
        final TestHarness harness = await readyHarness(
          destinations: <UploadDestination>[tooSmall],
        );
        addTearDown(harness.dispose);
        final String path =
            (harness.viewModel.state as SessionReady).recording.path;

        await harness.viewModel.send();
        await pumpEventQueue();

        expect(tooSmall.calls, isNot(contains('upload')));
        expect(File(path).existsSync(), isTrue);
        expect(harness.viewModel.state, isA<SessionUploadFailed>());
      },
    );

    test('"keep the file and decide later" returns to ready', () async {
      final FakeUploadDestination failing =
          FakeUploadDestination(id: 'telegram')
            ..script = (String uploadId, UploadFile file) => <UploadEvent>[
              UploadStarted(uploadId, totalBytes: file.sizeBytes),
              UploadFailed(uploadId, const UploadError.network('dropped')),
            ];
      final TestHarness harness = await readyHarness(
        destinations: <UploadDestination>[failing],
      );
      addTearDown(harness.dispose);

      await harness.viewModel.send();
      await pumpEventQueue();
      harness.viewModel.keepRecordingForLater();

      expect(harness.viewModel.state, isA<SessionReady>());
      expect(
        File((harness.viewModel.state as SessionReady).recording.path)
            .existsSync(),
        isTrue,
      );
    });

    test('starting a new recording releases the finished session', () async {
      // Leaving the post-recording screen used to be a pure state transition,
      // so the platform kept the finished session — and everything it had
      // built — until the process exited. A recorder the user has walked away
      // from must not still own a camera, a microphone or a capture.
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);

      harness.viewModel.startNewSession();
      await pumpEventQueue();

      expect(harness.recorder.calls, contains('releaseSession'));
      expect(harness.viewModel.state, isA<SessionIdle>());
    });

    test('keeping the recording for later releases the session too', () async {
      // The file stays on disk and the screen stays on `ready`, but the capture
      // that produced it is just as finished as it is after New recording.
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);
      final String path =
          (harness.viewModel.state as SessionReady).recording.path;

      harness.viewModel.keepRecordingForLater();
      await pumpEventQueue();

      expect(harness.recorder.calls, contains('releaseSession'));
      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'releasing the session must never touch the recording (§18)',
      );
    });

    test('Delete releases the session as well as the file', () async {
      // Send and Delete are the other two exits from the post-recording screen.
      // Releasing on only "New recording" left the platform holding the
      // finished session on the two commonest paths out.
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);

      await harness.viewModel.deleteRecording();
      await pumpEventQueue();

      expect(harness.recorder.calls, contains('releaseSession'));
      expect(harness.viewModel.state, isA<SessionIdle>());
    });

    test('a platform that refuses to release does not block the user', () async {
      // The release is best effort. A platform that cannot answer must not trap
      // the user on the post-recording screen.
      final TestHarness harness = await readyHarness();
      addTearDown(harness.dispose);
      harness.recorder.failOnReleaseSession = true;

      harness.viewModel.startNewSession();
      await pumpEventQueue();

      expect(harness.viewModel.state, isA<SessionIdle>());
    });
  });

  group('source discovery', () {
    test('every request reaches the platform, not just the first', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.viewModel.initialize();

      final int afterInit = harness.recorder.calls
          .where((String c) => c.startsWith('getAvailableSources'))
          .length;
      expect(afterInit, 1);

      // A one-shot source list is the whole bug: the picker would keep showing
      // the launch-time snapshot with no thumbnails, windows opened since
      // would be missing, and their stale ids fail `prepare`.
      await harness.viewModel.openSourcePicker();
      await harness.viewModel.refreshSources();

      expect(
        harness.recorder.calls
            .where((String c) => c.startsWith('getAvailableSources'))
            .length,
        afterInit + 2,
      );
      expect(
        harness.recorder.calls,
        contains('getAvailableSources(true)'),
        reason: 'the picker asks for thumbnails',
      );
    });

    test(
      'the picker stops reporting "loading" once the list arrives',
      () async {
        final TestHarness harness = await TestHarness.create();
        addTearDown(harness.dispose);
        await harness.viewModel.initialize();

        await harness.viewModel.openSourcePicker();

        final SessionState state = harness.viewModel.state;
        expect(state, isA<SessionSelectingSource>());
        expect((state as SessionSelectingSource).loading, isFalse);
        expect(harness.viewModel.isDiscoveringSources, isFalse);
      },
    );
  });

  group('startup recovery (§18)', () {
    test('an unrecoverable artefact is left on disk', () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'relay_recover_none_',
      );
      final File part = File('${directory.path}/recording-8f2a11.part')
        ..writeAsBytesSync(List<int>.filled(4096, 3));
      final TestHarness harness = await TestHarness.create(
        directory: directory,
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      harness.recorder.recoverResult = null;
      await harness.viewModel.recoverArtifact(
        harness.viewModel.pendingArtifacts.single,
      );

      expect(part.existsSync(), isTrue);
      expect(harness.viewModel.state, isA<SessionIdle>());
    });

    test('a recovered artefact becomes a ready recording', () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'relay_recover_ok_',
      );
      File('${directory.path}/recording-8f2a11.part')
          .writeAsBytesSync(List<int>.filled(4096, 3));
      final TestHarness harness = await TestHarness.create(
        directory: directory,
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      final File recovered = File('${directory.path}/recording-8f2a11.mp4')
        ..writeAsBytesSync(List<int>.filled(4096, 3));
      harness.recorder.recoverResult = FakeRecorder.sampleRecording(
        path: recovered.path,
        sizeBytes: 4096,
      );
      await harness.viewModel.recoverArtifact(
        harness.viewModel.pendingArtifacts.single,
      );

      expect(harness.viewModel.state, isA<SessionReady>());
    });

    test('discard removes only the artefact the user chose', () async {
      final Directory directory = Directory.systemTemp.createTempSync(
        'relay_discard_',
      );
      final File part = File('${directory.path}/recording-8f2a11.part')
        ..writeAsBytesSync(List<int>.filled(4096, 3));
      final File keeper = File('${directory.path}/recording-other.mp4')
        ..writeAsBytesSync(List<int>.filled(16, 1));
      final TestHarness harness = await TestHarness.create(
        directory: directory,
      );
      addTearDown(harness.dispose);
      await harness.initialize();

      await harness.viewModel.discardArtifact(
        harness.viewModel.pendingArtifacts.single,
      );

      expect(part.existsSync(), isFalse);
      expect(keeper.existsSync(), isTrue);
      expect(harness.viewModel.hasRecoverableArtifacts, isFalse);
    });
  });
}
