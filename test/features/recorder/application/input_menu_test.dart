import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import 'package:relay/core/settings/app_settings.dart';
import 'package:relay/features/recorder/domain/session_state.dart';

import '../../../support/fakes.dart';
import '../../../support/harness.dart';

/// The device list a chevron opens, and the swap a choice makes (§33.4).
///
/// The rules worth locking in are the ones about a window floating over
/// someone else's screen: it opens once, it closes on every path, and a choice
/// reaches the running capture rather than only the next recording.
void main() {
  Future<TestHarness> recording({FakeRecorder? recorder}) async {
    final TestHarness harness = await TestHarness.create(recorder: recorder);
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.viewModel.requestStart();
    harness.overlays.calls.clear();
    harness.recorder.calls.clear();
    return harness;
  }

  group('opening and closing', () {
    test('a chevron opens the list for its own input', () async {
      final TestHarness harness = await recording();

      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);

      expect(harness.viewModel.openMenuKind, MediaDeviceKind.microphone);
      final InputMenuOverlayState state = harness.overlays.menuStates.first;
      expect(state.kind, MediaDeviceKind.microphone);
      expect(state.title, 'Microphone');
      expect(
        state.items.map((InputMenuItem i) => i.label),
        containsAllInOrder(<String>[
          'System default',
          'MacBook Pro Microphone',
          'Shure MV7',
          'Microphone off',
        ]),
      );
    });

    test('a second press on the same chevron closes it', () async {
      final TestHarness harness = await recording();

      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);

      expect(harness.viewModel.openMenuKind, isNull);
      expect(harness.overlays.calls, contains('hideInputMenu'));
    });

    test('the session ending closes it', () async {
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.camera);

      await harness.viewModel.stop();

      expect(harness.viewModel.openMenuKind, isNull);
      expect(harness.overlays.calls, contains('hideInputMenu'));
    });

    test('the meter it opened closes with it', () async {
      final TestHarness harness = await recording();

      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);
      expect(harness.recorder.metering, isNotEmpty);

      await harness.viewModel.closeInputMenu();

      expect(
        harness.recorder.metering,
        isEmpty,
        reason: 'a meter nobody is looking at must not hold a microphone',
      );
    });

    test('a menu the host closed is no longer believed to be open', () async {
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);

      harness.overlays.menuController.add(
        const InputMenuSelection.dismissed(MediaDeviceKind.microphone),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(harness.viewModel.openMenuKind, isNull);
      expect(
        harness.recorder.metering,
        isEmpty,
        reason: 'the meter went with the window the host closed',
      );
    });

    test('the chevron reopens a menu the host closed, on one press', () async {
      // The defect this locks out: a click outside closes the window, the
      // application still thinks it is open, and the next press is read as the
      // second press that closes it — so the menu takes two presses to come
      // back.
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);
      harness.overlays.menuController.add(
        const InputMenuSelection.dismissed(MediaDeviceKind.microphone),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      harness.overlays.calls.clear();

      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);

      expect(harness.viewModel.openMenuKind, MediaDeviceKind.microphone);
      expect(harness.overlays.calls, contains('showInputMenu(microphone)'));
    });

    test('a dismissal for another menu leaves the open one alone', () async {
      // Two windows never overlap, but a late dismissal from the one just
      // replaced must not close its successor.
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.camera);

      harness.overlays.menuController.add(
        const InputMenuSelection.dismissed(MediaDeviceKind.microphone),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(harness.viewModel.openMenuKind, MediaDeviceKind.camera);
    });

    test('a device appearing re-renders it rather than closing it', () async {
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);
      harness.overlays.calls.clear();

      harness.recorder.emit(
        const RecorderDevicesChangedEvent(MediaDeviceKind.microphone),
      );
      await Future<void>.delayed(Duration.zero);

      expect(harness.viewModel.openMenuKind, MediaDeviceKind.microphone);
      expect(harness.overlays.calls, contains('updateInputMenu(microphone)'));
      expect(harness.overlays.calls, isNot(contains('hideInputMenu')));
    });
  });

  group('what the menu says', () {
    test('a kind still loading shows one row, not an empty panel', () async {
      final TestHarness harness = await recording();
      // Nothing has been enumerated for a kind the platform cannot choose.
      final InputMenuOverlayState state = harness.viewModel.menuStateFor(
        MediaDeviceKind.systemAudio,
      );

      expect(state.items.map((InputMenuItem i) => i.label), <String>[
        'System audio off',
      ]);
      expect(state.emptyMessage, 'System mix');
    });

    test(
      'a device that cannot be opened is shown and not selectable',
      () async {
        final FakeRecorder recorder = FakeRecorder()
          ..devices = <MediaDeviceKind, List<MediaDevice>>{
            MediaDeviceKind.microphone: <MediaDevice>[
              const MediaDevice(
                id: 'mic:builtin',
                kind: MediaDeviceKind.microphone,
                label: 'MacBook Pro Microphone',
                isSystemDefault: true,
              ),
              const MediaDevice(
                id: 'mic:busy',
                kind: MediaDeviceKind.microphone,
                label: 'Studio Interface',
                isAvailable: false,
              ),
            ],
          };
        final TestHarness harness = await recording(recorder: recorder);

        final InputMenuOverlayState state = harness.viewModel.menuStateFor(
          MediaDeviceKind.microphone,
        );
        final InputMenuItem busy = state.items.firstWhere(
          (InputMenuItem i) => i.id == 'mic:busy',
        );

        expect(busy.enabled, isFalse);
        expect(busy.meta, 'in use');
      },
    );

    test('the microphone carries a level and the camera does not', () async {
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);
      harness.recorder.emit(
        const RecorderInputLevelEvent(
          MediaDeviceKind.microphone,
          InputLevel(peak: 0.8, rms: 0.6),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        harness.viewModel.menuStateFor(MediaDeviceKind.microphone).level?.rms,
        0.6,
      );
      expect(
        harness.viewModel.menuStateFor(MediaDeviceKind.camera).level,
        isNull,
      );
    });
  });

  group('nothing is left holding a device', () {
    test('opening a second sheet releases the first one’s meter', () async {
      // §33.7. Replacing a sheet used to leave the previous kind's meter
      // demanded, so a microphone stayed open for a bar nobody was looking at —
      // and outlived the session that opened it.
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);
      expect(harness.recorder.metering, contains(MediaDeviceKind.microphone));

      await harness.viewModel.openInputMenu(MediaDeviceKind.camera);

      expect(
        harness.recorder.metering,
        isNot(contains(MediaDeviceKind.microphone)),
        reason: 'the sheet that went away took its microphone with it',
      );
    });

    test('the session ending leaves no meter running', () async {
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);

      await harness.viewModel.stop();

      expect(harness.recorder.metering, isEmpty);
    });

    test('a sheet that hangs on close still gives the window back', () async {
      // The main window is hidden for the whole of a recording and restored by
      // the last step of the teardown. `closeInputMenu` used to run *before*
      // that loop, unguarded: a hang in it left the recording safe and the
      // application unreachable.
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);
      harness.overlays.hangOnHideInputMenu = true;

      await harness.viewModel.stop();

      expect(
        harness.overlays.mainWindowVisible,
        isTrue,
        reason: 'a wedged sheet must not cost the user their window',
      );
    });
  });

  group('the camera sheet carries the shapes', () {
    test('the three presets, with the current one marked', () async {
      final TestHarness harness = await recording();
      await harness.viewModel.setCameraPreset(CameraPipPreset.circle);

      final InputMenuOverlayState state = harness.viewModel.menuStateFor(
        MediaDeviceKind.camera,
      );

      expect(state.presets, CameraPipPreset.values);
      expect(state.selectedPreset, CameraPipPreset.circle);
    });

    test('no other sheet offers them', () async {
      final TestHarness harness = await recording();

      for (final MediaDeviceKind kind in <MediaDeviceKind>[
        MediaDeviceKind.microphone,
        MediaDeviceKind.systemAudio,
      ]) {
        final InputMenuOverlayState state = harness.viewModel.menuStateFor(
          kind,
        );
        expect(state.presets, isEmpty, reason: '${kind.name} has no tile');
        expect(state.selectedPreset, isNull);
      }
    });

    test('a preset applies to the running capture', () async {
      final TestHarness harness = await recording();
      await harness.settings.setCameraEnabled(true);
      await harness.viewModel.openInputMenu(MediaDeviceKind.camera);
      harness.recorder.cameraOverlays.clear();

      harness.overlays.menuController.add(
        const InputMenuSelection.preset(
          MediaDeviceKind.camera,
          CameraPipPreset.square,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        harness.recorder.cameraOverlays.single.preset,
        CameraPipPreset.square,
      );
    });

    test('and leaves the sheet open, re-rendered', () async {
      // A device choice closes the sheet; a shape does not. The tile changes
      // under it and comparing the three should not cost a reopen each time.
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.camera);
      harness.overlays.calls.clear();

      harness.overlays.menuController.add(
        const InputMenuSelection.preset(
          MediaDeviceKind.camera,
          CameraPipPreset.circle,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(harness.viewModel.openMenuKind, MediaDeviceKind.camera);
      expect(harness.overlays.calls, contains('updateInputMenu(camera)'));
      expect(harness.overlays.calls, isNot(contains('hideInputMenu')));
      expect(
        harness.overlays.menuStates.last.selectedPreset,
        CameraPipPreset.circle,
      );
    });

    test('a display source offers no corners, because it drags', () async {
      final TestHarness harness = await recording();

      final InputMenuOverlayState state = harness.viewModel.menuStateFor(
        MediaDeviceKind.camera,
      );

      expect(
        state.corners,
        isEmpty,
        reason: 'the preview is the tile there; a corner is the worse answer',
      );
    });

    test('a window source offers the four corners instead', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.refreshSources();
      harness.viewModel.selectSource(
        harness.viewModel.sources.firstWhere(
          (CaptureSource s) => s.type == CaptureSourceType.window,
        ),
      );
      await harness.viewModel.requestStart();

      final InputMenuOverlayState state = harness.viewModel.menuStateFor(
        MediaDeviceKind.camera,
      );

      expect(state.corners, CameraOverlayCorner.values);
      expect(state.selectedCorner, CameraOverlayCorner.bottomRight);
    });

    test('a corner reaches the live tile and clears any drag', () async {
      final TestHarness harness = await recording();
      await harness.viewModel.setCameraPreset(CameraPipPreset.square);
      await harness.settings.update(
        harness.settings.settings.copyWith(
          cameraPipPosition: const Offset(0.3, 0.2),
        ),
      );
      harness.recorder.cameraOverlays.clear();

      harness.overlays.menuController.add(
        const InputMenuSelection.corner(
          MediaDeviceKind.camera,
          CameraOverlayCorner.topLeft,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        harness.settings.settings.cameraPipCorner,
        CameraOverlayCorner.topLeft,
      );
      expect(
        harness.settings.settings.cameraPipPosition,
        isNull,
        reason: 'a stored fraction would silently win over the chosen corner',
      );
      expect(
        harness.recorder.cameraOverlays.single.corner,
        CameraOverlayCorner.topLeft,
      );
    });

    test('the corner survives a settings round trip', () {
      const AppSettings settings = AppSettings(
        cameraPipCorner: CameraOverlayCorner.topRight,
      );

      final AppSettings restored = AppSettings.fromJson(settings.toJson());

      expect(restored.cameraPipCorner, CameraOverlayCorner.topRight);
      expect(restored, settings);
    });

    test('a document written before corners existed keeps the default', () {
      // Adding a field must not move a tile that was placed by an older build.
      expect(
        AppSettings.fromJson(const <String, Object?>{}).cameraPipCorner,
        CameraOverlayCorner.bottomRight,
      );
    });

    test('Reset position is offered only once the tile has moved', () async {
      final TestHarness harness = await recording();
      expect(
        harness.viewModel.menuStateFor(MediaDeviceKind.camera).canResetPosition,
        isFalse,
        reason: 'before a drag it would put the tile where it already is',
      );

      await harness.settings.update(
        harness.settings.settings.copyWith(
          cameraPipPosition: const Offset(0.3, 0.2),
        ),
      );

      expect(
        harness.viewModel.menuStateFor(MediaDeviceKind.camera).canResetPosition,
        isTrue,
      );
    });

    test('Reset position puts the tile back in its corner', () async {
      final TestHarness harness = await recording();
      await harness.settings.update(
        harness.settings.settings.copyWith(
          cameraPipPosition: const Offset(0.3, 0.2),
        ),
      );
      harness.recorder.cameraOverlays.clear();

      harness.overlays.menuController.add(
        const InputMenuSelection.resetTilePosition(MediaDeviceKind.camera),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(harness.settings.settings.cameraPipPosition, isNull);
      expect(harness.recorder.cameraOverlays.single.position, isNull);
    });
  });

  group('the level reaches the sheet', () {
    // The defect this group locks out: the sheet renders in its own engine and
    // holds no state, so `notifyListeners()` — which is what makes the launch
    // screen's bar move — reaches nothing there. Without a pushed snapshot the
    // bar stayed at the value it had when the sheet opened, which is silence,
    // and a working microphone read permanently as "TEST — NO SOUND".
    //
    // Every assertion here is on what CROSSED the engine boundary
    // (`overlays.menuStates`), never on `menuStateFor` — the factory was
    // correct all along, which is exactly why the existing test above passed
    // while the bug was live.
    Future<void> emit(TestHarness harness, InputLevel level) async {
      harness.recorder.emit(
        RecorderInputLevelEvent(MediaDeviceKind.microphone, level),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }

    test('a sample pushes a new snapshot to the open sheet', () async {
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);
      final int before = harness.overlays.menuStates.length;

      await emit(harness, const InputLevel(peak: 0.4, rms: 0.3));
      await emit(harness, const InputLevel(peak: 0.9, rms: 0.7));

      expect(harness.overlays.menuStates.length, greaterThan(before));
      expect(harness.overlays.menuStates.last.level?.peak, 0.9);
      expect(
        harness.overlays.menuStates.last.level?.isSilent,
        isFalse,
        reason:
            'a bar that says "no sound" while someone is speaking is the '
            'more misleading half of the symptom',
      );
    });

    test('a sample for a kind whose sheet is closed pushes nothing', () async {
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.camera);
      final int before = harness.overlays.menuStates.length;

      await emit(harness, const InputLevel(peak: 0.6, rms: 0.5));

      expect(
        harness.overlays.menuStates.length,
        before,
        reason: 'twenty pushes a second for a sheet nobody opened',
      );
    });

    test('no sheet at all, no push', () async {
      final TestHarness harness = await recording();

      await emit(harness, const InputLevel(peak: 0.6, rms: 0.5));

      expect(harness.overlays.menuStates, isEmpty);
    });

    test('an unchanged level is not pushed twice', () async {
      // Silence is twenty identical samples a second, forever.
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);
      const InputLevel same = InputLevel(peak: 0.2, rms: 0.1);
      await emit(harness, same);
      final int after = harness.overlays.menuStates.length;

      await emit(harness, same);
      await emit(harness, same);

      expect(harness.overlays.menuStates.length, after);
    });

    test('pushes never overlap, and settle on the newest sample', () async {
      // `updateInputMenu` is an awaited round trip. Firing one every 50 ms
      // unawaited lets two land out of order, and a bar that settles on a stale
      // sample is worse than one that skips a frame.
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);
      harness.overlays.peakMenuUpdatesInFlight = 0;
      final Completer<void> gate = Completer<void>();
      harness.overlays.holdMenuUpdate = gate;

      await emit(harness, const InputLevel(peak: 0.1, rms: 0.1));
      await emit(harness, const InputLevel(peak: 0.5, rms: 0.4));
      await emit(harness, const InputLevel(peak: 0.8, rms: 0.6));

      expect(
        harness.overlays.peakMenuUpdatesInFlight,
        1,
        reason: 'two pushes in flight can land in either order',
      );

      harness.overlays.holdMenuUpdate = null;
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        harness.overlays.menuStates.last.level?.peak,
        0.8,
        reason: 'the trailing edge is the newest sample, not the next one',
      );
    });

    test('reopening the sheet pushes the level again', () async {
      // The dedupe must not survive the sheet it belongs to, or a reopened
      // sheet would sit on its opening snapshot until the level happened to
      // change.
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);
      const InputLevel level = InputLevel(peak: 0.4, rms: 0.3);
      await emit(harness, level);
      await harness.viewModel.closeInputMenu();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);
      final int before = harness.overlays.menuStates.length;

      await emit(harness, level);

      expect(harness.overlays.menuStates.length, greaterThan(before));
      expect(harness.overlays.menuStates.last.level?.peak, 0.4);
    });
  });

  group('choosing', () {
    test('a device is selected and the live capture follows it', () async {
      final TestHarness harness = await recording();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);

      harness.overlays.menuController.add(
        const InputMenuSelection(
          kind: MediaDeviceKind.microphone,
          deviceId: 'mic:mv7',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        harness.viewModel.deviceSelectionFor(MediaDeviceKind.microphone)?.id,
        'mic:mv7',
      );
      expect(
        harness.recorder.liveDevices[MediaDeviceKind.microphone],
        'mic:mv7',
        reason: 'a choice that only reached the next recording is not a choice',
      );
      expect(harness.viewModel.openMenuKind, isNull);
    });

    test(
      'System default clears the id and still swaps the live capture',
      () async {
        final TestHarness harness = await recording();
        await harness.viewModel.selectInputDevice(
          MediaDeviceKind.microphone,
          harness.viewModel
              .devicesFor(MediaDeviceKind.microphone)
              .firstWhere((MediaDevice d) => d.id == 'mic:mv7'),
        );
        harness.recorder.liveDevices.clear();

        harness.overlays.menuController.add(
          const InputMenuSelection(kind: MediaDeviceKind.microphone),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          harness.viewModel.deviceSelectionFor(MediaDeviceKind.microphone),
          isNull,
        );
        expect(
          harness.recorder.liveDevices.containsKey(MediaDeviceKind.microphone),
          isTrue,
        );
        expect(
          harness.recorder.liveDevices[MediaDeviceKind.microphone],
          isNull,
        );
      },
    );

    test('Off goes through the same toggle the strip button raises', () async {
      final TestHarness harness = await recording();

      harness.overlays.menuController.add(
        const InputMenuSelection(kind: MediaDeviceKind.microphone, off: true),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(harness.recorder.calls, contains('setMicrophoneEnabled(false)'));
    });

    test('Off on an input that is already off does nothing', () async {
      final TestHarness harness = await recording();
      // The camera is off by default.
      harness.overlays.menuController.add(
        const InputMenuSelection(kind: MediaDeviceKind.camera, off: true),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        harness.recorder.calls.where((String c) => c.startsWith('setCamera')),
        isEmpty,
        reason: 'a toggle that fired anyway would turn it back on',
      );
    });

    test(
      'a device that vanished between opening and clicking is re-read',
      () async {
        final TestHarness harness = await recording();

        harness.overlays.menuController.add(
          const InputMenuSelection(
            kind: MediaDeviceKind.microphone,
            deviceId: 'mic:gone',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          harness.recorder.liveDevices,
          isEmpty,
          reason: 'the list the user was reading is the stale thing',
        );
        expect(harness.recorder.calls, contains('getInputDevices(microphone)'));
      },
    );

    test('a swap the platform refuses leaves the recording running', () async {
      final TestHarness harness = await recording();
      harness.recorder.failOnSelectDevice = const RecorderException(
        RecorderErrorCode.microphoneUnavailable,
        'busy',
      );

      harness.overlays.menuController.add(
        const InputMenuSelection(
          kind: MediaDeviceKind.microphone,
          deviceId: 'mic:mv7',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(harness.viewModel.state, isA<SessionActive>());
    });

    test(
      'a choice outside a session changes the next recording only',
      () async {
        final TestHarness harness = await TestHarness.create();
        addTearDown(harness.dispose);
        await harness.initialize();

        harness.overlays.menuController.add(
          const InputMenuSelection(
            kind: MediaDeviceKind.microphone,
            deviceId: 'mic:mv7',
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(harness.recorder.liveDevices, isEmpty);
        expect(
          harness.viewModel.deviceSelectionFor(MediaDeviceKind.microphone)?.id,
          'mic:mv7',
        );
      },
    );
  });

  group('resetting the strip', () {
    test('the remembered position is dropped', () async {
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();
      harness.overlays.reportedStripPosition = const OverlayStripPosition(
        displayId: 'display:1',
        x: 0.3,
        y: 0.4,
      );
      await harness.viewModel.stop();
      expect(harness.settings.settings.stripPosition, isNotNull);

      await harness.viewModel.resetStripPosition();

      expect(harness.settings.settings.stripPosition, isNull);
    });

    test('a strip on screen is re-shown at the default dock', () async {
      final TestHarness harness = await recording();
      harness.overlays.stripPlacements.clear();

      await harness.viewModel.resetStripPosition();

      expect(harness.overlays.stripPlacements.single.position, isNull);
      expect(
        harness.overlays.stripPlacements.single.anchor,
        OverlayAnchor.topCenter,
      );
    });
  });
}
