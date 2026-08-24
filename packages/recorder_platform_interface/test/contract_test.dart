import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

/// The Flutter half of `docs/architecture/platform-channel-contract.md`.
///
/// Every supported platform speaks this shape, so a change that breaks it here
/// breaks macOS and Windows at once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('capability decoding', () {
    test('a full payload becomes typed capabilities', () {
      final RecorderCapabilities capabilities = RecorderCapabilities.fromMap(
        <String, Object?>{
          'qualities': <Object?>['hd720', 'fullHd1080'],
          'frameRates': <Object?>[30, 60],
          'sourceTypes': <Object?>['display', 'window'],
          'supportsCamera': true,
          'supportsMicrophone': true,
          'supportsSystemAudio': true,
          'supportsPause': true,
          'supportsCursorCapture': true,
          'supportsHardwareEncoding': true,
          'platformName': 'macOS',
          'platformVersion': '26.5.2',
        },
      );
      expect(capabilities.isSupported, isTrue);
      expect(capabilities.sortedFrameRates, <int>[30, 60]);
      expect(capabilities.sortedQualities, <RecordingQuality>[
        RecordingQuality.hd720,
        RecordingQuality.fullHd1080,
      ]);
      expect(capabilities.supportedSourceTypes, <CaptureSourceType>{
        CaptureSourceType.display,
        CaptureSourceType.window,
      });
    });

    test('an unsupportedReason disables recording entirely', () {
      final RecorderCapabilities capabilities = RecorderCapabilities.fromMap(
        <String, Object?>{'unsupportedReason': 'no implementation'},
      );
      expect(capabilities.isSupported, isFalse);
      expect(capabilities.supportedFrameRates, isEmpty);
    });

    test('a future frame rate arrives as data, not as a new flag', () {
      // 120 FPS is a §10 future capability: it must need no code change here.
      final RecorderCapabilities capabilities = RecorderCapabilities.fromMap(
        <String, Object?>{
          'frameRates': <Object?>[30, 60, 120],
        },
      );
      expect(capabilities.sortedFrameRates, <int>[30, 60, 120]);
    });

    test('a platform that says nothing about relaunching needs none', () {
      // The conservative default matters: a payload without these keys is an
      // older or non-macOS platform, and offering to quit and reopen there
      // would be an action with no effect on a permission it cannot change.
      final RecorderCapabilities capabilities = RecorderCapabilities.fromMap(
        <String, Object?>{'platformName': 'Windows'},
      );
      expect(capabilities.screenRecordingNeedsRelaunch, isFalse);
      expect(capabilities.screenRecordingLaunchedByThisApp, isTrue);
      expect(
        const RecorderCapabilities.unsupported('none')
            .screenRecordingLaunchedByThisApp,
        isTrue,
      );
    });

    test('a platform that applies permissions on relaunch says so', () {
      final RecorderCapabilities capabilities = RecorderCapabilities.fromMap(
        <String, Object?>{
          'screenRecordingNeedsRelaunch': true,
          'screenRecordingLaunchedByThisApp': false,
        },
      );
      expect(capabilities.screenRecordingNeedsRelaunch, isTrue);
      expect(capabilities.screenRecordingLaunchedByThisApp, isFalse);
    });

    test('an unknown source type degrades instead of throwing', () {
      final RecorderCapabilities capabilities = RecorderCapabilities.fromMap(
        <String, Object?>{
          'sourceTypes': <Object?>['display', 'hologram'],
        },
      );
      expect(
        capabilities.supportedSourceTypes,
        contains(CaptureSourceType.display),
      );
    });
  });

  group('event decoding', () {
    test('every documented event type maps to its class', () {
      expect(
        RecorderEvent.fromMap(<String, Object?>{
          'type': 'state',
          'state': 'recording',
        }),
        isA<RecorderStateEvent>().having(
          (RecorderStateEvent e) => e.state,
          'state',
          PlatformRecorderState.recording,
        ),
      );
      expect(
        RecorderEvent.fromMap(<String, Object?>{
          'type': 'tick',
          'elapsedMs': 872000,
        }),
        isA<RecorderTickEvent>().having(
          (RecorderTickEvent e) => e.elapsed,
          'elapsed',
          const Duration(milliseconds: 872000),
        ),
      );
      expect(
        RecorderEvent.fromMap(<String, Object?>{
          'type': 'inputChanged',
          'microphoneEnabled': true,
          'cameraEnabled': false,
          'systemAudioEnabled': true,
        }),
        isA<RecorderInputChangedEvent>(),
      );
      expect(
        RecorderEvent.fromMap(<String, Object?>{
          'type': 'stats',
          'droppedFrames': 6,
          'encoderName': 'VideoToolbox H.264',
          'hardwareEncoding': true,
        }),
        isA<RecorderStatsEvent>().having(
          (RecorderStatsEvent e) => e.droppedFrames,
          'droppedFrames',
          6,
        ),
      );
    });

    test('fatal and non-fatal errors are distinguished', () {
      final RecorderEvent degraded = RecorderEvent.fromMap(<String, Object?>{
        'type': 'error',
        'code': 'systemAudioUnavailable',
        'message': 'device removed',
        'fatal': false,
      });
      expect(
        degraded,
        isA<RecorderErrorEvent>()
            .having((RecorderErrorEvent e) => e.fatal, 'fatal', isFalse)
            .having(
              (RecorderErrorEvent e) => e.code,
              'code',
              RecorderErrorCode.systemAudioUnavailable,
            ),
      );
      expect(
        RecorderEvent.fromMap(<String, Object?>{
          'type': 'error',
          'code': 'diskFull',
          'message': 'full',
        }),
        isA<RecorderErrorEvent>().having(
          (RecorderErrorEvent e) => e.fatal,
          'fatal',
          isTrue,
        ),
      );
    });

    test('an unrecognized event becomes an error rather than throwing', () {
      expect(
        RecorderEvent.fromMap(<String, Object?>{'type': 'teleport'}),
        isA<RecorderErrorEvent>().having(
          (RecorderErrorEvent e) => e.code,
          'code',
          RecorderErrorCode.unknown,
        ),
      );
    });

    test('optional-input codes are recoverable, video codes are not', () {
      for (final RecorderErrorCode code in <RecorderErrorCode>[
        RecorderErrorCode.microphoneUnavailable,
        RecorderErrorCode.cameraUnavailable,
        RecorderErrorCode.systemAudioUnavailable,
      ]) {
        expect(code.isRecoverableDuringSession, isTrue, reason: code.name);
      }
      for (final RecorderErrorCode code in <RecorderErrorCode>[
        RecorderErrorCode.captureFailed,
        RecorderErrorCode.encodingFailed,
        RecorderErrorCode.diskFull,
        RecorderErrorCode.finalizationFailed,
        RecorderErrorCode.sourceClosed,
      ]) {
        expect(code.isRecoverableDuringSession, isFalse, reason: code.name);
      }
    });
  });

  group('permissions (§23)', () {
    const PermissionReport denied = PermissionReport(
      <PermissionKind, PermissionStatus>{
        PermissionKind.screenRecording: PermissionStatus.granted,
        PermissionKind.microphone: PermissionStatus.denied,
        PermissionKind.camera: PermissionStatus.notDetermined,
      },
    );

    test('an answer awaiting a relaunch blocks, but is not a refusal', () {
      // macOS applies a screen-recording grant to the launched binary, so the
      // process that asked cannot observe it. Reporting that as `denied` is
      // what told a user who had just pressed Allow that they had refused.
      const PermissionReport pending = PermissionReport(
        <PermissionKind, PermissionStatus>{
          PermissionKind.screenRecording: PermissionStatus.pendingRelaunch,
        },
      );
      expect(PermissionStatus.pendingRelaunch.isUsable, isFalse);
      expect(PermissionStatus.pendingRelaunch.needsRelaunch, isTrue);
      expect(PermissionStatus.denied.needsRelaunch, isFalse);
      expect(pending.canRecordScreen, isFalse);
      expect(pending.blockingDenials(), <PermissionKind>{
        PermissionKind.screenRecording,
      });
      expect(
        PermissionStatus.fromName('pendingRelaunch'),
        PermissionStatus.pendingRelaunch,
      );
    });

    test('only screen recording blocks', () {
      expect(
        denied.blockingDenials(
          microphoneRequested: true,
          cameraRequested: true,
        ),
        isEmpty,
      );
      const PermissionReport noScreen = PermissionReport(
        <PermissionKind, PermissionStatus>{
          PermissionKind.screenRecording: PermissionStatus.denied,
        },
      );
      expect(noScreen.blockingDenials(), <PermissionKind>{
        PermissionKind.screenRecording,
      });
    });

    test('a requested-but-refused input is reported as degraded', () {
      expect(
        denied.degradedInputs(microphoneRequested: true, cameraRequested: true),
        <PermissionKind>{PermissionKind.microphone, PermissionKind.camera},
      );
    });

    test('an input that is off is never degraded', () {
      expect(
        denied.degradedInputs(
          microphoneRequested: false,
          cameraRequested: false,
        ),
        isEmpty,
      );
    });

    test(
      'notApplicable counts as usable, for a platform without the concept',
      () {
        const PermissionReport windowsLike = PermissionReport(
          <PermissionKind, PermissionStatus>{
            PermissionKind.screenRecording: PermissionStatus.notApplicable,
          },
        );
        expect(windowsLike.canRecordScreen, isTrue);
      },
    );
  });

  group('configuration encoding', () {
    const CaptureSource source = CaptureSource(
      id: 'display:1',
      type: CaptureSourceType.display,
      title: 'Built-in Display',
      subtitle: '2560 × 1600',
      pixelWidth: 2560,
      pixelHeight: 1600,
      isCurrentDisplay: true,
    );

    test('the payload matches the documented shape', () {
      final Map<String, Object?> map = const RecordingConfiguration(
        source: source,
        recordingId: '8f2a11',
        outputDirectoryPath: '/tmp/relay',
        quality: RecordingQuality.fullHd1080,
        frameRate: 60,
      ).toMap();

      expect(map['sourceId'], 'display:1');
      expect(map['sourceType'], 'display');
      expect(map['recordingId'], '8f2a11');
      expect(map['targetHeight'], 1080);
      expect(map['frameRate'], 60);
      expect(map['showCursor'], isTrue);
      expect(map['microphoneEnabled'], isTrue);
      expect(map['systemAudioEnabled'], isTrue);
      expect(map['cameraEnabled'], isFalse);
      final Map<String, Object?> overlay =
          map['cameraOverlay']! as Map<String, Object?>;
      expect(overlay['widthRatio'], 0.16);
      expect(overlay['followsSourceAspectRatio'], isTrue);
      expect(
        (map['composition']! as Map<String, Object?>)['aspectRatioPolicy'],
        'containWithinPreset',
      );
    });

    test('a recording file round-trips from the documented payload', () {
      final RecordingFile file = RecordingFile.fromMap(<String, Object?>{
        'path': '/tmp/relay/recording-8f2a11.mp4',
        'recordingId': '8f2a11',
        'sizeBytes': 1094813696,
        'durationMs': 872000,
        'createdAtMs': 1755900000000,
        'width': 1920,
        'height': 1080,
        'frameRate': 60,
        'hasAudio': true,
        'hasCamera': false,
      });
      expect(file.duration, const Duration(milliseconds: 872000));
      expect(file.sizeBytes, 1094813696);
      expect(file.height, 1080);
    });
  });

  group('MethodChannelRecorder', () {
    const MethodChannel channel = MethodChannel('relay/recorder');
    final List<MethodCall> calls = <MethodCall>[];
    late MethodChannelRecorder recorder;

    setUp(() {
      calls.clear();
      recorder = MethodChannelRecorder();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            switch (call.method) {
              case 'getAvailableSources':
                return <Object?>[
                  <Object?, Object?>{
                    'id': 'display:1',
                    'type': 'display',
                    'title': 'Built-in Display',
                    'subtitle': '2560 × 1600',
                    'pixelWidth': 2560,
                    'pixelHeight': 1600,
                    'isCurrentDisplay': true,
                    'thumbnail': Uint8List.fromList(<int>[1, 2, 3]),
                  },
                ];
              case 'stop':
                return <Object?, Object?>{
                  'path': '/tmp/relay/recording-1.mp4',
                  'recordingId': '1',
                  'sizeBytes': 10,
                  'durationMs': 1000,
                  'createdAtMs': 0,
                  'width': 1280,
                  'height': 720,
                  'frameRate': 30,
                };
              default:
                return null;
            }
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('sources decode, including the thumbnail', () async {
      final List<CaptureSource> sources = await recorder.getAvailableSources();
      expect(calls.single.method, 'getAvailableSources');
      expect(
        (calls.single.arguments as Map<Object?, Object?>)['refreshThumbnails'],
        isTrue,
      );
      expect(sources.single.id, 'display:1');
      expect(sources.single.thumbnail, isNotNull);
      expect(sources.single.isCurrentDisplay, isTrue);
    });

    test('a native failure becomes a typed RecorderException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            throw PlatformException(
              code: 'permissionDenied',
              message: 'not granted',
            );
          });
      await expectLater(
        recorder.start(),
        throwsA(
          isA<RecorderException>().having(
            (RecorderException e) => e.code,
            'code',
            RecorderErrorCode.permissionDenied,
          ),
        ),
      );
    });

    test(
      'a missing implementation reports as unsupported, not as a crash',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await expectLater(
          recorder.start(),
          throwsA(
            isA<RecorderException>().having(
              (RecorderException e) => e.code,
              'code',
              RecorderErrorCode.unsupported,
            ),
          ),
        );
      },
    );

    test('stop decodes the finalized file', () async {
      final RecordingFile file = await recorder.stop();
      expect(file.path, endsWith('.mp4'));
      expect(file.duration, const Duration(seconds: 1));
    });

    test('input toggles pass the flag through', () async {
      await recorder.setMicrophoneEnabled(false);
      await recorder.setCameraEnabled(true);
      await recorder.setSystemAudioEnabled(false);
      expect(calls.map((MethodCall c) => c.method), <String>[
        'setMicrophoneEnabled',
        'setCameraEnabled',
        'setSystemAudioEnabled',
      ]);
      expect(
        calls
            .map(
              (MethodCall c) =>
                  (c.arguments as Map<Object?, Object?>)['enabled'],
            )
            .toList(),
        <bool>[false, true, false],
      );
    });
  });

  group('showCameraPreview payload', () {
    const MethodChannel channel = MethodChannel(RecorderChannels.overlay);
    final List<MethodCall> calls = <MethodCall>[];
    late OverlayWindowController overlays;

    setUp(() {
      calls.clear();
      overlays = MethodChannelOverlayWindowController();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('display mode states the picture-in-picture presentation', () async {
      await overlays.showCameraPreview(
        const OverlayPlacement.absolute(Rect.fromLTWH(100, 200, 160, 90)),
        matchesCompositedPip: true,
        cameraOverlay: const CameraOverlayConfiguration(),
      );

      final Map<Object?, Object?> arguments =
          calls.single.arguments as Map<Object?, Object?>;
      expect(arguments['matchesCompositedPip'], isTrue);
      expect(arguments['cameraOverlay'], isA<Map<Object?, Object?>>());
    });

    test('window mode states it despite also carrying a frame', () async {
      // The host used to read the mode off `frame`, and both modes send one —
      // so it saw display mode every time and the captioned window-mode
      // preview (design `1e`) was unreachable.
      await overlays.showCameraPreview(
        const OverlayPlacement.absolute(Rect.fromLTWH(10, 20, 200, 140)),
        matchesCompositedPip: false,
      );

      final Map<Object?, Object?> arguments =
          calls.single.arguments as Map<Object?, Object?>;
      expect(arguments.containsKey('frame'), isTrue);
      expect(arguments['matchesCompositedPip'], isFalse);
      expect(
        arguments.containsKey('cameraOverlay'),
        isFalse,
        reason: 'the tile configuration follows the mode, it does not set it',
      );
    });
  });

  group('overlay placement encoding', () {
    test('an anchored placement carries size, anchor and margin', () {
      final Map<String, Object?> map = const OverlayPlacement.anchored(
        size: Size(360, 46),
        anchor: OverlayAnchor.topCenter,
        margin: 6,
      ).toMap();
      expect(map['width'], 360.0);
      expect(map['height'], 46.0);
      expect(map['anchor'], 'topCenter');
      expect(map['margin'], 6.0);
      expect(map.containsKey('frame'), isFalse);
    });

    test('an absolute placement carries a frame', () {
      final Map<String, Object?> map = const OverlayPlacement.absolute(
        Rect.fromLTWH(10, 20, 30, 40),
      ).toMap();
      final Map<String, Object?> frame = map['frame']! as Map<String, Object?>;
      expect(frame, <String, Object?>{
        'x': 10.0,
        'y': 20.0,
        'width': 30.0,
        'height': 40.0,
      });
    });

    test('an overlay command this build does not know is ignored', () {
      // The fallback used to be `stop`, so anything the host mis-spelled
      // ended the recording (§6).
      expect(
        OverlayCommand.fromName('pauseOrResume'),
        OverlayCommand.pauseOrResume,
      );
      expect(OverlayCommand.fromName('somethingElse'), isNull);
      expect(OverlayCommand.fromName(null), isNull);
    });

    test('the overlay snapshot round-trips', () {
      const RecordingOverlayState state = RecordingOverlayState(
        isPaused: true,
        elapsed: Duration(minutes: 14, seconds: 32),
        microphoneEnabled: false,
        cameraEnabled: true,
        systemAudioEnabled: true,
        systemAudioAvailable: false,
      );
      expect(RecordingOverlayState.fromMap(state.toMap()), state);
    });
  });

  group('the unsupported platform', () {
    test('fails loudly rather than pretending to record', () async {
      final RecorderPlatform platform = UnsupportedRecorderPlatform();
      expect((await platform.recorder.getCapabilities()).isSupported, isFalse);
      expect(await platform.recorder.getAvailableSources(), isEmpty);
      await expectLater(
        platform.recorder.start(),
        throwsA(isA<RecorderException>()),
      );
      // Teardown must stay safe so a caller can always clean up.
      await platform.recorder.abort();
      await platform.recorder.dispose();
      await platform.overlays.hideControlStrip();
    });
  });

  group('a display the platform could not read is refused (§5)', () {
    test('a usable geometry reports itself usable', () {
      const DisplayGeometry geometry = DisplayGeometry(
        id: '1',
        logicalWidth: 1512,
        logicalHeight: 982,
        pixelWidth: 3024,
        pixelHeight: 1964,
        scaleFactor: 2,
      );
      expect(geometry.isUsable, isTrue);
    });

    test('a zero-sized geometry does not', () {
      // The decode used to produce exactly this from a null reply, and every
      // caller downstream treated it as a real display: overlay placement
      // resolved against an empty rectangle and the strip was docked nowhere.
      expect(DisplayGeometry.unknown.isUsable, isFalse);
    });

    test('tryFromMap returns null rather than a well-formed nothing', () {
      expect(DisplayGeometry.tryFromMap(const <String, Object?>{}), isNull);
      expect(
        DisplayGeometry.tryFromMap(const <String, Object?>{
          'id': '1',
          'logicalWidth': 0,
          'logicalHeight': 0,
        }),
        isNull,
      );
    });

    test('tryFromMap decodes a real reply', () {
      final DisplayGeometry? geometry = DisplayGeometry.tryFromMap(
        const <String, Object?>{
          'id': '1',
          'logicalWidth': 1512.0,
          'logicalHeight': 982.0,
          'pixelWidth': 3024,
          'pixelHeight': 1964,
          'scaleFactor': 2.0,
        },
      );
      expect(geometry, isNotNull);
      expect(geometry!.logicalWidth, 1512.0);
      expect(geometry.scaleFactor, 2.0);
    });
  });
}
