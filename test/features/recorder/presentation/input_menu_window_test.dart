import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/design_system/design_system.dart';
import 'package:relay/features/recorder/presentation/overlay/input_menu_window.dart';

import '../../../support/harness.dart';

/// The device sheet a chevron opens, in its own Flutter engine (§33.4).
///
/// What is pinned here is the one thing a press on a row must not do: dismiss
/// the menu on its way in. The dismissal used to be a `Listener` wrapped around
/// the whole window, and a hit-test path holds every `RenderPointerListener`
/// from the pressed row up to the root — `dispatchEvent` calls all of them — so
/// one press fired the row *and* the dismissal. On Windows
/// `OverlayWindows::HideInputMenu` destroys this window and its engine at once,
/// so the pointer-up that completes the tap never arrived: the camera sheet's
/// shape presets could not be chosen at all, and which rows survived was
/// chance. The dismissal is a sibling beneath the sheet now, so only the
/// surplus around it can reach the dismissal.
void main() {
  const InputMenuOverlayState cameraSheet = InputMenuOverlayState(
    kind: MediaDeviceKind.camera,
    title: 'Camera',
    items: <InputMenuItem>[
      InputMenuItem(label: 'System default', meta: 'FaceTime HD Camera'),
      InputMenuItem(id: 'camera:brio', label: 'Logitech Brio'),
      InputMenuItem(label: 'Camera off'),
    ],
    presets: CameraPipPreset.values,
    selectedPreset: CameraPipPreset.camera,
  );

  /// Opens the sheet in a window taller than it needs, which is the window the
  /// host actually gives it: a panel that has already rendered a longer list is
  /// never driven back down
  /// (`docs/adr/2026-08-31-overlay-panels-never-shrink.md`), so there is
  /// surplus below the sheet in an ordinary session.
  Future<_FakeOverlayViewClient> mount(
    WidgetTester tester, {
    InputMenuOverlayState state = cameraSheet,
    Size window = const Size(300, 460),
  }) async {
    await loadDesignFonts();
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final _FakeOverlayViewClient client = _FakeOverlayViewClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(InputMenuWindow(client: client));
    client.push(state);
    // The snapshot crosses a broadcast stream, so it lands in a microtask: one
    // pump delivers it and the second rebuilds with it.
    await tester.pump();
    await tester.pump();
    return client;
  }

  testWidgets('a press on a shape preset chooses it and nothing else', (
    WidgetTester tester,
  ) async {
    final _FakeOverlayViewClient client = await mount(tester);

    await tester.tap(find.text('Square'));
    await tester.pump();

    expect(
      client.calls,
      <String>['chooseCameraPreset(square)'],
      reason:
          'a dismissal on the same press destroys this engine before the '
          'pointer-up, which is why the presets were unpickable on Windows',
    );
  });

  testWidgets('a press on a device row chooses it and nothing else', (
    WidgetTester tester,
  ) async {
    final _FakeOverlayViewClient client = await mount(tester);

    await tester.tap(find.text('Logitech Brio'));
    await tester.pump();

    expect(client.calls, <String>['chooseInputDevice(camera:brio)']);
  });

  testWidgets('a press in the surplus below the sheet still dismisses', (
    WidgetTester tester,
  ) async {
    // The surplus is the user's own screen showing through, so it cannot
    // silently eat clicks: this window floats over whatever is being recorded.
    final _FakeOverlayViewClient client = await mount(tester);
    final Rect sheet = tester.getRect(find.byType(InputMenuSheet));

    await tester.tapAt(Offset(sheet.center.dx, sheet.bottom + 40));
    await tester.pump();

    expect(client.calls, <String>['dismissInputMenu']);
  });

  testWidgets('the sheet is still measured at its natural size', (
    WidgetTester tester,
  ) async {
    // The host sizes the window from this report, so the layer added under the
    // sheet must not become something the sheet is measured inside: a window
    // the host opened too small would then be confirmed at that size and clip
    // its own last row.
    final _FakeOverlayViewClient client = await mount(
      tester,
      window: const Size(120, 60),
    );

    expect(client.sizes, isNotEmpty);
    expect(client.sizes.last.width, InputMenuSheet.width);
    expect(
      client.sizes.last.height,
      tester.getSize(find.byType(InputMenuSheet)).height,
    );
    expect(client.sizes.last.height, greaterThan(60));
  });
}

/// Feeds snapshots the way the host does, and records what the sheet sent back
/// in the order it was sent — the ordering is the defect.
class _FakeOverlayViewClient implements OverlayViewClient {
  final StreamController<InputMenuOverlayState> _menu =
      StreamController<InputMenuOverlayState>.broadcast();

  final List<String> calls = <String>[];
  final List<Size> sizes = <Size>[];

  void push(InputMenuOverlayState state) => _menu.add(state);

  @override
  Stream<InputMenuOverlayState> get inputMenuStates => _menu.stream;

  @override
  Future<void> reportContentSize(double width, double height) async {
    sizes.add(Size(width, height));
  }

  @override
  Future<void> dismissInputMenu() async {
    calls.add('dismissInputMenu');
  }

  @override
  Future<void> chooseInputDevice(
    MediaDeviceKind kind, {
    String? deviceId,
    bool off = false,
  }) async {
    calls.add('chooseInputDevice(${off ? 'off' : deviceId})');
  }

  @override
  Future<void> chooseCameraPreset(
    MediaDeviceKind kind,
    CameraPipPreset preset,
  ) async {
    calls.add('chooseCameraPreset(${preset.name})');
  }

  @override
  Future<void> chooseCameraCorner(
    MediaDeviceKind kind,
    CameraOverlayCorner corner,
  ) async {
    calls.add('chooseCameraCorner(${corner.name})');
  }

  @override
  Future<void> dispose() => _menu.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
