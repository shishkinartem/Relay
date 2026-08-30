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

  group('RelayTheme (§33.5)', () {
    testWidgets('a null ground paints nothing behind its child', (
      WidgetTester tester,
    ) async {
      // The display-mode camera preview asks for this. Its window is the
      // composited tile, and the compositor leaves every pixel outside the tile
      // untouched — so a ground here is a square of #F2F2F3 on the user's own
      // screen around a circular tile, which is what was photographed.
      for (final (Color? ground, int expected) in <(Color?, int)>[
        (AppColors.background, 1),
        (null, 0),
      ]) {
        await tester.pumpWidget(
          RelayTheme(
            ground: ground,
            child: const SizedBox(width: 40, height: 40),
          ),
        );
        expect(
          find.descendant(
            of: find.byType(RelayTheme),
            matching: find.byWidgetPredicate(
              (Widget w) => w is ColoredBox && w.color == AppColors.background,
            ),
          ),
          findsExactly(expected),
        );
      }
    });

    testWidgets('a null ground still supplies direction and a text style', (
      WidgetTester tester,
    ) async {
      // There is no `WidgetsApp` above an overlay engine, so this is the only
      // provider of either. Dropping the ground must not drop them with it.
      await tester.pumpWidget(
        const RelayTheme(ground: null, child: Text('overlay')),
      );

      expect(tester.widget<Text>(find.text('overlay')), isNotNull);
      expect(
        Directionality.of(tester.element(find.text('overlay'))),
        TextDirection.ltr,
      );
      expect(
        DefaultTextStyle.of(tester.element(find.text('overlay')))
            .style
            .fontFamily,
        AppTypography.body.fontFamily,
      );
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

    testWidgets('the composited tile fills its box in every preset', (
      WidgetTester tester,
    ) async {
      // The bug this locks out: the square preset drew a 1.8 x 1.0 speck in the
      // corner of an otherwise empty window, so the user saw a plain white
      // block with no camera in it. The load-bearing property is *geometry* —
      // that the feed is not degenerate — not which widgets wrap it, because a
      // structural assertion is one a future wrapper can satisfy while
      // reintroducing the collapse.
      //
      // Mounted inside a `Stack`, which is what broke it: a `Stack` loosens the
      // constraints it hands its children, and a `cover` fit sizes itself to
      // its child when the minimums are zero.
      const Key feedKey = Key('feed');
      const Size box = Size(126, 126);

      for (final (String name, CameraPipFit fit, double radius, Widget? feed)
          in <(String, CameraPipFit, double, Widget?)>[
            ('camera', CameraPipFit.contain, 0, null),
            ('square', CameraPipFit.cover, 0, null),
            ('circle', CameraPipFit.cover, 0.5, null),
            (
              'camera · live',
              CameraPipFit.contain,
              0,
              const ColoredBox(key: feedKey, color: Color(0xFF102030)),
            ),
            (
              'square · live',
              CameraPipFit.cover,
              0,
              const ColoredBox(key: feedKey, color: Color(0xFF102030)),
            ),
            (
              'circle · live',
              CameraPipFit.cover,
              0.5,
              const ColoredBox(key: feedKey, color: Color(0xFF102030)),
            ),
          ]) {
        await tester.pumpWidget(
          host(
            Center(
              child: SizedBox.fromSize(
                size: box,
                // The surface is a *non-positioned* child of a `Stack`, so it
                // is handed loosened constraints — 0..126, not 126x126. That is
                // the exact shape that broke it: the frame it used to draw was
                // itself a `Stack`, so the tile inside shrank to the camera's
                // aspect ratio measured in logical pixels and the window was
                // left showing its own background.
                child: Stack(
                  children: <Widget>[
                    CameraPreviewSurface(
                      matchesCompositedPip: true,
                      aspectRatio: 16 / 9,
                      fit: fit,
                      cornerRadiusRatio: radius,
                      feed: feed,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        // The *painted* rect, not the laid-out size: a `cover` fit lays its
        // child out unconstrained at the camera's aspect ratio and then scales
        // it with a transform, so `getSize` reports 1.8 x 1.0 whether the tile
        // is filled or collapsed. `getRect` walks the transform and is
        // therefore the only measurement that can tell the two apart.
        final Size drawn = tester
            .getRect(
              feed == null ? find.byType(HatchedSurface) : find.byKey(feedKey),
            )
            .size;
        if (fit == CameraPipFit.cover) {
          // `cover` crops: the frame is at least the tile in both axes.
          expect(
            drawn.width,
            greaterThanOrEqualTo(box.width - 0.01),
            reason: '$name is $drawn in a $box tile',
          );
          expect(
            drawn.height,
            greaterThanOrEqualTo(box.height - 0.01),
            reason: '$name is $drawn in a $box tile',
          );
        } else {
          // `contain` letterboxes: exactly one axis matches the tile, and the
          // other is the camera's own shape.
          expect(drawn.width, closeTo(box.width, 0.01), reason: name);
          expect(
            drawn.width / drawn.height,
            closeTo(16 / 9, 0.01),
            reason: '$name must not be distorted',
          );
        }
      }
    });

    testWidgets('the composited tile is only the tile — no frame, no ground', (
      WidgetTester tester,
    ) async {
      // Design `1p`: this window *is* the picture-in-picture. The compositor
      // draws no border, no registration marks and nothing behind the camera,
      // so anything drawn here that is not the camera is a mark on the user's
      // screen that never reaches the file.
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 126,
            height: 126,
            child: CameraPreviewSurface(
              matchesCompositedPip: true,
              fit: CameraPipFit.cover,
              feed: ColoredBox(color: Color(0xFF102030)),
            ),
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(CameraPreviewSurface),
          matching: find.byType(BlueprintFrame),
        ),
        findsNothing,
      );
      // Window mode keeps its frame: there it is a captioned object in its own
      // right, not a stand-in for something in the file (design `1e`).
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 200,
            height: 140,
            child: CameraPreviewSurface(
              feed: ColoredBox(color: Color(0xFF102030)),
            ),
          ),
        ),
      );
      expect(
        find.descendant(
          of: find.byType(CameraPreviewSurface),
          matching: find.byType(BlueprintFrame),
        ),
        findsOneWidget,
      );
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

  group('SourceCard', () {
    // §4.1: a source entry exists so the user can tell one of fifteen windows
    // from another. The system duotones photography into the accent, and a
    // capture thumbnail is the one image in the product that must not be
    // recoloured — two blue-washed screenshots look like the same screenshot.
    testWidgets('capture thumbnails are shown in their own colours', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          SourceCard(
            title: 'Terminal',
            subtitle: 'zsh — flutter run',
            selected: false,
            onSelected: () {},
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(SourceCard),
          matching: find.byType(DuotoneFilter),
        ),
        findsNothing,
      );
    });

    testWidgets('the thumbnail is clipped to its slot', (
      WidgetTester tester,
    ) async {
      // `BoxFit.cover` paints outside the box it is given. The clip used to
      // come from `DuotoneFilter`; dropping the wash must not drop the clip.
      await tester.pumpWidget(
        host(
          SourceCard(
            title: 'Terminal',
            subtitle: 'zsh — flutter run',
            selected: false,
            onSelected: () {},
          ),
        ),
      );

      expect(
        find.descendant(
          of: find.byType(SourceCard),
          matching: find.byType(ClipRect),
        ),
        findsOneWidget,
      );
    });
  });

  group('AppDisclosure (§33.2)', () {
    testWidgets('the row control is not part of the disclosure target', (
      WidgetTester tester,
    ) async {
      // The failure this prevents: reaching for Off and opening a panel, or
      // reaching for the details and muting an input.
      int toggles = 0;
      int controlTaps = 0;
      await tester.pumpWidget(
        host(
          AppDisclosure(
            semanticLabel: 'Microphone settings',
            expanded: false,
            onToggle: (_) => toggles++,
            header: const Text('Microphone'),
            headerTrailing: GestureDetector(
              onTap: () => controlTaps++,
              child: const SizedBox(width: 60, height: 24, child: Text('Off')),
            ),
            child: const Text('details'),
          ),
        ),
      );

      await tester.tap(find.text('Off'));
      expect(toggles, 0);
      expect(controlTaps, 1);

      await tester.tap(find.text('Microphone'));
      expect(toggles, 1);
    });

    testWidgets('a closed disclosure builds none of its detail', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          AppDisclosure(
            semanticLabel: 'Microphone settings',
            expanded: false,
            onToggle: (_) {},
            header: const Text('Microphone'),
            child: const Text('details'),
          ),
        ),
      );

      expect(find.text('details'), findsNothing);
    });

    testWidgets('nothing to disclose draws no chevron at all', (
      WidgetTester tester,
    ) async {
      // A control that can never do anything is not a disabled control.
      await tester.pumpWidget(
        host(
          AppDisclosure(
            semanticLabel: 'System audio settings',
            expanded: false,
            enabled: false,
            onToggle: (_) {},
            header: const Text('System audio'),
            child: const Text('details'),
          ),
        ),
      );

      expect(find.byType(AppIcon), findsNothing);
    });
  });

  group('AppLevelMeter (§33.2)', () {
    testWidgets('reports the level it is drawing', (WidgetTester tester) async {
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 200,
            child: AppLevelMeter(
              level: 0.62,
              peak: 0.74,
              semanticLabel: 'Microphone level',
            ),
          ),
        ),
      );

      expect(
        tester.getSemantics(find.byType(AppLevelMeter)),
        matchesSemantics(label: 'Microphone level', value: '62%'),
      );
    });

    testWidgets('a dead meter reports no value, and still occupies its row', (
      WidgetTester tester,
    ) async {
      // Drawn rather than hidden: "off" and "broken" must not look the same,
      // and a control that disappears reads as a layout bug.
      await tester.pumpWidget(
        host(
          const SizedBox(
            width: 200,
            child: AppLevelMeter(
              level: 0,
              peak: 0,
              enabled: false,
              semanticLabel: 'Microphone level',
            ),
          ),
        ),
      );

      expect(find.byType(AppLevelMeter), findsOneWidget);
      expect(tester.getSize(find.byType(AppLevelMeter)).height, 8);
      expect(
        tester.getSemantics(find.byType(AppLevelMeter)),
        matchesSemantics(label: 'Microphone level'),
      );
    });
  });

  group('AppSelectField and AppOptionTile (§33.2)', () {
    testWidgets('a field with nothing to choose is not a button', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          const AppSelectField(
            label: 'System mix',
            meta: 'not selectable here',
            semanticLabel: 'System audio device',
          ),
        ),
      );

      expect(find.text('System mix'), findsOneWidget);
      expect(
        tester.getSemantics(find.byType(AppSelectField)),
        matchesSemantics(
          label: 'System audio device',
          value: 'System mix',
          hasEnabledState: false,
          isReadOnly: true,
        ),
      );
    });

    testWidgets('an option the platform cannot open cannot be chosen', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      await tester.pumpWidget(
        host(
          AppOptionTile(
            label: 'Studio Interface',
            meta: 'in use',
            selected: false,
            enabled: false,
            onPressed: () => taps++,
          ),
        ),
      );

      await tester.tap(find.text('Studio Interface'));
      expect(
        taps,
        0,
        reason: 'shown so its absence is legible, not selectable',
      );
    });
  });

  group('InputMenuSheet (§33.4)', () {
    InputMenuOverlayState state({
      List<InputMenuItem> items = const <InputMenuItem>[],
      bool loading = false,
      String? emptyMessage,
      String? notice,
      InputLevel? level,
    }) => InputMenuOverlayState(
      kind: MediaDeviceKind.microphone,
      title: 'Microphone',
      items: items,
      loading: loading,
      emptyMessage: emptyMessage,
      notice: notice,
      level: level,
    );

    Future<void> mount(
      WidgetTester tester,
      InputMenuOverlayState s, {
      ValueChanged<InputMenuItem>? onChoose,
    }) async {
      await tester.pumpWidget(
        host(InputMenuSheet(state: s, onChoose: onChoose ?? (_) {})),
      );
    }

    testWidgets('a list that is still loading says so, in one row', (
      WidgetTester tester,
    ) async {
      // Never an empty panel, and never a list that appears to have loaded.
      await mount(tester, state(loading: true));

      expect(find.text('Looking for devices…'), findsOneWidget);
      expect(find.byType(AppOptionTile), findsNothing);
    });

    testWidgets('nothing found is said, not left blank', (
      WidgetTester tester,
    ) async {
      await mount(tester, state(emptyMessage: 'No microphone found'));

      expect(find.text('No microphone found'), findsOneWidget);
    });

    testWidgets('a device that cannot be opened cannot be chosen', (
      WidgetTester tester,
    ) async {
      int chosen = 0;
      await mount(
        tester,
        state(
          items: const <InputMenuItem>[
            InputMenuItem(id: 'a', label: 'Shure MV7'),
            InputMenuItem(
              id: 'b',
              label: 'Studio Interface',
              meta: 'in use',
              enabled: false,
            ),
          ],
        ),
        onChoose: (_) => chosen++,
      );

      await tester.tap(find.text('Studio Interface'));
      expect(chosen, 0);

      await tester.tap(find.text('Shure MV7'));
      expect(chosen, 1);
    });

    testWidgets('a lost device is named under the list', (
      WidgetTester tester,
    ) async {
      await mount(
        tester,
        state(
          items: const <InputMenuItem>[InputMenuItem(label: 'System default')],
          notice: '“Shure MV7” was not found · using the default',
        ),
      );

      expect(find.textContaining('was not found'), findsOneWidget);
    });

    testWidgets('the meter appears only when a level is being reported', (
      WidgetTester tester,
    ) async {
      await mount(tester, state());
      expect(find.byType(AppLevelMeter), findsNothing);

      await mount(tester, state(level: const InputLevel(peak: 0.8, rms: 0.6)));
      expect(find.byType(AppLevelMeter), findsOneWidget);
      expect(find.text('TEST — SPEAK NOW'), findsOneWidget);
    });

    testWidgets('a silent level says so rather than reading as working', (
      WidgetTester tester,
    ) async {
      await mount(tester, state(level: InputLevel.silent));

      expect(find.text('TEST — NO SOUND'), findsOneWidget);
    });

    testWidgets('the camera sheet carries the shapes, and raises one', (
      WidgetTester tester,
    ) async {
      // §33.4: the camera's answer to the microphone's meter. Without it the
      // shape could only be chosen before recording started.
      CameraPipPreset? chosen;
      await tester.pumpWidget(
        host(
          InputMenuSheet(
            state: const InputMenuOverlayState(
              kind: MediaDeviceKind.camera,
              title: 'Camera',
              presets: CameraPipPreset.values,
              selectedPreset: CameraPipPreset.square,
            ),
            onChoose: (_) {},
            onChoosePreset: (CameraPipPreset p) => chosen = p,
          ),
        ),
      );

      expect(find.byType(CameraPresetTiles), findsOneWidget);
      await tester.tap(find.text('Circle'));

      expect(chosen, CameraPipPreset.circle);
    });

    testWidgets('a sheet that cannot apply a preset draws none', (
      WidgetTester tester,
    ) async {
      // A dead control on a window floating over someone else's screen is
      // worse than no control: there is nothing to explain why it does nothing.
      await tester.pumpWidget(
        host(
          const InputMenuSheet(
            state: InputMenuOverlayState(
              kind: MediaDeviceKind.camera,
              title: 'Camera',
              presets: CameraPipPreset.values,
              canResetPosition: true,
            ),
            onChoose: _noChoice,
          ),
        ),
      );

      expect(find.byType(CameraPresetTiles), findsNothing);
      expect(find.text('Reset position'), findsNothing);
    });

    testWidgets('window mode offers four named corners instead of a drag', (
      WidgetTester tester,
    ) async {
      // §33.5: with a window source the preview is not the tile, so there is
      // nothing on screen to drag and nothing that would show where a drag had
      // put it. A named corner is legible without a preview.
      CameraOverlayCorner? chosen;
      await tester.pumpWidget(
        host(
          InputMenuSheet(
            state: const InputMenuOverlayState(
              kind: MediaDeviceKind.camera,
              title: 'Camera',
              presets: CameraPipPreset.values,
              corners: CameraOverlayCorner.values,
              selectedCorner: CameraOverlayCorner.bottomRight,
            ),
            onChoose: (_) {},
            onChoosePreset: (_) {},
            onChooseCorner: (CameraOverlayCorner c) => chosen = c,
          ),
        ),
      );

      for (final CameraOverlayCorner corner in CameraOverlayCorner.values) {
        expect(find.text(corner.label), findsOneWidget);
      }
      await tester.tap(find.text('Top left'));

      expect(chosen, CameraOverlayCorner.topLeft);
    });

    testWidgets('a display source is offered no corners at all', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(
          InputMenuSheet(
            state: const InputMenuOverlayState(
              kind: MediaDeviceKind.camera,
              title: 'Camera',
              presets: CameraPipPreset.values,
            ),
            onChoose: (_) {},
            onChoosePreset: (_) {},
            onChooseCorner: (_) {},
          ),
        ),
      );

      expect(find.text('POSITION'), findsNothing);
      expect(find.text('Lower right'), findsNothing);
    });

    testWidgets('Reset position appears only once the tile has moved', (
      WidgetTester tester,
    ) async {
      int reset = 0;
      Future<void> mountCamera({required bool moved}) => tester.pumpWidget(
        host(
          InputMenuSheet(
            state: InputMenuOverlayState(
              kind: MediaDeviceKind.camera,
              title: 'Camera',
              presets: CameraPipPreset.values,
              canResetPosition: moved,
            ),
            onChoose: (_) {},
            onChoosePreset: (_) {},
            onResetPosition: () => reset++,
          ),
        ),
      );

      await mountCamera(moved: false);
      expect(find.text('Reset position'), findsNothing);

      await mountCamera(moved: true);
      await tester.tap(find.text('Reset position'));
      expect(reset, 1);
    });
  });

  group('the strip carets (§33.4)', () {
    testWidgets('a caret is drawn only for an input with a menu', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      await tester.pumpWidget(
        host(
          RecordingControlStrip(
            elapsed: Duration.zero,
            isPaused: false,
            microphoneEnabled: true,
            cameraEnabled: false,
            systemAudioEnabled: true,
            onOpenMicrophoneMenu: (_) {},
            onOpenCameraMenu: (_) {},
          ),
          size: const Size(700, 200),
        ),
      );

      // An input the platform gives no choice about has nothing to disclose,
      // and a control that can never do anything is not a disabled control.
      expect(find.bySemanticsLabel('Choose a microphone'), findsOneWidget);
      expect(find.bySemanticsLabel('Choose a camera'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Choose a system-audio device'),
        findsNothing,
      );
    });

    testWidgets('a caret reports its own centre, in window coordinates', (
      WidgetTester tester,
    ) async {
      // The host places the menu under it and cannot work that out for itself.
      await loadDesignFonts();
      double? anchor;
      await tester.pumpWidget(
        host(
          RecordingControlStrip(
            elapsed: Duration.zero,
            isPaused: false,
            microphoneEnabled: true,
            cameraEnabled: false,
            systemAudioEnabled: true,
            onOpenMicrophoneMenu: (double x) => anchor = x,
          ),
          size: const Size(700, 200),
        ),
      );

      await tester.tap(find.bySemanticsLabel('Choose a microphone'));
      await tester.pump();

      expect(anchor, isNotNull);
      expect(
        anchor,
        closeTo(
          tester.getCenter(find.bySemanticsLabel('Choose a microphone')).dx,
          0.5,
        ),
      );
    });

    testWidgets('pressing a caret does not toggle the input beside it', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      int toggles = 0;
      await tester.pumpWidget(
        host(
          RecordingControlStrip(
            elapsed: Duration.zero,
            isPaused: false,
            microphoneEnabled: true,
            cameraEnabled: false,
            systemAudioEnabled: true,
            onToggleMicrophone: () => toggles++,
            onOpenMicrophoneMenu: (_) {},
          ),
          size: const Size(700, 200),
        ),
      );

      await tester.tap(find.bySemanticsLabel('Choose a microphone'));
      await tester.pump();

      expect(toggles, 0);
    });
  });

  group('camera picture-in-picture geometry (§7)', () {
    test('the defaults are the accepted ADR values', () {
      const CameraOverlayConfiguration configuration =
          CameraOverlayConfiguration();
      expect(configuration.widthRatio, 0.16);
      expect(configuration.aspectRatio, closeTo(16 / 9, 0.0001));
      expect(configuration.followsSourceAspectRatio, isTrue);
      expect(configuration.cornerRadiusRatio, 0);
      expect(configuration.preset, CameraPipPreset.camera);
      expect(configuration.position, isNull);
      expect(configuration.fit, CameraPipFit.contain);
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

/// A sheet whose callbacks are absent is the point of the test above, so this
/// stands in for the one that is required.
void _noChoice(InputMenuItem _) {}
