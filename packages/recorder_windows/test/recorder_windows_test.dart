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
        // Null on every one of the three: an unconfigured session must open
        // exactly the devices the plugin opened before device selection
        // existed (§33.2).
        'cameraDeviceId': null,
        'microphoneDeviceId': null,
        'systemAudioDeviceId': null,
        // §33.5's shape of the tile. `cornerRadius` in canvas pixels is gone:
        // it is a ratio of the tile's width on both sides now, so one
        // configuration describes the same shape on a 720p and a 1080p canvas.
        // `positionX`/`positionY` are always present and null together — the
        // tile is on its corner.
        'cameraOverlay': <String, Object?>{
          'preset': 'camera',
          'widthRatio': 0.16,
          'aspectRatio': 16 / 9,
          'followsSourceAspectRatio': true,
          'cornerRadiusRatio': 0.0,
          'marginRatio': 0.01,
          'corner': 'bottomRight',
          'fit': 'contain',
          'positionX': null,
          'positionY': null,
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

  group('relay/recorder input devices', () {
    late Recorder recorder;

    setUp(() {
      recorder = RecorderWindows().recorder;
    });

    test('a chosen device rides along on prepare', () async {
      await recorder.prepare(
        const RecordingConfiguration(
          source: source,
          recordingId: '8f2a11',
          outputDirectoryPath: r'C:\Users\ada\Videos\Relay',
          cameraDeviceId: r'\\?\usb#vid_046d&pid_085e#mi_00',
          microphoneDeviceId: '{0.0.1.00000000}.{7a2b}',
          systemAudioDeviceId: '{0.0.0.00000000}.{1c4d}',
        ),
      );

      final Map<Object?, Object?> arguments =
          calls.single.arguments as Map<Object?, Object?>;
      expect(arguments['cameraDeviceId'], r'\\?\usb#vid_046d&pid_085e#mi_00');
      expect(arguments['microphoneDeviceId'], '{0.0.1.00000000}.{7a2b}');
      expect(arguments['systemAudioDeviceId'], '{0.0.0.00000000}.{1c4d}');
    });

    test('getInputDevices names the kind and keeps the default first', () async {
      // The native half orders the list; this asserts the package carries that
      // order through rather than re-sorting it.
      respond = (MethodCall call) => <Object?>[
        <String, Object?>{
          'id': '{0.0.1.00000000}.{7a2b}',
          'kind': 'microphone',
          'label': 'Microphone Array (Realtek)',
          'isSystemDefault': true,
          'isAvailable': true,
        },
        <String, Object?>{
          'id': '{0.0.1.00000000}.{9f10}',
          'kind': 'microphone',
          'label': 'Shure MV7',
          'isSystemDefault': false,
          'isAvailable': true,
        },
      ];

      final List<MediaDevice> devices = await recorder.getInputDevices(
        MediaDeviceKind.microphone,
      );

      expect(calls.single.method, 'getInputDevices');
      expect(calls.single.arguments, <String, Object?>{'kind': 'microphone'});
      expect(devices.first.isSystemDefault, isTrue);
      expect(devices.map((MediaDevice d) => d.label).toList(), <String>[
        'Microphone Array (Realtek)',
        'Shure MV7',
      ]);
    });

    test('an empty list is an answer, not a failure', () async {
      // No camera attached. The native half must not report this as
      // unimplemented: Dart would surface that as RecorderErrorCode.unsupported.
      respond = (MethodCall call) => <Object?>[];

      expect(await recorder.getInputDevices(MediaDeviceKind.camera), isEmpty);
      expect(calls.single.arguments, <String, Object?>{'kind': 'camera'});
    });

    test('metering names the device the bar sits under', () async {
      // The native half opens the device it is given: a meter showing the
      // system default while the user picks between two microphones answers a
      // question nobody asked (§33.2).
      await recorder.startInputMetering(
        MediaDeviceKind.microphone,
        deviceId: 'mic:mv7',
      );
      await recorder.stopInputMetering(MediaDeviceKind.microphone);

      expect(calls.map((MethodCall c) => c.method).toList(), <String>[
        'startInputMetering',
        'stopInputMetering',
      ]);
      expect(calls[0].arguments, <String, Object?>{
        'kind': 'microphone',
        'deviceId': 'mic:mv7',
      });
      expect(calls[1].arguments, <String, Object?>{'kind': 'microphone'});
    });

    test('no device named is the platform default, spelled as null', () async {
      // The plugin reads one shape: `deviceId` is always present, and an
      // absent or null one means the endpoint Windows would pick itself —
      // exactly what a null id means on the recording configuration.
      await recorder.startInputMetering(MediaDeviceKind.microphone);

      expect(calls.single.arguments, <String, Object?>{
        'kind': 'microphone',
        'deviceId': null,
      });
    });

    test('selectInputDevice names the kind and the device', () async {
      // The live swap (§33.2). The plugin re-points the running capture; it
      // does not restart the session, so nothing here carries a configuration.
      await recorder.selectInputDevice(
        MediaDeviceKind.camera,
        deviceId: r'\\?\usb#vid_046d&pid_085e#mi_00',
      );

      expect(calls.single.method, 'selectInputDevice');
      expect(calls.single.arguments, <String, Object?>{
        'kind': 'camera',
        'deviceId': r'\\?\usb#vid_046d&pid_085e#mi_00',
      });
    });

    test(
      'selecting no device is the platform default, spelled as null',
      () async {
        await recorder.selectInputDevice(MediaDeviceKind.systemAudio);

        expect(calls.single.arguments, <String, Object?>{
          'kind': 'systemAudio',
          'deviceId': null,
        });
      },
    );
  });

  group('relay/recorder camera picture-in-picture', () {
    late Recorder recorder;

    setUp(() {
      recorder = RecorderWindows().recorder;
    });

    test('setCameraOverlay sends the preset the user chose', () async {
      // Circle · small: 1:1 at 0.10 of the canvas width, centre-cropped, and a
      // corner radius of half the tile's width — which is the circle (§33.5).
      await recorder.setCameraOverlay(
        CameraOverlayConfiguration.forPreset(
          CameraPipPreset.circle,
          position: const Offset(0.42, 0.18),
        ),
      );

      expect(calls.single.method, 'setCameraOverlay');
      expect(calls.single.arguments, <String, Object?>{
        'preset': 'circle',
        'widthRatio': CameraOverlayConfiguration.smallPresetWidth,
        'aspectRatio': 1.0,
        'followsSourceAspectRatio': false,
        'cornerRadiusRatio': 0.5,
        'marginRatio': 0.01,
        'corner': 'bottomRight',
        'fit': 'cover',
        'positionX': 0.42,
        'positionY': 0.18,
        'mirrorPreview': true,
        'mirrorOutput': false,
      });
    });

    test('cameraPreviewPosition decodes the fraction of the canvas', () async {
      respond = (MethodCall call) => <String, Object?>{'x': 0.42, 'y': 0.18};

      final Offset? position = await recorder.cameraPreviewPosition();

      expect(calls.single.method, 'cameraPreviewPosition');
      expect(calls.single.arguments, isNull);
      expect(position?.dx, closeTo(0.42, 1e-9));
      expect(position?.dy, closeTo(0.18, 1e-9));
    });

    test('a preview that is not the tile reports nothing', () async {
      // Window mode: the preview is a separate captioned object there, so
      // dragging it moves the preview and nothing else (design `1e`).
      respond = (MethodCall call) => null;

      expect(await recorder.cameraPreviewPosition(), isNull);
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

    test('a remembered position rides along on showControlStrip', () async {
      // What the native half has to decode to put the strip back where the user
      // left it (§33.3): a fraction of the display's usable area, plus the
      // display it was measured on. The anchor still travels with it, because
      // that is the fallback when the display is gone.
      await overlays.showControlStrip(
        const OverlayPlacement.fractional(
          size: Size(360, 46),
          position: OverlayStripPosition(
            displayId: 'display:65537',
            x: 0.31,
            y: 0.44,
          ),
          margin: 6,
        ),
      );

      expect(calls.single.method, 'showControlStrip');
      expect(calls.single.arguments, <String, Object?>{
        'width': 360.0,
        'height': 46.0,
        'anchor': 'topCenter',
        'margin': 6.0,
        'position': <String, Object?>{
          'displayId': 'display:65537',
          'x': 0.31,
          'y': 0.44,
        },
      });
    });

    test('controlStripPosition decodes where the strip ended up', () async {
      // The display id is spelled the way the native half spells every other
      // display id — `display:<HMONITOR>` — and is opaque here.
      respond = (MethodCall call) => <String, Object?>{
        'displayId': 'display:65537',
        'x': 0.62,
        'y': 0.08,
      };

      final OverlayStripPosition? position = await overlays
          .controlStripPosition();

      expect(calls.single.method, 'controlStripPosition');
      expect(calls.single.arguments, isNull);
      expect(position?.displayId, 'display:65537');
      expect(position?.x, closeTo(0.62, 1e-9));
      expect(position?.y, closeTo(0.08, 1e-9));
    });

    test('a strip the host cannot locate is null, not the origin', () async {
      // No strip on screen, or a display the host cannot name. Dart then keeps
      // whatever it had stored: failing to read a position is not the user
      // having moved the strip back.
      respond = (MethodCall call) => null;

      expect(await overlays.controlStripPosition(), isNull);
    });

    test('setMainWindowVisible hides the main panel for the session', () async {
      await overlays.setMainWindowVisible(false);

      expect(calls.single.method, 'setMainWindowVisible');
      expect(calls.single.arguments, <String, Object?>{'visible': false});
    });

    test('excludedWindowIds reports the capture exclusion set', () async {
      // Three ids once a menu is open: the strip, the preview and the menu.
      // §6's exclusion rule applies to the third exactly as it does to the
      // other two, and a menu that appeared in a recording is the one
      // unacceptable outcome (§33.4).
      respond = (MethodCall call) => <Object?>['920318', '920442', '921004'];

      final List<String> ids = await overlays.excludedWindowIds();

      expect(calls.single.method, 'excludedWindowIds');
      expect(ids, <String>['920318', '920442', '921004']);
    });

    test('showInputMenu sends the placement and the menu state', () async {
      await overlays.showInputMenu(
        const OverlayPlacement.anchored(
          size: Size(240, 180),
          anchor: OverlayAnchor.topCenter,
          margin: 6,
        ),
        const InputMenuOverlayState(
          kind: MediaDeviceKind.microphone,
          title: 'Microphone',
          items: <InputMenuItem>[
            InputMenuItem(label: 'System default', meta: 'Shure MV7'),
            InputMenuItem(id: 'mic:mv7', label: 'Shure MV7', selected: true),
          ],
          level: InputLevel(peak: 0.62, rms: 0.41),
        ),
      );

      expect(calls.single.method, 'showInputMenu');
      expect(calls.single.arguments, <String, Object?>{
        'width': 240.0,
        'height': 180.0,
        'anchor': 'topCenter',
        'margin': 6.0,
        'state': <String, Object?>{
          'kind': 'microphone',
          'title': 'Microphone',
          'loading': false,
          'emptyMessage': null,
          'notice': null,
          'level': <String, Object?>{'peak': 0.62, 'rms': 0.41},
          'items': <Object?>[
            <String, Object?>{
              'id': null,
              'label': 'System default',
              'meta': 'Shure MV7',
              'selected': false,
              'enabled': true,
            },
            <String, Object?>{
              'id': 'mic:mv7',
              'label': 'Shure MV7',
              'meta': null,
              'selected': true,
              'enabled': true,
            },
          ],
          // The camera sheet's own rows, empty on every other kind (§33.4).
          // Present rather than omitted, because the host forwards this map to
          // the menu engine untouched and the menu reads one shape.
          'presets': <Object?>[],
          'selectedPreset': null,
          'canResetPosition': false,
          'corners': <Object?>[],
          'selectedCorner': null,
        },
      });
    });

    test('updateInputMenu re-renders in place, without a placement', () async {
      // A device that appears or disappears must not close the sheet the user
      // is reading (§33.7), so the update carries state and nothing else.
      await overlays.updateInputMenu(
        const InputMenuOverlayState(
          kind: MediaDeviceKind.camera,
          title: 'Camera',
          emptyMessage: 'No camera found',
        ),
      );

      expect(calls.single.method, 'updateInputMenu');
      final Map<Object?, Object?> arguments =
          calls.single.arguments as Map<Object?, Object?>;
      expect(arguments['kind'], 'camera');
      expect(arguments['emptyMessage'], 'No camera found');
      expect(arguments.containsKey('width'), isFalse);
    });

    test('hideInputMenu takes no arguments', () async {
      await overlays.hideInputMenu();

      expect(calls.single.method, 'hideInputMenu');
      expect(calls.single.arguments, isNull);
    });

    test('nudgeControlStrip carries logical points', () async {
      // The keyboard path §33.3 deferred: the host moves the strip and then
      // clamps and snaps it exactly as the end of a drag does.
      await overlays.nudgeControlStrip(-8, 32);

      expect(calls.single.method, 'nudgeControlStrip');
      expect(calls.single.arguments, <String, Object?>{'dx': -8.0, 'dy': 32.0});
    });
  });

  group('relay/overlay/events', () {
    // What the Windows half has to put on this one channel: bare command names
    // and choice maps, side by side, decoded by shape (§33.4). Each stream is
    // exercised on its own subscription — see the note in
    // `menuSelections decodes a choice`.
    late MockStreamHandlerEventSink sink;

    void listenToOverlayEvents() {
      messenger.setMockStreamHandler(
        const EventChannel(RecorderChannels.overlayEvents),
        MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            sink = events;
          },
        ),
      );
      addTearDown(
        () => messenger.setMockStreamHandler(
          const EventChannel(RecorderChannels.overlayEvents),
          null,
        ),
      );
    }

    test('commands decode the bare names and ignore a choice', () async {
      final OverlayWindowController overlays = RecorderWindows().overlays;
      listenToOverlayEvents();

      final List<OverlayCommand> seen = <OverlayCommand>[];
      final StreamSubscription<OverlayCommand> subscription = overlays.commands
          .listen(seen.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      sink.success('openMicrophoneMenu');
      // A choice on the same channel is not a command, and decoding it as one
      // would press a button nobody pressed.
      sink.success(<String, Object?>{
        'kind': 'microphone',
        'deviceId': 'mic:mv7',
        'off': false,
      });
      sink.success('resetStripPosition');
      await pumpEventQueue();

      expect(seen, <OverlayCommand>[
        OverlayCommand.openMicrophoneMenu,
        OverlayCommand.resetStripPosition,
      ]);
    });

    test('menuSelections decodes a choice and ignores a command', () async {
      // Its own subscription, and not one taken alongside `commands`: both
      // getters call `receiveBroadcastStream()` separately, and a second listen
      // replaces the first on *both* sides of the bridge — Dart's
      // `binaryMessenger.setMessageHandler` and the C++ EventChannel wrapper's
      // `OnCancel`-then-`OnListen`. Whichever stream is subscribed last is the
      // only one that receives anything, so asserting both at once would assert
      // a thing no host can do.
      final OverlayWindowController overlays = RecorderWindows().overlays;
      listenToOverlayEvents();

      final List<InputMenuSelection> seen = <InputMenuSelection>[];
      final StreamSubscription<InputMenuSelection> subscription = overlays
          .menuSelections
          .listen(seen.add);
      addTearDown(subscription.cancel);
      await pumpEventQueue();

      sink.success('openMicrophoneMenu');
      sink.success(<String, Object?>{
        'kind': 'microphone',
        'deviceId': 'mic:mv7',
        'off': false,
      });
      // `System default` is a null device id; `Off` is the existing toggle
      // rather than a device.
      sink.success(<String, Object?>{
        'kind': 'camera',
        'deviceId': null,
        'off': true,
      });
      await pumpEventQueue();

      expect(seen, <InputMenuSelection>[
        const InputMenuSelection(
          kind: MediaDeviceKind.microphone,
          deviceId: 'mic:mv7',
        ),
        const InputMenuSelection(kind: MediaDeviceKind.camera, off: true),
      ]);
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
      // Linear amplitude in [0, 1], never decibels and never a buffer: §3 keeps
      // raw media native.
      sink!.success(<String, Object?>{
        'type': 'inputLevel',
        'kind': 'microphone',
        'peak': 0.62,
        'rms': 0.41,
      });
      // The Windows half names no kind: what it watches is an audio endpoint
      // change, and "re-read everything" is the only instruction that is also
      // true of the camera list.
      sink!.success(<String, Object?>{'type': 'devicesChanged'});
      await pumpEventQueue();

      expect(seen, hasLength(6));
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
      expect(
        (seen[4] as RecorderInputLevelEvent).kind,
        MediaDeviceKind.microphone,
      );
      expect(
        (seen[4] as RecorderInputLevelEvent).level.peak,
        closeTo(0.62, 1e-9),
      );
      expect((seen[5] as RecorderDevicesChangedEvent).kind, isNull);
    });
  });
}
