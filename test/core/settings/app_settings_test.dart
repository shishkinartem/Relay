import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/settings/app_settings.dart';

void main() {
  group('AppSettings defaults', () {
    test('match the specification', () {
      const AppSettings settings = AppSettings();

      expect(settings.microphoneEnabled, isTrue);
      expect(settings.systemAudioEnabled, isTrue);
      expect(settings.cameraEnabled, isFalse);
      expect(settings.showCursor, isTrue);
      expect(settings.frameRate, 30);
      expect(settings.quality, RecordingQuality.hd720);
      expect(settings.preferredSourceType, CaptureSourceType.display);
      expect(settings.uploadDestinationId, 'telegram');
      expect(settings.localRecordingsDirectory, isNull);
    });

    test('are produced by an empty document', () {
      expect(
        AppSettings.fromJson(const <String, Object?>{}),
        const AppSettings(),
      );
    });
  });

  group('AppSettings json', () {
    test('round-trips every field', () {
      const AppSettings settings = AppSettings(
        uploadDestinationId: 'telegram',
        localRecordingsDirectory: '/Users/a/Movies/Recorder',
        quality: RecordingQuality.fullHd1080,
        frameRate: 60,
        microphoneEnabled: false,
        systemAudioEnabled: false,
        cameraEnabled: true,
        showCursor: false,
        preferredSourceType: CaptureSourceType.window,
      );

      final AppSettings decoded = AppSettings.fromJson(settings.toJson());

      expect(decoded, settings);
      expect(decoded.hashCode, settings.hashCode);
    });

    test('stamps the current schema version', () {
      expect(
        const AppSettings().toJson()[AppSettings.keySchemaVersion],
        AppSettings.currentSchemaVersion,
      );
    });

    test('ignores an unknown field', () {
      final Map<String, Object?> json = const AppSettings().toJson()
        ..['experimentalHdr'] = true;

      expect(AppSettings.fromJson(json), const AppSettings());
    });

    test('falls back to the default for a missing field', () {
      final Map<String, Object?> json =
          const AppSettings(frameRate: 60).toJson()
            ..remove(AppSettings.keyFrameRate)
            ..remove(AppSettings.keyMicrophoneEnabled);

      final AppSettings decoded = AppSettings.fromJson(json);

      expect(decoded.frameRate, 30);
      expect(decoded.microphoneEnabled, isTrue);
    });

    test('falls back to the default for a wrongly typed field', () {
      final AppSettings decoded = AppSettings.fromJson(<String, Object?>{
        AppSettings.keyFrameRate: '60',
        AppSettings.keyCameraEnabled: 'yes',
        AppSettings.keyQuality: 42,
        AppSettings.keyPreferredSourceType: <String>['window'],
      });

      expect(decoded.frameRate, 30);
      expect(decoded.cameraEnabled, isFalse);
      expect(decoded.quality, RecordingQuality.hd720);
      expect(decoded.preferredSourceType, CaptureSourceType.display);
    });

    test('falls back to the default for an unknown enum name', () {
      final AppSettings decoded = AppSettings.fromJson(<String, Object?>{
        AppSettings.keyQuality: 'uhd2160',
        AppSettings.keyPreferredSourceType: 'hologram',
      });

      expect(decoded.quality, RecordingQuality.hd720);
      expect(decoded.preferredSourceType, CaptureSourceType.display);
    });

    test('reads a null recordings directory as the platform default', () {
      expect(
        AppSettings.fromJson(<String, Object?>{
          AppSettings.keyLocalRecordingsDirectory: null,
        }).localRecordingsDirectory,
        isNull,
      );
    });
  });

  group('AppSettings copyWith', () {
    test('replaces only the named fields', () {
      const AppSettings settings = AppSettings(
        localRecordingsDirectory: '/tmp/recordings',
      );

      final AppSettings updated = settings.copyWith(cameraEnabled: true);

      expect(updated.cameraEnabled, isTrue);
      expect(updated.localRecordingsDirectory, '/tmp/recordings');
      expect(updated.microphoneEnabled, isTrue);
    });

    test('clears the recordings directory when null is passed explicitly', () {
      const AppSettings settings = AppSettings(
        localRecordingsDirectory: '/tmp/recordings',
      );

      expect(
        settings
            .copyWith(localRecordingsDirectory: null)
            .localRecordingsDirectory,
        isNull,
      );
    });

    test('an unrelated change keeps equality with an identical value', () {
      expect(const AppSettings().copyWith(frameRate: 30), const AppSettings());
    });
  });

  group('input devices and disclosure state (§33.2)', () {
    test('choices and open sections round-trip', () {
      const AppSettings settings = AppSettings(
        inputDevices: <MediaDeviceKind, InputDeviceChoice>{
          MediaDeviceKind.microphone: InputDeviceChoice(
            id: 'mic:mv7',
            label: 'Shure MV7',
          ),
        },
        expandedInputs: <MediaDeviceKind>{MediaDeviceKind.microphone},
      );

      final AppSettings restored = AppSettings.fromJson(settings.toJson());

      expect(restored, settings);
      expect(restored.hashCode, settings.hashCode);
      expect(
        restored.inputDevices[MediaDeviceKind.microphone]?.label,
        'Shure MV7',
      );
      expect(restored.expandedInputs, <MediaDeviceKind>{
        MediaDeviceKind.microphone,
      });
    });

    test('defaults are no choice made and every section closed', () {
      const AppSettings settings = AppSettings();

      expect(settings.inputDevices, isEmpty);
      expect(settings.expandedInputs, isEmpty);
    });

    test('a stored kind this build does not know is dropped', () {
      // Defaulting it would file a choice under the wrong input.
      final AppSettings settings = AppSettings.fromJson(<String, Object?>{
        AppSettings.keyInputDevices: <String, Object?>{
          'telepathy': <String, Object?>{'id': 'x', 'label': 'Mind'},
          'microphone': <String, Object?>{'id': 'mic:1', 'label': 'Mic'},
        },
        AppSettings.keyExpandedInputs: <Object?>['telepathy', 'camera'],
      });

      expect(settings.inputDevices.keys, <MediaDeviceKind>[
        MediaDeviceKind.microphone,
      ]);
      expect(settings.expandedInputs, <MediaDeviceKind>{
        MediaDeviceKind.camera,
      });
    });

    test('a stored choice with no id is not a choice', () {
      final AppSettings settings = AppSettings.fromJson(<String, Object?>{
        AppSettings.keyInputDevices: <String, Object?>{
          'microphone': <String, Object?>{'label': 'Ghost'},
        },
      });

      expect(settings.inputDevices, isEmpty);
    });

    test(
      'a choice with no label degrades to its id rather than to nothing',
      () {
        final AppSettings settings = AppSettings.fromJson(<String, Object?>{
          AppSettings.keyInputDevices: <String, Object?>{
            'microphone': <String, Object?>{'id': 'mic:1'},
          },
        });

        expect(
          settings.inputDevices[MediaDeviceKind.microphone]?.label,
          'mic:1',
        );
      },
    );
  });
}
