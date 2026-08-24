import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/design_system/design_system.dart';
import 'package:relay/design_system/icons/svg_path_parser.dart';

import '../support/harness.dart';

Widget host(Widget child, {Size size = const Size(420, 560)}) => RelayTheme(
  child: MediaQuery(
    data: MediaQueryData(size: size),
    child: Center(child: child),
  ),
);

void main() {
  group('tokens are ported from the stylesheet', () {
    test('the accent, ground and ink are the design system values', () {
      expect(AppColors.background, const Color(0xFFF2F2F3));
      expect(AppColors.surface, const Color(0xFFE9E9EA));
      expect(AppColors.text, const Color(0xFF1D1F20));
      expect(AppColors.accent, const Color(0xFF5980A6));
      // `color-mix(in srgb, #1d1f20 16%, transparent)`.
      expect(AppColors.divider.a, closeTo(0.16, 0.005));
    });

    test('components use the overridden radius of 0, not the token ramp', () {
      expect(AppRadius.none, 0);
      expect(AppRadius.md, 4);
    });

    test('typography is Barlow Condensed over Barlow', () {
      expect(AppTypography.h4.fontFamily, 'Barlow Condensed');
      expect(AppTypography.button.fontFamily, 'Barlow Condensed');
      expect(AppTypography.body.fontFamily, 'Barlow');
      expect(AppTypography.bodySmall.fontFamily, 'Barlow');
    });
  });

  group('RelayTheme', () {
    testWidgets('supplies a direction, so an overlay engine can render', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const RelayTheme(child: Text('x')));
      final BuildContext context = tester.element(find.text('x'));
      expect(Directionality.of(context), TextDirection.ltr);
      expect(DefaultTextStyle.of(context).style.fontFamily, 'Barlow');
    });
  });

  group('AppButton', () {
    testWidgets('reports as a button and fires once per tap', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      await tester.pumpWidget(
        host(AppButton(label: 'Send', onPressed: () => taps++)),
      );
      await tester.tap(find.text('Send'));
      expect(taps, 1);
      expect(
        tester.getSemantics(find.byType(AppButton)),
        matchesSemantics(
          label: 'Send',
          isButton: true,
          isEnabled: true,
          hasEnabledState: true,
          hasTapAction: true,
          hasFocusAction: true,
          isFocusable: true,
        ),
      );
    });

    testWidgets('a null callback disables it and swallows taps', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(const AppButton(label: 'Send')));
      await tester.tap(find.text('Send'), warnIfMissed: false);
      expect(tester.takeException(), isNull);
    });

    testWidgets('busy blocks activation', (WidgetTester tester) async {
      int taps = 0;
      await tester.pumpWidget(
        host(AppButton(label: 'Send', busy: true, onPressed: () => taps++)),
      );
      await tester.tap(find.text('Send'), warnIfMissed: false);
      expect(taps, 0);
    });
  });

  group('AppSegmentedControl', () {
    testWidgets('selecting an option reports the value once', (
      WidgetTester tester,
    ) async {
      final List<int> changes = <int>[];
      await tester.pumpWidget(
        host(
          AppSegmentedControl<int>(
            value: 30,
            onChanged: changes.add,
            segments: const <AppSegment<int>>[
              AppSegment<int>(value: 30, label: '30'),
              AppSegment<int>(value: 60, label: '60'),
            ],
          ),
        ),
      );
      await tester.tap(find.text('60'));
      expect(changes, <int>[60]);
    });

    testWidgets('a disabled segment cannot be chosen', (
      WidgetTester tester,
    ) async {
      final List<int> changes = <int>[];
      await tester.pumpWidget(
        host(
          AppSegmentedControl<int>(
            value: 30,
            onChanged: changes.add,
            segments: const <AppSegment<int>>[
              AppSegment<int>(value: 30, label: '30'),
              AppSegment<int>(value: 120, label: '120', enabled: false),
            ],
          ),
        ),
      );
      await tester.tap(find.text('120'), warnIfMissed: false);
      expect(changes, isEmpty);
    });

    testWidgets('the on/off control maps to booleans', (
      WidgetTester tester,
    ) async {
      final List<bool> changes = <bool>[];
      await tester.pumpWidget(
        host(
          AppOnOffControl(
            semanticLabel: 'Microphone',
            value: true,
            onChanged: changes.add,
          ),
        ),
      );
      await tester.tap(find.text('Off'));
      expect(changes, <bool>[false]);
    });
  });

  group('RecordingControlStrip', () {
    testWidgets('renders the recording state and raises each intent', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final List<String> intents = <String>[];
      await tester.pumpWidget(
        host(
          RecordingControlStrip(
            elapsed: const Duration(minutes: 14, seconds: 32),
            isPaused: false,
            microphoneEnabled: true,
            cameraEnabled: false,
            systemAudioEnabled: true,
            onToggleMicrophone: () => intents.add('mic'),
            onToggleCamera: () => intents.add('camera'),
            onToggleSystemAudio: () => intents.add('audio'),
            onPauseOrResume: () => intents.add('pause'),
            onStop: () => intents.add('stop'),
          ),
          size: const Size(700, 200),
        ),
      );

      expect(find.text('00:14:32'), findsOneWidget);
      // The paused slots are laid out in every state so the strip keeps one
      // width, but only the active layer reaches the user: nothing announces
      // `Paused` or `Resume` while the session is recording.
      expect(find.bySemanticsLabel('Paused'), findsNothing);
      expect(find.bySemanticsLabel('Resume'), findsNothing);

      await tester.tap(find.bySemanticsLabel('Microphone on'));
      await tester.tap(find.bySemanticsLabel('Camera off'));
      await tester.tap(find.bySemanticsLabel('System audio on'));
      await tester.tap(find.bySemanticsLabel('Pause'));
      await tester.tap(find.bySemanticsLabel('Stop'));
      expect(intents, <String>['mic', 'camera', 'audio', 'pause', 'stop']);
    });

    testWidgets('the paused state shows Resume and holds the timer', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      await tester.pumpWidget(
        host(
          const RecordingControlStrip(
            elapsed: Duration(minutes: 14, seconds: 32),
            isPaused: true,
            microphoneEnabled: false,
            cameraEnabled: false,
            systemAudioEnabled: true,
          ),
          size: const Size(760, 200),
        ),
      );
      expect(find.bySemanticsLabel('Resume'), findsOneWidget);
      expect(find.bySemanticsLabel('Pause'), findsNothing);
      expect(find.text('00:14:32'), findsOneWidget);
    });

    testWidgets('the strip is the same size recording and paused', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      Future<Size> measure({required bool paused}) async {
        await tester.pumpWidget(
          host(
            RecordingControlStrip(
              elapsed: const Duration(minutes: 14, seconds: 32),
              isPaused: paused,
              microphoneEnabled: true,
              cameraEnabled: false,
              systemAudioEnabled: true,
            ),
            size: const Size(760, 200),
          ),
        );
        await tester.pumpAndSettle();
        return tester.getSize(find.byType(RecordingControlStrip));
      }

      final Size recording = await measure(paused: false);
      final Size paused = await measure(paused: true);
      // The strip sizes its own always-on-top window. If pausing changed that
      // size, the window would be resized on the very click that paused it and
      // every control to the right of the cursor would move (§6, design `1g`).
      expect(paused, recording);
    });

    testWidgets('pause and resume are the same square in the same place', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final List<String> intents = <String>[];
      Future<Rect> control({required bool paused}) async {
        await tester.pumpWidget(
          host(
            RecordingControlStrip(
              elapsed: Duration.zero,
              isPaused: paused,
              microphoneEnabled: true,
              cameraEnabled: false,
              systemAudioEnabled: true,
              onPauseOrResume: () => intents.add('toggle'),
            ),
            size: const Size(760, 200),
          ),
        );
        await tester.pumpAndSettle();
        return tester.getRect(
          find.bySemanticsLabel(paused ? 'Resume' : 'Pause'),
        );
      }

      final Rect recording = await control(paused: false);
      final Rect paused = await control(paused: true);
      // The control the user just pressed must still be under the cursor
      // afterwards — the whole reason the strip does not change shape.
      expect(paused, recording);

      await tester.tap(find.bySemanticsLabel('Resume'));
      expect(intents, <String>['toggle']);
    });

    testWidgets('a press in the gap between two controls still lands', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final List<String> intents = <String>[];
      await tester.pumpWidget(
        host(
          RecordingControlStrip(
            elapsed: Duration.zero,
            isPaused: false,
            microphoneEnabled: true,
            cameraEnabled: false,
            systemAudioEnabled: true,
            onPauseOrResume: () => intents.add('pause'),
            onStop: () => intents.add('stop'),
          ),
          size: const Size(760, 200),
        ),
      );

      final Rect pause = tester.getRect(find.bySemanticsLabel('Pause'));
      final Rect stop = tester.getRect(find.bySemanticsLabel('Stop'));

      // The drawn squares are 32 px with 12 px between them, as designed; the
      // hit targets take that gap and meet in the middle of it, so there is no
      // dead space at all between two controls.
      const double drawn = 32;
      expect(pause.width, closeTo(drawn + RecordingControlStrip.gap, 0.5));
      expect(stop.left - pause.right, closeTo(0, 0.5));

      // Aimed into what looks like the gap: on a strip floating over someone
      // else's work, a click that near a control must reach it, not nothing.
      await tester.tapAt(Offset(pause.right - 2, pause.center.dy));
      await tester.tapAt(Offset(stop.left + 2, stop.center.dy));
      expect(intents, <String>['pause', 'stop']);

      // And the full height of the strip is live, not just the middle 32 px.
      await tester.tapAt(Offset(stop.center.dx, stop.top + 1));
      expect(intents, <String>['pause', 'stop', 'stop']);
    });

    testWidgets('an unavailable input cannot be toggled', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final List<String> intents = <String>[];
      await tester.pumpWidget(
        host(
          RecordingControlStrip(
            elapsed: Duration.zero,
            isPaused: false,
            microphoneEnabled: false,
            cameraEnabled: false,
            systemAudioEnabled: true,
            microphoneAvailable: false,
            onToggleMicrophone: () => intents.add('mic'),
          ),
          size: const Size(700, 200),
        ),
      );
      await tester.tap(
        find.bySemanticsLabel('Microphone off — unavailable'),
        warnIfMissed: false,
      );
      expect(intents, isEmpty);
    });
  });

  group('AppProgressBar', () {
    testWidgets('exposes the confirmed percentage', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 200,
            child: AppProgressBar(value: 0.62, semanticLabel: 'Upload'),
          ),
        ),
      );
      expect(find.bySemanticsLabel('Upload'), findsOneWidget);
    });

    test('a fraction outside 0..1 is a programming error', () {
      expect(() => AppProgressBar(value: 1.4), throwsAssertionError);
    });
  });

  group('AppDialog', () {
    testWidgets('actions are ordered secondary then primary', (
      WidgetTester tester,
    ) async {
      String? chosen;
      await tester.pumpWidget(
        host(
          AppDialog(
            title: 'Delete this recording?',
            body: '14:32 · 1.02 GB.',
            actions: <Widget>[
              AppButton(label: 'Keep', onPressed: () => chosen = 'keep'),
              AppButton(
                label: 'Delete',
                variant: AppButtonVariant.primary,
                onPressed: () => chosen = 'delete',
              ),
            ],
          ),
        ),
      );
      expect(
        tester.getTopLeft(find.text('Keep')).dx,
        lessThan(tester.getTopLeft(find.text('Delete')).dx),
      );
      await tester.tap(find.text('Delete'));
      expect(chosen, 'delete');
    });
  });

  group('CameraPreviewSurface', () {
    testWidgets('carries no capture-exclusion labels in either mode', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 200,
            height: 140,
            child: CameraPreviewSurface(),
          ),
        ),
      );
      expect(find.text('excluded'), findsNothing);
      expect(find.text('Camera preview'), findsOneWidget);

      // The picture-in-picture preview sits over the user's own screen, so it
      // shows the camera and nothing else — no tag, no caption.
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 126,
            height: 126,
            child: CameraPreviewSurface(matchesCompositedPip: true),
          ),
        ),
      );
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('the preview is mirrored and the flag flips it', (
      WidgetTester tester,
    ) async {
      for (final bool mirrored in <bool>[true, false]) {
        await tester.pumpWidget(
          host(
            SizedBox(
              width: 200,
              height: 140,
              child: CameraPreviewSurface(
                mirrored: mirrored,
                feed: const ColoredBox(color: Color(0xFF000000)),
              ),
            ),
          ),
        );
        final Transform transform = tester.widget<Transform>(
          find.descendant(
            of: find.byType(CameraPreviewSurface),
            matching: find.byType(Transform),
          ),
        );
        expect(transform.transform.entry(0, 0), mirrored ? -1.0 : 1.0);
      }
    });
  });

  group('icon rendering', () {
    test('the SVG parser handles the commands Lucide emits', () {
      // A closed triangle: absolute move, relative line, closepath.
      final ui.Path triangle = parseSvgPath('M0 0 L10 0 l0 10 Z');
      expect(triangle.contains(const Offset(2, 1)), isTrue);
      expect(triangle.contains(const Offset(9, 1)), isTrue);
      expect(triangle.contains(const Offset(1, 9)), isFalse);
    });

    test('an arc segment produces a curve, not a straight line', () {
      // The microphone body's rounded cap.
      final ui.Path arc = parseSvgPath(
        'M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z',
      );
      final Rect bounds = arc.getBounds();
      expect(bounds.width, closeTo(6, 0.5));
      expect(bounds.height, closeTo(13, 0.5));
    });

    test('packed arc flags are read one character at a time', () {
      // `a10 10 0 0 1 0 14.2` has no separator between the two flags.
      final ui.Path path = parseSvgPath('M19.1 4.9a10 10 0 0 1 0 14.2');
      expect(path.getBounds().height, closeTo(14.2, 1.5));
    });

    testWidgets('AppIcon paints at the requested size', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(const AppIcon(AppIcons.record, size: 24)));
      expect(tester.getSize(find.byType(AppIcon)), const Size(24, 24));
    });
  });

  group('DestinationCard', () {
    testWidgets('renders its own capability text and dims when rejected', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 392,
            child: DestinationCard(
              name: 'Telegram',
              account: 'Hosted Bot API',
              note: '50 MB limit — this file is 1.02 GB.',
              selected: false,
              accepted: false,
              badge: 'Too large',
              badgeTone: AppTagTone.outline,
              onSelected: _noop,
            ),
          ),
        ),
      );
      expect(find.text('Too large'), findsOneWidget);
      expect(find.textContaining('50 MB limit'), findsOneWidget);
      final Opacity opacity = tester.widget<Opacity>(
        find
            .descendant(
              of: find.byType(DestinationCard),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(opacity.opacity, lessThan(1));
    });
  });

  group('camera picture-in-picture geometry (§7)', () {
    test('the defaults are the accepted ADR values', () {
      const CameraOverlayConfiguration configuration =
          CameraOverlayConfiguration();
      expect(configuration.widthRatio, 0.16);
      expect(configuration.aspectRatio, closeTo(16 / 9, 0.0001));
      expect(configuration.followsSourceAspectRatio, isTrue);
      expect(configuration.cornerRadius, 0);
      expect(configuration.marginRatio, 0.01);
      expect(configuration.corner, CameraOverlayCorner.bottomRight);
      expect(configuration.mirrorPreview, isTrue);
      expect(configuration.mirrorOutput, isFalse);
    });

    test('the rectangle is resolved from ratios at any canvas size', () {
      const CameraOverlayConfiguration configuration =
          CameraOverlayConfiguration();
      for (final Size canvas in <Size>[
        const Size(1280, 720),
        const Size(1920, 1080),
        const Size(1152, 720),
      ]) {
        final Rect rect = configuration.resolveRect(
          canvas.width,
          canvas.height,
        );
        expect(rect.width, closeTo(canvas.width * 0.16, 0.001));
        expect(
          rect.width / rect.height,
          closeTo(16 / 9, 0.001),
          reason: 'the fallback shape when no camera frame has arrived',
        );
        expect(rect.right, closeTo(canvas.width - canvas.width * 0.01, 0.001));
        expect(
          rect.bottom,
          closeTo(canvas.height - canvas.width * 0.01, 0.001),
        );
      }
    });

    test('the tile takes the camera\'s own shape, so nothing is cropped', () {
      const CameraOverlayConfiguration configuration =
          CameraOverlayConfiguration();
      for (final double camera in <double>[16 / 9, 4 / 3, 1, 3 / 2]) {
        final Rect rect = configuration.resolveRect(
          1920,
          1080,
          sourceAspectRatio: camera,
        );
        // Same width at every camera shape — only the height follows, so the
        // frame is neither squeezed into a fixed tile nor cropped to fill one.
        expect(rect.width, closeTo(1920 * 0.16, 0.001));
        expect(rect.width / rect.height, closeTo(camera, 0.001));
        expect(rect.right, closeTo(1920 - 19.2, 0.001));
        expect(rect.bottom, closeTo(1080 - 19.2, 0.001));
      }
    });

    test('following the source can be turned off', () {
      const CameraOverlayConfiguration square = CameraOverlayConfiguration(
        aspectRatio: 1,
        followsSourceAspectRatio: false,
      );
      final Rect rect = square.resolveRect(
        1920,
        1080,
        sourceAspectRatio: 16 / 9,
      );
      expect(rect.height, closeTo(rect.width, 0.001));
    });

    test('the corner is configuration, not a constant', () {
      const CameraOverlayConfiguration topLeft = CameraOverlayConfiguration(
        corner: CameraOverlayCorner.topLeft,
      );
      final Rect rect = topLeft.resolveRect(1000, 500);
      expect(rect.left, closeTo(10, 0.001));
      expect(rect.top, closeTo(10, 0.001));
    });
  });

  group('canvas policy (§10)', () {
    test('a 16:9 source fills the preset exactly', () {
      const VideoCompositionConfiguration configuration =
          VideoCompositionConfiguration();
      expect(
        configuration.resolveCanvasSize(
          sourceWidth: 1920,
          sourceHeight: 1080,
          quality: RecordingQuality.hd720,
        ),
        const Size(1280, 720),
      );
    });

    test('a 16:10 source keeps its shape and is not cropped', () {
      const VideoCompositionConfiguration configuration =
          VideoCompositionConfiguration();
      final Size canvas = configuration.resolveCanvasSize(
        sourceWidth: 2560,
        sourceHeight: 1600,
        quality: RecordingQuality.hd720,
      );
      expect(canvas.height, 720);
      expect(canvas.width / canvas.height, closeTo(1.6, 0.01));
    });

    test('an ultrawide source stays inside the preset budget', () {
      const VideoCompositionConfiguration configuration =
          VideoCompositionConfiguration();
      final Size canvas = configuration.resolveCanvasSize(
        sourceWidth: 3440,
        sourceHeight: 1440,
        quality: RecordingQuality.fullHd1080,
      );
      expect(canvas.width, lessThanOrEqualTo(1920));
      expect(canvas.height, lessThanOrEqualTo(1080));
      expect(canvas.width / canvas.height, closeTo(3440 / 1440, 0.01));
    });

    test('dimensions are always even for H.264', () {
      const VideoCompositionConfiguration configuration =
          VideoCompositionConfiguration();
      for (final (int, int) source in <(int, int)>[
        (1365, 767),
        (999, 333),
        (3, 3),
      ]) {
        final Size canvas = configuration.resolveCanvasSize(
          sourceWidth: source.$1,
          sourceHeight: source.$2,
          quality: RecordingQuality.fullHd1080,
        );
        expect(canvas.width % 2, 0);
        expect(canvas.height % 2, 0);
      }
    });

    test('a source smaller than the preset is never upscaled', () {
      const VideoCompositionConfiguration configuration =
          VideoCompositionConfiguration();
      expect(
        configuration.resolveCanvasSize(
          sourceWidth: 640,
          sourceHeight: 360,
          quality: RecordingQuality.fullHd1080,
        ),
        const Size(640, 360),
      );
    });

    test('the letterbox policy holds the reference canvas', () {
      const VideoCompositionConfiguration configuration =
          VideoCompositionConfiguration(
            aspectRatioPolicy: AspectRatioPolicy.letterboxIntoReferenceCanvas,
          );
      expect(
        configuration.resolveCanvasSize(
          sourceWidth: 2560,
          sourceHeight: 1600,
          quality: RecordingQuality.hd720,
        ),
        const Size(1280, 720),
      );
    });
  });
}

void _noop() {}
