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

  testWidgets('an input the platform cannot choose between offers no list', (
    WidgetTester tester,
  ) async {
    // macOS: ScreenCaptureKit delivers the system mix, so there is no endpoint
    // to pick and the field is drawn fixed rather than tappable (§33.8).
    await mount(
      tester,
      settings: const AppSettings(
        expandedInputs: <MediaDeviceKind>{MediaDeviceKind.systemAudio},
      ),
    );

    final AppSelectField field = tester.widget<AppSelectField>(
      find.byType(AppSelectField).first,
    );
    expect(field.onPressed, isNull);
    expect(find.text('not selectable here'), findsOneWidget);
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
    expect(find.textContaining('was not found'), findsOneWidget);
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
    expect(find.textContaining('hardware switch'), findsOneWidget);
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
}
