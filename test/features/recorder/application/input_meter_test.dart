import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/logging/app_logger.dart';
import 'package:relay/features/recorder/application/input_meter.dart';

/// "Is this microphone hearing me?" (§33.2)
///
/// The rules worth locking in are the ones about not leaving a device open and
/// not calling a working microphone deaf.
void main() {
  const MediaDeviceKind mic = MediaDeviceKind.microphone;
  const MediaDeviceKind camera = MediaDeviceKind.camera;
  const InputLevel loud = InputLevel(peak: 0.8, rms: 0.6);

  late _FakeMeteringProvider provider;
  late PlatformInputMeter meter;

  setUp(() {
    provider = _FakeMeteringProvider();
    meter = PlatformInputMeter(
      provider: provider,
      logger: AppLogger(sinks: <LogSink>[MemoryLogSink()]),
      meterableKinds: const <MediaDeviceKind>{MediaDeviceKind.microphone},
      silenceThreshold: 3,
    );
  });

  test('a kind the platform cannot meter never opens a tap', () async {
    await meter.start(camera);

    expect(provider.started, isEmpty);
    expect(meter.isRunningFor(camera), isFalse);
  });

  test('starting twice opens one tap', () async {
    await meter.start(mic);
    await meter.start(mic);

    expect(provider.started, <MediaDeviceKind>[mic]);
  });

  test('re-pointing at another device moves the tap, it does not add one', () async {
    // The bar under a device row has to be that device, or picking between two
    // microphones by speaking does not work at all (§33.2).
    await meter.start(mic, deviceId: 'mic:builtin');
    await meter.start(mic, deviceId: 'mic:mv7');

    expect(provider.devices, <String?>['mic:builtin', 'mic:mv7']);
    expect(meter.meteredDeviceFor(mic), 'mic:mv7');
    expect(meter.isRunningFor(mic), isTrue);
    expect(
      provider.stopped,
      <MediaDeviceKind>[mic],
      reason:
          'both platforms count references; a start with no matching stop '
          'leaves the microphone open for the life of the process',
    );
  });

  test('a re-point leaves exactly one reference to close', () async {
    await meter.start(mic, deviceId: 'mic:a');
    await meter.start(mic, deviceId: 'mic:b');
    await meter.start(mic, deviceId: 'mic:c');
    await meter.stop(mic);

    // Three starts, three stops: two closing the taps that were re-pointed and
    // one closing the last. The platform's count is back at zero.
    expect(provider.started, hasLength(3));
    expect(provider.stopped, hasLength(3));
    expect(meter.isRunningFor(mic), isFalse);
  });

  test(
    're-pointing forgets what the previous device was heard to be',
    () async {
      await meter.start(mic, deviceId: 'mic:builtin');
      for (int i = 0; i < 5; i++) {
        meter.accept(mic, InputLevel.silent);
      }
      expect(meter.isSilentFor(mic), isTrue);

      await meter.start(mic, deviceId: 'mic:mv7');

      expect(
        meter.isSilentFor(mic),
        isFalse,
        reason: 'the new microphone has not been given a chance yet',
      );
    },
  );

  test('starting again on the same device changes nothing', () async {
    await meter.start(mic, deviceId: 'mic:mv7');
    await meter.start(mic, deviceId: 'mic:mv7');

    expect(provider.started, <MediaDeviceKind>[mic]);
  });

  test('stopping closes it, and stopping again is a no-op', () async {
    await meter.start(mic);
    await meter.stop(mic);
    await meter.stop(mic);

    expect(provider.stopped, <MediaDeviceKind>[mic]);
    expect(meter.isRunningFor(mic), isFalse);
  });

  test('stopAll closes every tap that is open', () async {
    meter.meterableKinds = <MediaDeviceKind>{mic, camera};
    await meter.start(mic);
    await meter.start(camera);

    await meter.stopAll();

    expect(provider.stopped, unorderedEquals(<MediaDeviceKind>[mic, camera]));
    expect(meter.isRunningFor(mic), isFalse);
    expect(meter.isRunningFor(camera), isFalse);
  });

  test(
    'a platform that refuses to start leaves nothing marked running',
    () async {
      provider.failStart = const RecorderException(
        RecorderErrorCode.microphoneUnavailable,
        'busy',
      );

      await meter.start(mic);

      expect(
        meter.isRunningFor(mic),
        isFalse,
        reason: 'otherwise a stop is never issued for a tap that never opened',
      );
    },
  );

  test('levels only count while the tap is open', () async {
    meter.accept(mic, loud);
    expect(meter.levelFor(mic), InputLevel.silent);

    await meter.start(mic);
    meter.accept(mic, loud);
    expect(meter.levelFor(mic), loud);

    await meter.stop(mic);
    meter.accept(mic, loud);
    expect(
      meter.levelFor(mic),
      InputLevel.silent,
      reason: 'a sample after the stop is the tail of a closed stream',
    );
  });

  group('silence', () {
    test('is not reported until the threshold is reached', () async {
      await meter.start(mic);

      meter
        ..accept(mic, InputLevel.silent)
        ..accept(mic, InputLevel.silent);
      expect(meter.isSilentFor(mic), isFalse);

      meter.accept(mic, InputLevel.silent);
      expect(meter.isSilentFor(mic), isTrue);
    });

    test('one sound resets the count', () async {
      await meter.start(mic);
      meter
        ..accept(mic, InputLevel.silent)
        ..accept(mic, InputLevel.silent)
        ..accept(mic, loud)
        ..accept(mic, InputLevel.silent)
        ..accept(mic, InputLevel.silent);

      expect(meter.isSilentFor(mic), isFalse);
    });

    test('a stopped meter is never called silent', () async {
      await meter.start(mic);
      for (int i = 0; i < 5; i++) {
        meter.accept(mic, InputLevel.silent);
      }
      await meter.stop(mic);

      expect(
        meter.isSilentFor(mic),
        isFalse,
        reason: '"nothing is metering" and "nothing is arriving" are different',
      );
    });

    test('changing the device does not carry the old silence over', () async {
      await meter.start(mic);
      for (int i = 0; i < 5; i++) {
        meter.accept(mic, InputLevel.silent);
      }
      expect(meter.isSilentFor(mic), isTrue);

      meter.reset(mic);

      expect(
        meter.isSilentFor(mic),
        isFalse,
        reason: 'the new microphone has not been given a chance yet',
      );
    });
  });
}

class _FakeMeteringProvider implements MediaDeviceProvider {
  final List<MediaDeviceKind> started = <MediaDeviceKind>[];
  final List<String?> devices = <String?>[];
  final List<MediaDeviceKind> stopped = <MediaDeviceKind>[];
  RecorderException? failStart;

  @override
  Future<List<MediaDevice>> getInputDevices(MediaDeviceKind kind) async =>
      const <MediaDevice>[];

  @override
  Future<void> startInputMetering(
    MediaDeviceKind kind, {
    String? deviceId,
  }) async {
    final RecorderException? failure = failStart;
    if (failure != null) {
      throw failure;
    }
    started.add(kind);
    devices.add(deviceId);
  }

  @override
  Future<void> selectInputDevice(
    MediaDeviceKind kind, {
    String? deviceId,
  }) async {}

  @override
  Future<void> stopInputMetering(MediaDeviceKind kind) async =>
      stopped.add(kind);
}
