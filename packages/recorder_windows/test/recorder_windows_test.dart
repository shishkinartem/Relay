import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:recorder_windows/recorder_windows.dart';

/// Exercises the Windows composition root against the channel contract in
/// `docs/architecture/platform-channel-contract.md`.
///
/// Every subject here is built from [RecorderWindows] itself, so what is
/// asserted is what this package routes onto the channels: the method names,
/// the payload shapes and the decoded replies the C++ half in `windows/` has
/// to speak on the other side.
///
/// The native half cannot run in a Dart test — the channels are faked. Its
/// marshalling is covered only by the platform integration tests, which need a
/// Windows host (`docs/development/testing.md`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const MethodChannel recorderChannel = MethodChannel(
    RecorderChannels.recorder,
  );
  const MethodChannel overlayChannel = MethodChannel(RecorderChannels.overlay);
  const List<MethodChannel> mockedChannels = <MethodChannel>[
    recorderChannel,
    overlayChannel,
  ];

  final List<MethodCall> calls = <MethodCall>[];
  Object? Function(MethodCall call)? respond;

  setUp(() {
    calls.clear();
    respond = null;
    for (final MethodChannel channel in mockedChannels) {
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return respond?.call(call);
      });
    }
  });

  tearDown(() {
    for (final MethodChannel channel in mockedChannels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  const CaptureSource source = CaptureSource(
    id: 'display:65537',
    type: CaptureSourceType.display,
    title: 'Generic PnP Monitor',
    subtitle: '2560 × 1440',
    pixelWidth: 2560,
    pixelHeight: 1440,
    isCurrentDisplay: true,
  );

  group('registration', () {
    test('registerWith installs the Windows platform', () {
      RecorderWindows.registerWith();

      expect(RecorderPlatform.instance, isA<RecorderWindows>());
    });

    test('registration is idempotent', () {
      RecorderWindows.registerWith();
      final RecorderPlatform first = RecorderPlatform.instance;
      RecorderWindows.registerWith();

      expect(RecorderPlatform.instance, same(first));
    });

    test('reuses the shared channel implementations, adding no Dart layer', () {
      final RecorderWindows platform = RecorderWindows();

      expect(platform.recorder, isA<MethodChannelRecorder>());
      expect(platform.permissions, isA<MethodChannelRecorderPermissions>());
      expect(platform.overlays, isA<MethodChannelOverlayWindowController>());
    });
  });

  group('relay/recorder traffic', () {
    late Recorder recorder;

    setUp(() {
      // Built from the Windows platform itself, not from the global instance:
      // the traffic asserted below has to be this package's, not whatever
      // implementation happens to be registered.
      recorder = RecorderWindows().recorder;
    });

    test('prepare sends the documented configuration map', () async {
      await recorder.prepare(
        const RecordingConfiguration(
          source: source,
          recordingId: '8f2a11',
          outputDirectoryPath: r'C:\Users\ada\Videos\Relay',
          quality: RecordingQuality.fullHd1080,
          frameRate: 60,
          cameraEnabled: true,
          systemAudioEnabled: false,
        ),
      );

      expect(calls, hasLength(1));
      expect(calls.single.method, 'prepare');
      expect(calls.single.arguments, <String, Object?>{
        'sourceId': 'display:65537',
        'sourceType': 'display',
        'sourceWidth': 2560,
        'sourceHeight': 1440,
        'recordingId': '8f2a11',
        'outputDirectoryPath': r'C:\Users\ada\Videos\Relay',
        'quality': 'fullHd1080',
        'targetHeight': 1080,
        'frameRate': 60,
        'cameraEnabled': true,
        'microphoneEnabled': true,
        'systemAudioEnabled': false,
        'showCursor': true,
        'cameraOverlay': <String, Object?>{
          'widthRatio': 0.16,
          'aspectRatio': 16 / 9,
          'followsSourceAspectRatio': true,
          'cornerRadius': 0.0,
          'marginRatio': 0.01,
          'corner': 'bottomRight',
          'mirrorPreview': true,
          'mirrorOutput': false,
        },
        'composition': <String, Object?>{
          'aspectRatioPolicy': 'containWithinPreset',
          'geometryChangePolicy': 'fixedCanvasLetterbox',
        },
      });
    });

    test('start takes no arguments', () async {
      await recorder.start();

      expect(calls.single.method, 'start');
      expect(calls.single.arguments, isNull);
    });

    test('stop parses the recording-file map', () async {
      respond = (MethodCall call) => <String, Object?>{
        'path': r'C:\Users\ada\Videos\Relay\recording-8f2a11.mp4',
        'recordingId': '8f2a11',
        'sizeBytes': 1094813696,
        'durationMs': 872000,
        'createdAtMs': 1755900000000,
        'width': 1920,
        'height': 1080,
        'frameRate': 60,
        'hasAudio': true,
        'hasCamera': false,
      };

      final RecordingFile file = await recorder.stop();

      expect(calls.single.method, 'stop');
      expect(calls.single.arguments, isNull);
      expect(file.path, endsWith(r'\recording-8f2a11.mp4'));
      expect(file.recordingId, '8f2a11');
      expect(file.duration, const Duration(milliseconds: 872000));
      expect(file.width, 1920);
      expect(file.height, 1080);
      expect(file.frameRate, 60);
      expect(file.hasCamera, isFalse);
    });

    test('releaseSession is its own call, not an abort or a dispose', () async {
      // Leaving the post-recording screen has to reach the native side, and it
      // is not either of the calls that already existed: `abort` is about an
      // unfinished recording and a platform may refuse it once a file has been
      // finalized, and `dispose` ends the platform with the process.
      await recorder.releaseSession();

      expect(calls.single.method, 'releaseSession');
      expect(calls.single.arguments, isNull);
    });

    test('runtime input toggles carry the enabled flag', () async {
      await recorder.setMicrophoneEnabled(false);
      await recorder.setCameraEnabled(true);
      await recorder.setSystemAudioEnabled(false);

      expect(calls.map((MethodCall c) => c.method).toList(), <String>[
        'setMicrophoneEnabled',
        'setCameraEnabled',
        'setSystemAudioEnabled',
      ]);
      expect(calls[0].arguments, <String, Object?>{'enabled': false});
      expect(calls[1].arguments, <String, Object?>{'enabled': true});
      expect(calls[2].arguments, <String, Object?>{'enabled': false});
    });

    test(
      'getAvailableSources keeps the platform order: displays, then windows',
      () async {
        respond = (MethodCall call) => <Object?>[
          <String, Object?>{
            'id': 'display:65537',
            'type': 'display',
            'title': 'Generic PnP Monitor',
            'subtitle': '2560 × 1440',
            'pixelWidth': 2560,
            'pixelHeight': 1440,
            'isCurrentDisplay': true,
            'thumbnail': Uint8List.fromList(<int>[137, 80, 78, 71]),
          },
          <String, Object?>{
            'id': 'window:263450',
            'type': 'window',
            'title': 'Visual Studio Code',
            'subtitle': 'recording_session.cpp',
            'pixelWidth': 1600,
            'pixelHeight': 900,
          },
        ];

        final List<CaptureSource> sources = await recorder
            .getAvailableSources();

        expect(calls.single.method, 'getAvailableSources');
        expect(calls.single.arguments, <String, Object?>{
          'refreshThumbnails': true,
        });
        expect(
          sources.map((CaptureSource s) => s.type).toList(),
          <CaptureSourceType>[
            CaptureSourceType.display,
            CaptureSourceType.window,
          ],
        );
        expect(sources.first.isCurrentDisplay, isTrue);
        expect(sources.first.thumbnail, isNotNull);
        expect(sources.last.thumbnail, isNull);
      },
    );

    test('a native failure surfaces as the typed error code', () async {
      respond = (MethodCall call) => throw PlatformException(
        code: RecorderErrorCode.diskFull.name,
        message: 'The recording drive is full.',
        details: 'free=12MB',
      );

      await expectLater(
        recorder.start(),
        throwsA(
          isA<RecorderException>().having(
            (RecorderException e) => e.code,
            'code',
            RecorderErrorCode.diskFull,
          ),
        ),
      );
    });
  });

  group('relay/overlay traffic', () {
    late OverlayWindowController overlays;

    setUp(() {
      overlays = RecorderWindows().overlays;
    });

    test('showControlStrip sends the anchored placement map', () async {
      await overlays.showControlStrip(
        const OverlayPlacement.anchored(
          size: Size(360, 56),
          anchor: OverlayAnchor.bottomCenter,
          margin: 24,
        ),
      );

      expect(calls.single.method, 'showControlStrip');
      expect(calls.single.arguments, <String, Object?>{
        'width': 360.0,
        'height': 56.0,
        'anchor': 'bottomCenter',
        'margin': 24.0,
      });
    });

    test('setMainWindowVisible hides the main panel for the session', () async {
      await overlays.setMainWindowVisible(false);

      expect(calls.single.method, 'setMainWindowVisible');
      expect(calls.single.arguments, <String, Object?>{'visible': false});
    });

    test('excludedWindowIds reports the capture exclusion set', () async {
      respond = (MethodCall call) => <Object?>['920318', '920442'];

      final List<String> ids = await overlays.excludedWindowIds();

      expect(calls.single.method, 'excludedWindowIds');
      expect(ids, <String>['920318', '920442']);
    });
  });

  group('relay/recorder/events', () {
    test('decodes the documented event payloads', () async {
      final Recorder recorder = RecorderWindows().recorder;

      MockStreamHandlerEventSink? sink;
      messenger.setMockStreamHandler(
        const EventChannel(RecorderChannels.recorderEvents),
        MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            sink = events;
          },
        ),
      );

      final List<RecorderEvent> seen = <RecorderEvent>[];
      final StreamSubscription<RecorderEvent> subscription = recorder.events
          .listen(seen.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      sink!.success(<String, Object?>{'type': 'state', 'state': 'recording'});
      sink!.success(<String, Object?>{'type': 'tick', 'elapsedMs': 872000});
      sink!.success(<String, Object?>{
        'type': 'stats',
        'capturedFrames': 26160,
        'encodedFrames': 26154,
        'droppedFrames': 6,
        'audioDiscontinuities': 0,
        'avDriftMs': 3.2,
        'encoderName': 'Media Foundation H.264 (hardware)',
        'hardwareEncoding': true,
      });
      sink!.success(<String, Object?>{
        'type': 'error',
        'code': 'systemAudioUnavailable',
        'message': 'The default render endpoint disappeared.',
        'fatal': false,
      });
      await pumpEventQueue();

      expect(seen, hasLength(4));
      expect(
        (seen[0] as RecorderStateEvent).state,
        PlatformRecorderState.recording,
      );
      expect(
        (seen[1] as RecorderTickEvent).elapsed,
        const Duration(milliseconds: 872000),
      );
      expect((seen[2] as RecorderStatsEvent).droppedFrames, 6);
      expect((seen[2] as RecorderStatsEvent).hardwareEncoding, isTrue);
      expect(
        (seen[3] as RecorderErrorEvent).code,
        RecorderErrorCode.systemAudioUnavailable,
      );
      expect((seen[3] as RecorderErrorEvent).fatal, isFalse);
    });
  });
}
