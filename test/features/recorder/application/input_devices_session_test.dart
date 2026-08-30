import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/settings/app_settings.dart';

import '../../../support/fakes.dart';
import '../../../support/harness.dart';

/// What the session actually asks the platform to open (§33.2).
///
/// The invariant worth locking in hardest is the boring one: an install that
/// never chose a device must send no device id at all, so it records exactly
/// what it recorded before any of this existed.
void main() {
  test('an unconfigured session names no device', () async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();

    await harness.viewModel.requestStart();

    final RecordingConfiguration configuration =
        harness.recorder.lastConfiguration!;
    expect(configuration.cameraDeviceId, isNull);
    expect(configuration.microphoneDeviceId, isNull);
    expect(configuration.systemAudioDeviceId, isNull);
  });

  test('a chosen device travels with the configuration', () async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();

    await harness.viewModel.selectInputDevice(
      MediaDeviceKind.microphone,
      harness.viewModel
          .devicesFor(MediaDeviceKind.microphone)
          .firstWhere((MediaDevice d) => d.id == 'mic:mv7'),
    );
    await harness.viewModel.requestStart();

    expect(harness.recorder.lastConfiguration!.microphoneDeviceId, 'mic:mv7');
    expect(harness.recorder.lastConfiguration!.cameraDeviceId, isNull);
  });

  test('a remembered choice is honoured on the next launch', () async {
    final TestHarness harness = await TestHarness.create(
      settings: const AppSettings(
        inputDevices: <MediaDeviceKind, InputDeviceChoice>{
          MediaDeviceKind.camera: InputDeviceChoice(
            id: 'camera:brio',
            label: 'Logitech Brio',
          ),
        },
      ),
    );
    addTearDown(harness.dispose);
    await harness.initialize();

    await harness.viewModel.requestStart();

    expect(harness.recorder.lastConfiguration!.cameraDeviceId, 'camera:brio');
  });

  test('a remembered device that is gone degrades and says so', () async {
    final FakeRecorder recorder = FakeRecorder()
      ..devices = <MediaDeviceKind, List<MediaDevice>>{
        MediaDeviceKind.microphone: <MediaDevice>[
          const MediaDevice(
            id: 'mic:builtin',
            kind: MediaDeviceKind.microphone,
            label: 'MacBook Pro Microphone',
            isSystemDefault: true,
          ),
        ],
      };
    final TestHarness harness = await TestHarness.create(
      recorder: recorder,
      settings: const AppSettings(
        inputDevices: <MediaDeviceKind, InputDeviceChoice>{
          MediaDeviceKind.microphone: InputDeviceChoice(
            id: 'mic:mv7',
            label: 'Shure MV7',
          ),
        },
      ),
    );
    addTearDown(harness.dispose);
    await harness.initialize();

    expect(
      harness.viewModel.unresolvedDevices[MediaDeviceKind.microphone],
      'Shure MV7',
    );

    await harness.viewModel.requestStart();

    expect(
      harness.recorder.lastConfiguration!.microphoneDeviceId,
      isNull,
      reason: 'a wrong microphone is worse than the default one',
    );
  });

  test('a device-list change is re-read, not ignored', () async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    harness.recorder.calls.clear();

    harness.recorder.emit(
      const RecorderDevicesChangedEvent(MediaDeviceKind.microphone),
    );
    // The reload is scheduled off the event, so one turn of the loop is needed.
    await Future<void>.delayed(Duration.zero);

    expect(harness.recorder.calls, contains('getInputDevices(microphone)'));
  });

  test('a change with no kind re-reads every selectable kind', () async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    harness.recorder.calls.clear();

    harness.recorder.emit(const RecorderDevicesChangedEvent(null));
    await Future<void>.delayed(Duration.zero);

    expect(
      harness.recorder.calls,
      containsAll(<String>[
        'getInputDevices(camera)',
        'getInputDevices(microphone)',
      ]),
    );
  });

  test('a level event reaches the meter that asked for it', () async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();

    await harness.viewModel.startMetering(MediaDeviceKind.microphone);
    harness.recorder.emit(
      const RecorderInputLevelEvent(
        MediaDeviceKind.microphone,
        InputLevel(peak: 0.9, rms: 0.5),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(harness.viewModel.levelFor(MediaDeviceKind.microphone).rms, 0.5);
  });

  test('the meter listens to the device the user chose', () async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();

    await harness.viewModel.startMetering(MediaDeviceKind.microphone);
    expect(
      harness.recorder.meteredDevices[MediaDeviceKind.microphone],
      isNull,
      reason: 'nothing chosen means the platform default',
    );

    await harness.viewModel.selectInputDevice(
      MediaDeviceKind.microphone,
      harness.viewModel
          .devicesFor(MediaDeviceKind.microphone)
          .firstWhere((MediaDevice d) => d.id == 'mic:mv7'),
    );

    expect(
      harness.recorder.meteredDevices[MediaDeviceKind.microphone],
      'mic:mv7',
      reason: 'the bar has to follow the row that was just picked',
    );
  });

  test('a kind the platform cannot meter is never tapped', () async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();

    await harness.viewModel.startMetering(MediaDeviceKind.camera);

    expect(harness.recorder.metering, isEmpty);
    expect(harness.viewModel.canMeter(MediaDeviceKind.camera), isFalse);
    expect(harness.viewModel.canMeter(MediaDeviceKind.microphone), isTrue);
  });

  test('disposing the session closes every tap it opened', () async {
    final TestHarness harness = await TestHarness.create();
    await harness.initialize();
    await harness.viewModel.startMetering(MediaDeviceKind.microphone);
    expect(harness.recorder.metering, isNotEmpty);

    await harness.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(harness.recorder.metering, isEmpty);
  });

  test(
    'which kinds offer a choice comes from capabilities, not the OS',
    () async {
      final FakeRecorder recorder = FakeRecorder()
        ..capabilities = const RecorderCapabilities(
          qualities: <RecordingQuality>{RecordingQuality.hd720},
          supportedFrameRates: <int>{30},
          supportedSourceTypes: <CaptureSourceType>{CaptureSourceType.display},
          // A Windows-shaped platform: the loopback endpoint is a real choice.
          selectableDeviceKinds: <MediaDeviceKind>{
            MediaDeviceKind.camera,
            MediaDeviceKind.microphone,
            MediaDeviceKind.systemAudio,
          },
          meterableDeviceKinds: <MediaDeviceKind>{MediaDeviceKind.microphone},
          supportsCamera: true,
          supportsMicrophone: true,
          supportsSystemAudio: true,
          supportsPause: true,
          supportsCursorCapture: true,
          supportsHardwareEncoding: true,
        );
      final TestHarness harness = await TestHarness.create(recorder: recorder);
      addTearDown(harness.dispose);
      await harness.initialize();

      expect(
        harness.viewModel.canChooseDevice(MediaDeviceKind.systemAudio),
        isTrue,
      );
      expect(harness.viewModel.canMeter(MediaDeviceKind.systemAudio), isFalse);
    },
  );
}
