import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/design_system/design_system.dart';
import 'package:relay/features/recorder/application/overlay_presenter.dart';

import '../../../support/fakes.dart';
import '../../../support/harness.dart';

/// The host's first guess at the sheet's height, against what the sheet is.
///
/// This is not cosmetics. A panel driven to one size and then back to a size it
/// recently left can be handed a surface of the wrong size out of the engine's
/// back-buffer cache; the render target built from it has no colour attachment,
/// and the raster thread dereferences null — flutter/flutter#185394, which this
/// project hit as a hard crash during a recording. The host remembers a
/// measured size per content shape so the correction happens once, and this
/// estimate is what the *first* show lands on. Every section the estimate
/// forgets is a correction that did not have to happen.
void main() {
  /// The sheet's real height, laid out exactly as the overlay engine lays it
  /// out: at its natural size, unconstrained by the window it is going into.
  Future<double> measure(
    WidgetTester tester,
    InputMenuOverlayState state,
  ) async {
    await loadDesignFonts();
    final GlobalKey key = GlobalKey();
    await tester.pumpWidget(
      RelayTheme(
        child: Align(
          alignment: Alignment.topLeft,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            minHeight: 0,
            maxHeight: double.infinity,
            child: InputMenuSheet(
              key: key,
              state: state,
              onChoose: (_) {},
              onChoosePreset: (_) {},
              onChooseCorner: (_) {},
            ),
          ),
        ),
      ),
    );
    return tester.getSize(find.byKey(key)).height;
  }

  late OverlayPresenter presenter;

  setUp(() {
    presenter = OverlayPresenter(overlays: FakeOverlayWindowController());
  });

  /// How far the estimate may miss before the panel is corrected twice. The
  /// host's own resize check ignores half a point, so anything larger is a
  /// second size.
  const double tolerance = 6;

  const List<InputMenuItem> devices = <InputMenuItem>[
    InputMenuItem(label: 'System default', meta: 'Shure MV7', selected: true),
    InputMenuItem(id: 'mic:mv7', label: 'Shure MV7', meta: 'USB'),
    InputMenuItem(id: 'mic:builtin', label: 'Built-in', meta: 'built-in'),
    InputMenuItem(label: 'Microphone off'),
  ];

  final Map<String, InputMenuOverlayState> shapes =
      <String, InputMenuOverlayState>{
        'a microphone list': const InputMenuOverlayState(
          kind: MediaDeviceKind.microphone,
          title: 'Microphone',
          items: devices,
        ),
        'a microphone list with its meter': const InputMenuOverlayState(
          kind: MediaDeviceKind.microphone,
          title: 'Microphone',
          items: devices,
          level: InputLevel(peak: 0.6, rms: 0.4),
        ),
        'a microphone list with a meter and a notice':
            const InputMenuOverlayState(
              kind: MediaDeviceKind.microphone,
              title: 'Microphone',
              items: devices,
              level: InputLevel(peak: 0.6, rms: 0.4),
              notice: '“Shure MV7” was not found · using the default',
            ),
        'a list still loading': const InputMenuOverlayState(
          kind: MediaDeviceKind.microphone,
          title: 'Microphone',
          loading: true,
        ),
        'nothing found': const InputMenuOverlayState(
          kind: MediaDeviceKind.microphone,
          title: 'Microphone',
          emptyMessage: 'No microphone found',
        ),
        'a camera sheet with its presets': const InputMenuOverlayState(
          kind: MediaDeviceKind.camera,
          title: 'Camera',
          items: <InputMenuItem>[
            InputMenuItem(label: 'System default', meta: 'FaceTime HD Camera'),
            InputMenuItem(id: 'camera:brio', label: 'Logitech Brio'),
            InputMenuItem(label: 'Camera off'),
          ],
          presets: CameraPipPreset.values,
          selectedPreset: CameraPipPreset.circle,
        ),
        'a camera sheet in window mode': const InputMenuOverlayState(
          kind: MediaDeviceKind.camera,
          title: 'Camera',
          items: <InputMenuItem>[
            InputMenuItem(label: 'System default', meta: 'FaceTime HD Camera'),
            InputMenuItem(label: 'Camera off'),
          ],
          presets: CameraPipPreset.values,
          corners: CameraOverlayCorner.values,
          selectedCorner: CameraOverlayCorner.bottomRight,
        ),
      };

  shapes.forEach((String name, InputMenuOverlayState state) {
    testWidgets('the estimate matches $name', (WidgetTester tester) async {
      final double measured = await measure(tester, state);
      final double estimated = presenter.estimatedMenuSize(state).height;

      expect(
        estimated,
        closeTo(measured, tolerance),
        reason:
            'the host would open this sheet at $estimated and be corrected to '
            '$measured — a second size, which is what feeds the crash',
      );
    });
  });

  testWidgets('the width is the design’s, whatever is in it', (
    WidgetTester tester,
  ) async {
    for (final InputMenuOverlayState state in shapes.values) {
      await measure(tester, state);
      expect(
        presenter.estimatedMenuSize(state).width,
        OverlayPresenter.inputMenuWidth,
      );
    }
  });
}
