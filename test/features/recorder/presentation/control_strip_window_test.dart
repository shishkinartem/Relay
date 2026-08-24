import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/features/recorder/presentation/overlay/control_strip_window.dart';

/// A control strip in its own window measures itself so the host window can be
/// resized to fit it exactly. The measurement must be of the strip's *natural*
/// size — measuring it inside the window it already lives in makes the two
/// clamp each other, and the strip can never grow — and it must be repeated
/// whenever the window stops matching it, because the host re-applies its own
/// requested size every time the strip is shown again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Records every `contentSize` the strip reports, and lets the test push
  /// states in as the host would.
  late List<Size> reported;
  late OverlayViewClient client;

  setUp(() {
    reported = <Size>[];
    const MethodChannel channel = MethodChannel(RecorderChannels.overlayView);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          if (call.method == 'contentSize') {
            final Map<Object?, Object?> args =
                call.arguments as Map<Object?, Object?>;
            reported.add(
              Size(args['width']! as double, args['height']! as double),
            );
          }
          return null;
        });
    client = OverlayViewClient(channel: channel);
  });

  tearDown(() async {
    await client.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(RecorderChannels.overlayView),
          null,
        );
  });

  /// Pushes a state to the strip the way the platform host does.
  Future<void> push(WidgetTester tester, RecordingOverlayState state) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          RecorderChannels.overlayView,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('controlStripState', state.toMap()),
          ),
          (ByteData? _) {},
        );
    await tester.pumpAndSettle();
  }

  /// The window the host actually gave the strip, deliberately narrower than
  /// the strip needs. This is the real situation on every show: the placement
  /// asks for a nominal size and only the measurement corrects it.
  void undersizedWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 46);
    tester.view.devicePixelRatio = 1;
  }

  testWidgets('the strip reports its natural size, not the window it is in', (
    WidgetTester tester,
  ) async {
    undersizedWindow(tester);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ControlStripWindow(client: client));
    await tester.pumpAndSettle();

    await push(
      tester,
      const RecordingOverlayState(elapsed: Duration(seconds: 12)),
    );
    expect(reported, isNotEmpty, reason: 'the strip must report its size');
    // The point of the regression: the report must exceed the window it was
    // measured in, not be clamped to it.
    expect(reported.last.width, greaterThan(360));
  });

  testWidgets('pausing does not change the size the strip asks for', (
    WidgetTester tester,
  ) async {
    undersizedWindow(tester);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ControlStripWindow(client: client));
    await push(
      tester,
      const RecordingOverlayState(elapsed: Duration(seconds: 12)),
    );
    final Size recording = reported.last;

    await push(
      tester,
      const RecordingOverlayState(
        elapsed: Duration(seconds: 12),
        isPaused: true,
      ),
    );

    // A strip that grew on pause would resize its always-on-top window on the
    // exact click the user is making, moving Resume and Stop out from under
    // the cursor. Both state-dependent slots are reserved at their widest, so
    // the strip is one size for the whole session.
    expect(reported.last.width, recording.width);
    expect(reported.last.height, recording.height);
  });

  testWidgets('every control stays inside the reported size', (
    WidgetTester tester,
  ) async {
    undersizedWindow(tester);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ControlStripWindow(client: client));
    await push(
      tester,
      const RecordingOverlayState(
        elapsed: Duration(seconds: 12),
        isPaused: true,
      ),
    );

    final Size strip = reported.last;
    // Resume and Stop are the two controls that fell outside the window in the
    // bug this test exists for: with the strip clipped, a paused recording
    // could not be resumed or stopped.
    for (final String label in <String>['Resume', 'Stop']) {
      final Finder control = find.bySemanticsLabel(label);
      expect(control, findsOneWidget, reason: '$label must be rendered');
      final Rect box = tester.getRect(control);
      expect(
        box.right,
        lessThanOrEqualTo(strip.width + 0.5),
        reason: '$label must sit inside the window the strip asked for',
      );
      expect(box.bottom, lessThanOrEqualTo(strip.height + 0.5));
    }
  });

  testWidgets('the size is reported again when the host resets the window', (
    WidgetTester tester,
  ) async {
    undersizedWindow(tester);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ControlStripWindow(client: client));
    await push(
      tester,
      const RecordingOverlayState(elapsed: Duration(seconds: 12)),
    );
    final Size measured = reported.last;

    // The host resized its window to what the strip asked for.
    tester.view.physicalSize = measured;
    await tester.pumpAndSettle();
    final int settled = reported.length;

    // A second recording: `showControlStrip` re-applies the placement's own
    // requested size. The strip's content has not changed, so a size-only
    // guard would report nothing and leave Pause and Stop outside the window.
    tester.view.physicalSize = const Size(360, 46);
    await tester.pumpAndSettle();

    expect(
      reported.length,
      greaterThan(settled),
      reason: 'the strip must ask for its size again when the window shrinks',
    );
    expect(reported.last, measured);
  });
}
