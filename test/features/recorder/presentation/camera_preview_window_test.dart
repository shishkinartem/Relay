import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/design_system/design_system.dart';
import 'package:relay/features/recorder/presentation/overlay/camera_preview_window.dart';

/// The camera preview window, in its own Flutter engine (§33.5, design `1p`).
///
/// The one property worth pinning here is the window's own ground. In display
/// mode this window *is* the composited picture-in-picture: the compositor
/// writes the camera into the tile and leaves every pixel around it untouched,
/// so a ground painted here is a square of near-white on the user's screen
/// around a circular tile. That is what it drew.
void main() {
  Future<void> mount(
    WidgetTester tester, {
    required bool matchesCompositedPip,
  }) async {
    final _FakeOverlayViewClient client = _FakeOverlayViewClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(
      Center(
        child: SizedBox(
          width: 160,
          height: 160,
          child: CameraPreviewWindow(client: client),
        ),
      ),
    );
    client.push(
      CameraPreviewOverlayState(
        matchesCompositedPip: matchesCompositedPip,
        aspectRatio: 16 / 9,
        fit: matchesCompositedPip ? CameraPipFit.cover : CameraPipFit.contain,
        cornerRadiusRatio: matchesCompositedPip ? 0.5 : 0,
      ),
    );
    // The snapshot crosses a broadcast stream, so it lands in a microtask: one
    // pump delivers it and the second rebuilds with it.
    await tester.pump();
    await tester.pump();
  }

  testWidgets('display mode paints no window ground', (
    WidgetTester tester,
  ) async {
    await mount(tester, matchesCompositedPip: true);

    expect(tester.widget<RelayTheme>(find.byType(RelayTheme)).ground, isNull);
  });

  testWidgets('window mode keeps its ground', (WidgetTester tester) async {
    // There the preview is a captioned panel in its own right, not a stand-in
    // for something in the file (design `1e`).
    await mount(tester, matchesCompositedPip: false);

    expect(
      tester.widget<RelayTheme>(find.byType(RelayTheme)).ground,
      isNotNull,
    );
  });
}

/// Feeds snapshots the way the host does, without a platform channel.
class _FakeOverlayViewClient implements OverlayViewClient {
  final StreamController<CameraPreviewOverlayState> _preview =
      StreamController<CameraPreviewOverlayState>.broadcast();

  void push(CameraPreviewOverlayState state) => _preview.add(state);

  @override
  Stream<CameraPreviewOverlayState> get cameraPreviewStates => _preview.stream;

  @override
  Future<void> beginMove() async {}

  @override
  Future<void> dispose() => _preview.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
