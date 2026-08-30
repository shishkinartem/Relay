import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/logging/app_logger.dart';
import 'package:relay/core/settings/app_settings.dart';
import 'package:relay/features/recorder/application/device_catalog.dart';

/// Which device each input opens (§33.2).
///
/// The rules that matter are all about *not* silently recording the wrong
/// thing: a remembered device that has gone must be reported, not quietly
/// replaced, and one kind failing to enumerate must not cost the user another
/// kind that answered.
void main() {
  const MediaDevice builtIn = MediaDevice(
    id: 'mic:builtin',
    kind: MediaDeviceKind.microphone,
    label: 'MacBook Pro Microphone',
    isSystemDefault: true,
  );
  const MediaDevice mv7 = MediaDevice(
    id: 'mic:mv7',
    kind: MediaDeviceKind.microphone,
    label: 'Shure MV7',
  );
  const MediaDevice busy = MediaDevice(
    id: 'mic:busy',
    kind: MediaDeviceKind.microphone,
    label: 'Studio Interface',
    isAvailable: false,
  );

  late _FakeDeviceProvider provider;
  late PlatformDeviceCatalog catalog;

  setUp(() {
    provider = _FakeDeviceProvider();
    catalog = PlatformDeviceCatalog(
      provider: provider,
      logger: AppLogger(sinks: <LogSink>[MemoryLogSink()]),
      timeout: const Duration(milliseconds: 50),
    );
  });

  group('enumeration', () {
    test('devices arrive in the order the platform gave them', () async {
      provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[
        builtIn,
        mv7,
      ];

      expect(
        await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone}),
        DeviceLoadResult.loaded,
      );
      expect(
        catalog
            .devicesFor(MediaDeviceKind.microphone)
            .map((MediaDevice d) => d.id),
        <String>['mic:builtin', 'mic:mv7'],
      );
    });

    test(
      'nothing chosen means the platform default, and no id on the wire',
      () async {
        provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[
          builtIn,
          mv7,
        ];
        await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});

        expect(catalog.selectionFor(MediaDeviceKind.microphone), isNull);
        expect(catalog.effectiveDeviceFor(MediaDeviceKind.microphone), builtIn);
        expect(
          catalog.deviceIdFor(MediaDeviceKind.microphone),
          isNull,
          reason: 'null is what makes an unconfigured session record as before',
        );
      },
    );

    test('a platform that forgot the default flag still names one', () async {
      // The contract promises the default comes first. A platform that kept the
      // order but dropped the flag must not leave the screen with nothing to
      // name.
      provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[mv7, busy];
      await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});

      expect(catalog.effectiveDeviceFor(MediaDeviceKind.microphone), mv7);
    });

    test('one kind failing does not cost another kind that answered', () async {
      provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[builtIn];
      provider.failures[MediaDeviceKind.camera] = const RecorderException(
        RecorderErrorCode.permissionDenied,
        'no camera access',
      );

      final DeviceLoadResult result = await catalog.load(<MediaDeviceKind>{
        MediaDeviceKind.camera,
        MediaDeviceKind.microphone,
      });

      expect(result, DeviceLoadResult.failed);
      expect(catalog.lastFailure, RecorderErrorCode.permissionDenied);
      expect(catalog.devicesFor(MediaDeviceKind.microphone), <MediaDevice>[
        builtIn,
      ]);
    });

    test('a kind that never answers is reported as that kind', () async {
      provider.hang.add(MediaDeviceKind.camera);

      expect(
        await catalog.load(<MediaDeviceKind>{MediaDeviceKind.camera}),
        DeviceLoadResult.failed,
      );
      expect(
        catalog.lastFailure,
        RecorderErrorCode.cameraUnavailable,
        reason: 'the screen has to be able to say which input is in trouble',
      );
    });

    test(
      'a second load while one is in flight is skipped, not queued',
      () async {
        provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[builtIn];
        final Future<DeviceLoadResult> first = catalog.load(<MediaDeviceKind>{
          MediaDeviceKind.microphone,
        });
        expect(catalog.isLoading, isTrue);
        final DeviceLoadResult second = await catalog.load(<MediaDeviceKind>{
          MediaDeviceKind.microphone,
        });

        expect(second, DeviceLoadResult.skipped);
        await first;
        expect(
          catalog.isLoading,
          isFalse,
          reason: 'the latch is always released',
        );
      },
    );

    test(
      'a failure leaves the previous list rather than emptying it',
      () async {
        provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[
          builtIn,
          mv7,
        ];
        await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});

        provider.failures[MediaDeviceKind.microphone] = const RecorderException(
          RecorderErrorCode.microphoneUnavailable,
          'gone',
        );
        await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});

        expect(catalog.devicesFor(MediaDeviceKind.microphone), hasLength(2));
      },
    );
  });

  group('choosing', () {
    setUp(() {
      provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[
        builtIn,
        mv7,
      ];
    });

    test('a named device travels as its id', () async {
      await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});
      catalog.select(MediaDeviceKind.microphone, mv7);

      expect(catalog.deviceIdFor(MediaDeviceKind.microphone), 'mic:mv7');
      expect(catalog.effectiveDeviceFor(MediaDeviceKind.microphone), mv7);
    });

    test(
      'naming the device that is currently the default still names it',
      () async {
        // `System default` and "the device that is the default today" are
        // different answers, and the picker offers both rows.
        await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});
        catalog.select(MediaDeviceKind.microphone, builtIn);

        expect(catalog.deviceIdFor(MediaDeviceKind.microphone), 'mic:builtin');
      },
    );

    test('choosing the system default clears the id', () async {
      await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});
      catalog.select(MediaDeviceKind.microphone, mv7);
      catalog.select(MediaDeviceKind.microphone, null);

      expect(catalog.deviceIdFor(MediaDeviceKind.microphone), isNull);
      expect(catalog.selectionFor(MediaDeviceKind.microphone), isNull);
    });

    test(
      'a refreshed list re-points the selection at the fresh instance',
      () async {
        await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});
        catalog.select(MediaDeviceKind.microphone, mv7);

        // The same device, now unavailable — equality is (id, kind), so only a
        // re-point picks the new flag up.
        provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[
          builtIn,
          const MediaDevice(
            id: 'mic:mv7',
            kind: MediaDeviceKind.microphone,
            label: 'Shure MV7',
            isAvailable: false,
          ),
        ];
        await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});

        expect(
          catalog.selectionFor(MediaDeviceKind.microphone)?.isAvailable,
          isFalse,
        );
      },
    );

    test('a device unplugged and plugged back in is chosen again', () async {
      await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});
      catalog.select(MediaDeviceKind.microphone, mv7);

      provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[builtIn];
      await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});
      expect(catalog.deviceIdFor(MediaDeviceKind.microphone), isNull);

      provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[
        builtIn,
        mv7,
      ];
      await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});

      expect(
        catalog.deviceIdFor(MediaDeviceKind.microphone),
        'mic:mv7',
        reason: 'the device went away; the choice did not',
      );
      expect(catalog.unresolved, isEmpty);
    });

    test('an empty list keeps the choice for when a device returns', () async {
      await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});
      catalog.select(MediaDeviceKind.microphone, mv7);

      provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[];
      await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});
      expect(catalog.effectiveDeviceFor(MediaDeviceKind.microphone), isNull);

      provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[mv7];
      await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});

      expect(catalog.deviceIdFor(MediaDeviceKind.microphone), 'mic:mv7');
    });

    test(
      'a device that disappears while selected is reported by name',
      () async {
        await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});
        catalog.select(MediaDeviceKind.microphone, mv7);

        provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[builtIn];
        await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});

        expect(catalog.unresolved[MediaDeviceKind.microphone], 'Shure MV7');
        expect(catalog.deviceIdFor(MediaDeviceKind.microphone), isNull);
        expect(catalog.effectiveDeviceFor(MediaDeviceKind.microphone), builtIn);
      },
    );
  });

  group('remembered choices', () {
    test('a remembered id is honoured by the enumeration that resolves it', () async {
      provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[
        builtIn,
        mv7,
      ];
      catalog.restore(const <MediaDeviceKind, InputDeviceChoice>{
        MediaDeviceKind.microphone: InputDeviceChoice(
          id: 'mic:mv7',
          label: 'Shure MV7',
        ),
      });

      // Restored before any list existed, which is the real ordering: settings
      // load before the platform answers.
      expect(catalog.deviceIdFor(MediaDeviceKind.microphone), isNull);

      await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});

      expect(catalog.deviceIdFor(MediaDeviceKind.microphone), 'mic:mv7');
      expect(catalog.unresolved, isEmpty);
    });

    test(
      'a remembered device that is gone is named, not silently replaced',
      () async {
        provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[builtIn];
        catalog.restore(const <MediaDeviceKind, InputDeviceChoice>{
          MediaDeviceKind.microphone: InputDeviceChoice(
            id: 'mic:mv7',
            label: 'Shure MV7',
          ),
        });
        await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});

        expect(catalog.unresolved[MediaDeviceKind.microphone], 'Shure MV7');
        expect(catalog.effectiveDeviceFor(MediaDeviceKind.microphone), builtIn);
      },
    );

    test('a remembered device that comes back is picked up', () async {
      provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[builtIn];
      catalog.restore(const <MediaDeviceKind, InputDeviceChoice>{
        MediaDeviceKind.microphone: InputDeviceChoice(
          id: 'mic:mv7',
          label: 'Shure MV7',
        ),
      });
      await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});

      provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[
        builtIn,
        mv7,
      ];
      await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});

      expect(catalog.deviceIdFor(MediaDeviceKind.microphone), 'mic:mv7');
      expect(catalog.unresolved, isEmpty);
    });

    test('choosing something else forgets the unresolved warning', () async {
      provider.devices[MediaDeviceKind.microphone] = <MediaDevice>[builtIn];
      catalog.restore(const <MediaDeviceKind, InputDeviceChoice>{
        MediaDeviceKind.microphone: InputDeviceChoice(
          id: 'mic:mv7',
          label: 'Shure MV7',
        ),
      });
      await catalog.load(<MediaDeviceKind>{MediaDeviceKind.microphone});

      catalog.select(MediaDeviceKind.microphone, builtIn);

      expect(catalog.unresolved, isEmpty);
      expect(catalog.deviceIdFor(MediaDeviceKind.microphone), 'mic:builtin');
    });
  });
}

class _FakeDeviceProvider implements MediaDeviceProvider {
  final Map<MediaDeviceKind, List<MediaDevice>> devices =
      <MediaDeviceKind, List<MediaDevice>>{};
  final Map<MediaDeviceKind, RecorderException> failures =
      <MediaDeviceKind, RecorderException>{};
  final Set<MediaDeviceKind> hang = <MediaDeviceKind>{};

  @override
  Future<List<MediaDevice>> getInputDevices(MediaDeviceKind kind) async {
    if (hang.contains(kind)) {
      await Completer<void>().future;
    }
    final RecorderException? failure = failures[kind];
    if (failure != null) {
      throw failure;
    }
    return devices[kind] ?? const <MediaDevice>[];
  }

  @override
  Future<void> startInputMetering(
    MediaDeviceKind kind, {
    String? deviceId,
  }) async {}

  @override
  Future<void> stopInputMetering(MediaDeviceKind kind) async {}
}
