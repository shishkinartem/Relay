import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/settings/app_settings.dart';
import 'package:relay/design_system/design_system.dart';
import 'package:relay/features/recorder/presentation/launch_screen.dart';

import '../../../support/fakes.dart';
import '../../../support/harness.dart';

/// The launch screen's input rows: On / Off on the row, everything else behind
/// a disclosure (§33.2).
///
/// The two things worth locking in are that the closed screen is still the
/// screen that shipped, and that a meter never outlives the section that shows
/// it — a tap left open holds a real microphone.
void main() {
  Future<TestHarness> mount(
    WidgetTester tester, {
    FakeRecorder? recorder,
    AppSettings settings = const AppSettings(),
  }) async {
    await loadDesignFonts();
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final TestHarness harness = await TestHarness.create(
      recorder: recorder,
      settings: settings,
    );
    addTearDown(harness.dispose);
    await harness.initialize();

    await tester.pumpWidget(harness.wrap(const LaunchScreen()));
    await tester.pumpAndSettle();
    return harness;
  }

  Finder disclosureFor(String label) =>
      find.bySemanticsLabel('$label settings');

  testWidgets('details are closed by default, and On/Off is still on the row', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await mount(tester);

    expect(find.text('Microphone'), findsOneWidget);
    expect(
      find.byType(AppSelectField),
      findsNothing,
      reason: 'closed, this is the screen that shipped',
    );
    expect(find.byType(AppLevelMeter), findsNothing);
    expect(harness.recorder.metering, isEmpty);
  });

  testWidgets('opening the microphone names its device and meters it', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await mount(tester);

    await tester.tap(disclosureFor('Microphone').first);
    await tester.pumpAndSettle();

    expect(find.text('MacBook Pro Microphone'), findsOneWidget);
    expect(find.byType(AppLevelMeter), findsOneWidget);
    expect(harness.recorder.metering, <MediaDeviceKind>{
      MediaDeviceKind.microphone,
    });
  });

  testWidgets('closing the section closes the tap it opened', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await mount(tester);

    await tester.tap(disclosureFor('Microphone').first);
    await tester.pumpAndSettle();
    expect(harness.recorder.metering, isNotEmpty);

    await tester.tap(disclosureFor('Microphone').first);
    await tester.pumpAndSettle();

    expect(
      harness.recorder.metering,
      isEmpty,
      reason: 'a meter nobody is looking at must not hold a microphone',
    );
  });

  testWidgets('turning the input off closes the tap too', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await mount(
      tester,
      settings: const AppSettings(
        expandedInputs: <MediaDeviceKind>{MediaDeviceKind.microphone},
      ),
    );
    expect(harness.recorder.metering, isNotEmpty);

    await tester.tap(find.text('Off').first);
    await tester.pumpAndSettle();

    expect(harness.recorder.metering, isEmpty);
  });

  testWidgets('system audio has no meter, on any platform', (
    WidgetTester tester,
  ) async {
    await mount(
      tester,
      settings: const AppSettings(
        expandedInputs: <MediaDeviceKind>{MediaDeviceKind.systemAudio},
      ),
    );

    // The level of an output the user can neither choose nor change is not
    // something they can act on (§33.2).
    expect(find.byType(AppLevelMeter), findsNothing);
  });

  testWidgets('choosing a device records it and remembers it', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await mount(
      tester,
      settings: const AppSettings(
        expandedInputs: <MediaDeviceKind>{MediaDeviceKind.microphone},
      ),
    );

    await tester.tap(find.byType(AppSelectField).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shure MV7'));
    await tester.pumpAndSettle();

    expect(
      harness.viewModel.deviceSelectionFor(MediaDeviceKind.microphone)?.id,
      'mic:mv7',
    );
    expect(
      harness.settings.settings.inputDevices[MediaDeviceKind.microphone]?.id,
      'mic:mv7',
      reason: 'the choice outlives the session that made it',
    );
  });

  testWidgets('System default is its own row and clears the choice', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await mount(
      tester,
      settings: const AppSettings(
        expandedInputs: <MediaDeviceKind>{MediaDeviceKind.microphone},
      ),
    );

    await tester.tap(find.byType(AppSelectField).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shure MV7'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(AppSelectField).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('System default'));
    await tester.pumpAndSettle();

    expect(
      harness.viewModel.deviceSelectionFor(MediaDeviceKind.microphone),
      isNull,
    );
    expect(harness.settings.settings.inputDevices, isEmpty);
  });

  testWidgets('an input with nothing to disclose is not a disclosure', (
    WidgetTester tester,
  ) async {
    // macOS: ScreenCaptureKit delivers the whole system mix, so there is no
    // device to name, no list to offer and no level to draw (§33.8). This used
    // to unroll a chevron onto one dead line reading "System mix · not
    // selectable here" — the exact control
    // `docs/adr/2026-08-30-input-device-selection.md` rejected: "a disclosure
    // chevron on a control that cannot disclose anything".
    //
    // The stored open state is deliberately part of the fixture: `expanded`
    // has to be recomputed rather than merely disabled, or a remembered open
    // row unrolls a panel with nothing left on screen to close it.
    await mount(
      tester,
      settings: const AppSettings(
        expandedInputs: <MediaDeviceKind>{MediaDeviceKind.systemAudio},
      ),
    );

    expect(find.text('System audio'), findsOneWidget);
    expect(disclosureFor('System audio'), findsNothing);
    expect(find.byType(AppSelectField), findsNothing);
    expect(find.text('not selectable here'), findsNothing);
    expect(find.text('System mix'), findsNothing);
  });

  testWidgets('the On/Off controls line up, chevron or no chevron', (
    WidgetTester tester,
  ) async {
    // The regression removing the dead chevron introduced: dropping its column
    // outright pulled that row's On/Off 28 points right, so the one row without
    // a chevron jogged sideways out of the column. The chevron is still not
    // drawn — its gutter is simply held open.
    await mount(tester);

    final List<Rect> toggles = tester
        .widgetList<AppOnOffControl>(find.byType(AppOnOffControl))
        .map((AppOnOffControl w) => tester.getRect(find.byWidget(w)))
        .toList();

    expect(toggles.length, greaterThanOrEqualTo(3));
    for (final Rect box in toggles) {
      expect(
        box.right,
        moreOrLessEquals(toggles.first.right, epsilon: 0.5),
        reason: 'every input row ends its control at the same x',
      );
    }
  });

  testWidgets('an input the platform does let you choose keeps its list', (
    WidgetTester tester,
  ) async {
    // Windows: WASAPI loopback is per render endpoint, so system audio is a
    // real choice there and the row must keep the chevron the macOS case
    // loses. Without this the assertion above would be satisfied by deleting
    // the disclosure outright.
    final FakeRecorder recorder =
        FakeRecorder(
            capabilities: const RecorderCapabilities(
              qualities: <RecordingQuality>{
                RecordingQuality.hd720,
                RecordingQuality.fullHd1080,
                RecordingQuality.native,
              },
              supportedFrameRates: <int>{30, 60},
              supportedSourceTypes: <CaptureSourceType>{
                CaptureSourceType.display,
                CaptureSourceType.window,
              },
              // The whole point of the fixture: all three kinds selectable, as
              // `recorder_windows_plugin.cpp` reports.
              selectableDeviceKinds: <MediaDeviceKind>{
                MediaDeviceKind.camera,
                MediaDeviceKind.microphone,
                MediaDeviceKind.systemAudio,
              },
              meterableDeviceKinds: <MediaDeviceKind>{
                MediaDeviceKind.microphone,
              },
              supportsCamera: true,
              supportsMicrophone: true,
              supportsSystemAudio: true,
              supportsPause: true,
              supportsCursorCapture: true,
              supportsHardwareEncoding: true,
              platformName: 'fake-windows',
            ),
          )
          ..devices = <MediaDeviceKind, List<MediaDevice>>{
            MediaDeviceKind.systemAudio: <MediaDevice>[
              const MediaDevice(
                id: 'render:speakers',
                kind: MediaDeviceKind.systemAudio,
                label: 'Speakers',
                isSystemDefault: true,
              ),
            ],
          };

    await mount(
      tester,
      recorder: recorder,
      settings: const AppSettings(
        expandedInputs: <MediaDeviceKind>{MediaDeviceKind.systemAudio},
      ),
    );

    expect(disclosureFor('System audio'), findsWidgets);
    expect(find.text('Speakers'), findsOneWidget);
  });

  testWidgets('a remembered device that is gone is named, not hidden', (
    WidgetTester tester,
  ) async {
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

    await mount(
      tester,
      recorder: recorder,
      settings: const AppSettings(
        expandedInputs: <MediaDeviceKind>{MediaDeviceKind.microphone},
        inputDevices: <MediaDeviceKind, InputDeviceChoice>{
          MediaDeviceKind.microphone: InputDeviceChoice(
            id: 'mic:mv7',
            label: 'Shure MV7',
          ),
        },
      ),
    );

    expect(find.textContaining('Shure MV7'), findsOneWidget);
    expect(find.textContaining('is gone'), findsOneWidget);
  });

  testWidgets('a silent microphone is reported, not left blank', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await mount(
      tester,
      settings: const AppSettings(
        expandedInputs: <MediaDeviceKind>{MediaDeviceKind.microphone},
      ),
    );

    for (int i = 0; i < 80; i++) {
      harness.recorder.emit(
        const RecorderInputLevelEvent(
          MediaDeviceKind.microphone,
          InputLevel.silent,
        ),
      );
    }
    await tester.pumpAndSettle();

    expect(find.text('TEST — NO SOUND'), findsOneWidget);
    expect(find.textContaining('mute switch'), findsOneWidget);
  });

  testWidgets('a level event moves the bar', (WidgetTester tester) async {
    final TestHarness harness = await mount(
      tester,
      settings: const AppSettings(
        expandedInputs: <MediaDeviceKind>{MediaDeviceKind.microphone},
      ),
    );

    harness.recorder.emit(
      const RecorderInputLevelEvent(
        MediaDeviceKind.microphone,
        InputLevel(peak: 0.8, rms: 0.6),
      ),
    );
    await tester.pumpAndSettle();

    final AppLevelMeter meter = tester.widget<AppLevelMeter>(
      find.byType(AppLevelMeter),
    );
    expect(meter.level, closeTo(0.6, 1e-9));
    expect(meter.peak, closeTo(0.8, 1e-9));
    expect(meter.enabled, isTrue);
    expect(find.text('TEST — SPEAK NOW'), findsOneWidget);
  });

  group('the camera tile can be placed before recording (§33.5)', () {
    testWidgets('the camera section offers all four corners', (
      WidgetTester tester,
    ) async {
      // There used to be no placement control of any kind before a recording:
      // the shape could be chosen here and the place could not, and the only
      // corner list lived in the strip's camera sheet, in window mode alone.
      await mount(
        tester,
        settings: const AppSettings(
          expandedInputs: <MediaDeviceKind>{MediaDeviceKind.camera},
        ),
      );

      expect(find.byType(CameraCornerTiles), findsOneWidget);
      for (final CameraOverlayCorner corner in CameraOverlayCorner.values) {
        expect(find.text(corner.label), findsOneWidget);
      }
    });

    testWidgets('the stored corner is the one drawn as chosen', (
      WidgetTester tester,
    ) async {
      await mount(
        tester,
        settings: const AppSettings(
          expandedInputs: <MediaDeviceKind>{MediaDeviceKind.camera},
          cameraPipCorner: CameraOverlayCorner.topLeft,
        ),
      );

      expect(
        tester
            .widget<CameraCornerTiles>(find.byType(CameraCornerTiles))
            .selected,
        CameraOverlayCorner.topLeft,
      );
    });

    testWidgets('choosing one stores it, with no session running', (
      WidgetTester tester,
    ) async {
      final TestHarness harness = await mount(
        tester,
        settings: const AppSettings(
          expandedInputs: <MediaDeviceKind>{MediaDeviceKind.camera},
        ),
      );

      await tester.tap(find.bySemanticsLabel('Top left picture-in-picture'));
      await tester.pumpAndSettle();

      expect(
        harness.settings.settings.cameraPipCorner,
        CameraOverlayCorner.topLeft,
      );
    });

    testWidgets('a display source says the corner is only where it starts', (
      WidgetTester tester,
    ) async {
      // The preview *is* the tile there (design `1p`), so the corner is a
      // starting point and a drag can put it anywhere. Nothing on this screen
      // shows that — the preview only exists once recording has begun — so it
      // is said in words.
      await mount(
        tester,
        settings: const AppSettings(
          expandedInputs: <MediaDeviceKind>{MediaDeviceKind.camera},
        ),
      );

      expect(find.textContaining('Drag it anywhere'), findsOneWidget);
    });

    testWidgets('a window source promises no drag, because there is none', (
      WidgetTester tester,
    ) async {
      // There the preview is a separate captioned object and not the tile
      // (design `1e`): the corner chosen here is the whole answer.
      final FakeRecorder recorder = FakeRecorder();
      final TestHarness harness = await mount(
        tester,
        recorder: recorder,
        settings: const AppSettings(
          expandedInputs: <MediaDeviceKind>{MediaDeviceKind.camera},
        ),
      );
      harness.viewModel.selectSource(
        harness.viewModel.sources.firstWhere(
          (CaptureSource s) => s.type == CaptureSourceType.window,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(CameraCornerTiles), findsOneWidget);
      expect(find.textContaining('Drag it anywhere'), findsNothing);
    });

    testWidgets('a dragged tile is drawn as being in none of the four', (
      WidgetTester tester,
    ) async {
      await mount(
        tester,
        settings: const AppSettings(
          expandedInputs: <MediaDeviceKind>{MediaDeviceKind.camera},
          cameraPipPosition: Offset(0.2, 0.2),
        ),
      );

      expect(
        tester
            .widget<CameraCornerTiles>(find.byType(CameraCornerTiles))
            .selected,
        isNull,
        reason:
            'a dragged tile is in none of them; marking one would say it is',
      );
    });

    testWidgets('choosing a corner is what puts a dragged tile back', (
      WidgetTester tester,
    ) async {
      // There is no `Reset position` button: with the four corners on screen it
      // was a fifth way to say the corner the tile already had.
      final TestHarness harness = await mount(
        tester,
        settings: const AppSettings(
          expandedInputs: <MediaDeviceKind>{MediaDeviceKind.camera},
          cameraPipPosition: Offset(0.2, 0.2),
        ),
      );

      expect(find.text('Reset position'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Lower right picture-in-picture'));
      await tester.pumpAndSettle();

      expect(harness.settings.settings.cameraPipPosition, isNull);
      expect(
        tester
            .widget<CameraCornerTiles>(find.byType(CameraCornerTiles))
            .selected,
        CameraOverlayCorner.bottomRight,
      );
    });
  });
}
