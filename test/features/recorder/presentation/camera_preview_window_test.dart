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
  Future<_FakeOverlayViewClient> mount(
    WidgetTester tester, {
    required bool matchesCompositedPip,
    Rect? content,
    Size window = const Size(160, 160),
  }) async {
    final _FakeOverlayViewClient client = _FakeOverlayViewClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(
      Center(
        child: SizedBox(
          width: window.width,
          height: window.height,
          child: CameraPreviewWindow(client: client),
        ),
      ),
    );
    client.push(
      CameraPreviewOverlayState(
        matchesCompositedPip: matchesCompositedPip,
        // The Circle preset, in both modes — the host sends the tile's shape
        // whatever the source is, because the file gets it whatever the source
        // is. What the mode decides is the box it is applied to.
        aspectRatio: 16 / 9,
        pipAspectRatio: 1,
        fit: CameraPipFit.cover,
        cornerRadiusRatio: 0.5,
        content: content,
      ),
    );
    // The snapshot crosses a broadcast stream, so it lands in a microtask: one
    // pump delivers it and the second rebuilds with it.
    await tester.pump();
    await tester.pump();
    return client;
  }

  testWidgets('display mode paints no window ground', (
    WidgetTester tester,
  ) async {
    await mount(tester, matchesCompositedPip: true);

    expect(tester.widget<RelayTheme>(find.byType(RelayTheme)).ground, isNull);
  });

  testWidgets('window mode masks the picture and not the panel', (
    WidgetTester tester,
  ) async {
    // §33.5. The tile is composited into the file with the chosen preset
    // whatever the source is, so the preview has to show that shape — but the
    // panel stays a captioned rectangle (design `1e`). A circular *window* is
    // what this replaced, and drawing the whole frame instead made all three
    // presets look identical while the MP4 differed.
    await mount(tester, matchesCompositedPip: false);

    expect(find.text('Camera preview'), findsOneWidget);
    expect(find.byType(BlueprintFrame), findsOneWidget);
    final Finder clip = find.descendant(
      of: find.byType(BlueprintFrame),
      matching: find.byType(ClipRRect),
    );
    expect(clip, findsOneWidget);
    final RenderBox box = tester.renderObject(clip);
    expect(
      box.size.width,
      closeTo(box.size.height, 0.01),
      reason:
          'the Circle preset is 1:1, and the picture is drawn at the '
          'tile’s shape rather than the camera’s',
    );
    expect(
      tester.widget<ClipRRect>(clip).borderRadius,
      BorderRadius.circular(box.size.width * 0.5),
    );
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

  group('the window can be larger than the picture (§33.5)', () {
    // macOS sizes the preview window for all three presets at once and moves it
    // from then on, because a panel driven through `Camera → Square → Camera`
    // can be handed a surface of the wrong size and crash its raster thread
    // (flutter/flutter#185394). The tile is then a rectangle inside it.
    const Size window = Size(300, 200);
    const Rect tile = Rect.fromLTWH(54, 4, 192, 192);

    testWidgets('the picture is drawn at the rectangle it was given', (
      WidgetTester tester,
    ) async {
      await mount(
        tester,
        matchesCompositedPip: true,
        window: window,
        content: tile,
      );

      final RenderBox surface = tester.renderObject(
        find.byType(CameraPreviewSurface),
      );
      expect(surface.size, const Size(192, 192));
      final RenderBox root = tester.renderObject(
        find.byType(CameraPreviewWindow),
      );
      expect(
        surface.localToGlobal(Offset.zero) - root.localToGlobal(Offset.zero),
        const Offset(54, 4),
      );
    });

    testWidgets('a press in the surplus is not a drag of the tile', (
      WidgetTester tester,
    ) async {
      // The surplus is the user's own screen showing through. A drag handle
      // spanning the whole window would take a press meant for whatever is
      // underneath it, and then move a picture that is not under the pointer.
      final _FakeOverlayViewClient client = await mount(
        tester,
        matchesCompositedPip: true,
        window: window,
        content: tile,
      );
      final Offset origin = tester
          .renderObject<RenderBox>(find.byType(CameraPreviewWindow))
          .localToGlobal(Offset.zero);

      final TestGesture outside = await tester.startGesture(
        origin + const Offset(10, 100),
      );
      await outside.moveBy(const Offset(40, 0));
      await outside.up();
      await tester.pump();

      expect(client.moves, 0);

      final TestGesture inside = await tester.startGesture(
        origin + tile.center,
      );
      await inside.moveBy(const Offset(40, 0));
      await inside.up();
      await tester.pump();

      expect(client.moves, 1);
    });

    testWidgets('a host that sends no rectangle still fills its window', (
      WidgetTester tester,
    ) async {
      // Windows, and window mode on both platforms: there the window *is* the
      // picture, and no rectangle is sent.
      await mount(tester, matchesCompositedPip: true, window: window);

      expect(
        tester.renderObject<RenderBox>(find.byType(CameraPreviewSurface)).size,
        window,
      );
    });
  });

  group('the rectangle on the wire', () {
    test('a whole rectangle round-trips', () {
      const CameraPreviewOverlayState state = CameraPreviewOverlayState(
        content: Rect.fromLTWH(54, 4, 192, 192),
      );

      expect(
        CameraPreviewOverlayState.fromMap(state.toMap()).content,
        const Rect.fromLTWH(54, 4, 192, 192),
      );
    });

    test('part of a rectangle is not a rectangle', () {
      // The rule every decoder here follows, and the null a host that has not
      // learned these keys sends: the window is the picture.
      for (final Map<String, Object?> partial in <Map<String, Object?>>[
        <String, Object?>{'contentX': 1.0, 'contentY': 2.0},
        <String, Object?>{
          'contentX': 1.0,
          'contentY': 2.0,
          'contentWidth': 0.0,
          'contentHeight': 10.0,
        },
        <String, Object?>{},
      ]) {
        expect(CameraPreviewOverlayState.fromMap(partial).content, isNull);
      }
    });
  });
}

/// Feeds snapshots the way the host does, without a platform channel.
class _FakeOverlayViewClient implements OverlayViewClient {
  final StreamController<CameraPreviewOverlayState> _preview =
      StreamController<CameraPreviewOverlayState>.broadcast();

  void push(CameraPreviewOverlayState state) => _preview.add(state);

  @override
  Stream<CameraPreviewOverlayState> get cameraPreviewStates => _preview.stream;

  /// How many times the tile asked the host to take over a drag.
  int moves = 0;

  @override
  Future<void> beginMove() async {
    moves++;
  }

  @override
  Future<void> dispose() => _preview.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
