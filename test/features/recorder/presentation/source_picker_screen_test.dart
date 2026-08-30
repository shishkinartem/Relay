import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/design_system/design_system.dart';
import 'package:relay/features/recorder/presentation/source_picker_screen.dart';

import '../../../support/fakes.dart';
import '../../../support/harness.dart';

/// The custom in-application source list (design `1a`, §4.1).
///
/// CLAUDE.md fixes the ordering as an invariant — displays first, then windows
/// — and the whole screen had one executed line out of sixty-five.
void main() {
  Future<TestHarness> mount(
    WidgetTester tester, {
    FakeRecorder? recorder,
  }) async {
    await loadDesignFonts();
    // The panel is a fixed size and the list scrolls inside it. A surface big
    // enough to lay the whole list out is what lets the ordering be asserted
    // by position rather than by hoping the right rows happened to be built.
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final TestHarness harness = await TestHarness.create(recorder: recorder);
    addTearDown(harness.dispose);
    await harness.initialize();

    await tester.pumpWidget(harness.wrap(const SourcePickerScreen()));
    await tester.pumpAndSettle();
    return harness;
  }

  testWidgets('displays are listed before windows', (
    WidgetTester tester,
  ) async {
    await mount(tester);

    // The display card is titled by what it is — "Entire screen" — with the
    // monitor named underneath, so the row is found by its subtitle.
    final double display = tester
        .getTopLeft(find.textContaining('Built-in Display').first)
        .dy;
    expect(tester.getTopLeft(find.text('WINDOWS')).dy, greaterThan(display));
    for (final String window in <String>['Terminal', 'Safari']) {
      expect(
        tester.getTopLeft(find.text(window)).dy,
        greaterThan(display),
        reason: '$window must come after every display',
      );
    }
  });

  testWidgets('the current display is preselected and the action names it', (
    WidgetTester tester,
  ) async {
    // §5: the display holding the main window is the default source, so the
    // common case is one click.
    final TestHarness harness = await mount(tester);

    expect(harness.viewModel.selectedSource?.id, 'display:1');
    expect(find.text('Continue with Built-in Display'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
  });

  testWidgets('choosing a window changes what the action commits to', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await mount(tester);

    await tester.tap(find.text('Terminal'));
    await tester.pumpAndSettle();

    expect(harness.viewModel.selectedSource?.id, 'window:11');
    expect(find.text('Continue with Terminal'), findsOneWidget);
  });

  testWidgets('the quality and frame rate the recording will use are shown', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await mount(tester);

    expect(
      find.text(
        '${harness.viewModel.settings.quality.label} · '
        '${harness.viewModel.settings.frameRate}',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the window grid answers to the width it is given (§33.6)', (
    WidgetTester tester,
  ) async {
    // Fifteen windows in two columns at 420 is a long scroll of small
    // thumbnails on a display with room for four. The columns come from the
    // constraints, never from a platform name (§28).
    await loadDesignFonts();
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();

    double cardWidth(double surfaceWidth) {
      return tester.getSize(find.widgetWithText(SourceCard, 'Terminal')).width;
    }

    for (final (double width, int columns) in <(double, int)>[
      (420, 2),
      (640, 3),
      (900, 4),
    ]) {
      await tester.binding.setSurfaceSize(Size(width, 1400));
      await tester.pumpWidget(harness.wrap(const SourcePickerScreen()));
      await tester.pumpAndSettle();

      const double gap = 14;
      const double padding = 14 * 2;
      final double expected = (width - padding - gap * (columns - 1)) / columns;
      expect(
        cardWidth(width),
        closeTo(expected, 0.5),
        reason: '\$width pt should lay the grid out in \$columns columns',
      );
    }
  });

  testWidgets('a platform with nothing to offer does not offer a source', (
    WidgetTester tester,
  ) async {
    // A source list that came back empty must not leave a Continue button that
    // starts a recording of nothing.
    final FakeRecorder empty = FakeRecorder()..sources = <CaptureSource>[];
    final TestHarness harness = await mount(tester, recorder: empty);

    expect(harness.viewModel.selectedSource, isNull);
    expect(find.text('Select a source'), findsOneWidget);

    final AppButton button = tester.widget<AppButton>(
      find.widgetWithText(AppButton, 'Select a source'),
    );
    expect(button.onPressed, isNull, reason: 'nothing to continue with');
  });

  group('the grid answers to its width (§33.6)', () {
    /// Eight windows, so a row is full at every breakpoint and the column
    /// count is readable from where the cards land rather than inferred.
    FakeRecorder crowded() => FakeRecorder(
      sources: <CaptureSource>[
        const CaptureSource(
          id: 'display:1',
          type: CaptureSourceType.display,
          title: 'Built-in Display',
          subtitle: '2560 × 1600',
          pixelWidth: 2560,
          pixelHeight: 1600,
          isCurrentDisplay: true,
        ),
        for (int i = 0; i < 8; i++)
          CaptureSource(
            id: 'window:$i',
            type: CaptureSourceType.window,
            title: 'Window $i',
            subtitle: 'app $i',
            pixelWidth: 1280,
            pixelHeight: 800,
          ),
      ],
    );

    /// The panel's own padding, which is why a window flips a column later
    /// than §33.6's number: the grid is given the width inside it.
    const double chrome = AppSpacing.panelPadding * 2;

    /// How many cards share the topmost row of the window grid.
    int columnsAt(WidgetTester tester) {
      final List<double> tops = <double>[
        for (int i = 0; i < 8; i++)
          tester.getTopLeft(find.text('Window $i')).dy,
      ];
      final double first = tops.reduce((double a, double b) => a < b ? a : b);
      return tops.where((double t) => (t - first).abs() < 1).length;
    }

    Future<void> mountAt(WidgetTester tester, double width) async {
      await loadDesignFonts();
      await tester.binding.setSurfaceSize(Size(width, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final TestHarness harness = await TestHarness.create(recorder: crowded());
      addTearDown(harness.dispose);
      await harness.initialize();
      await tester.pumpWidget(harness.wrap(const SourcePickerScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('each breakpoint flips exactly where it says it does', (
      WidgetTester tester,
    ) async {
      // One pixel either side of each threshold, which is the only place a
      // breakpoint can be wrong without being obviously wrong.
      for (final (double content, int columns) in <(double, int)>[
        (AppSpacing.wide - 1, 2),
        (AppSpacing.wide, 3),
        (AppSpacing.wider - 1, 3),
        (AppSpacing.wider, 4),
        (AppSpacing.panelMaxWidth - chrome, 4),
      ]) {
        await mountAt(tester, content + chrome);
        expect(
          columnsAt(tester),
          columns,
          reason: '$content pt of content should be $columns columns',
        );
      }
    });

    testWidgets('the panel at its minimum is the reference layout', (
      WidgetTester tester,
    ) async {
      // Below the first breakpoint the screen is the design exactly as drawn,
      // and this is the width the panel opens at.
      await mountAt(tester, AppSpacing.panelWidth);

      expect(columnsAt(tester), 2);
    });

    testWidgets('no width scrolls the panel sideways', (
      WidgetTester tester,
    ) async {
      // §33.6 forbids it outright. An overflow throws in a test, so the
      // assertion is that nothing was thrown at any of the four widths.
      for (final double width in <double>[
        AppSpacing.panelWidth,
        AppSpacing.wide + chrome,
        AppSpacing.wider + chrome,
        AppSpacing.panelMaxWidth,
      ]) {
        await mountAt(tester, width);
        expect(
          tester.takeException(),
          isNull,
          reason: 'an overflow at $width would have thrown',
        );
      }
    });

    test('the breakpoints themselves', () {
      // The one place the widths turn into a number, so a second grid cannot
      // disagree with the first.
      expect(AppSpacing.gridColumns(AppSpacing.wide - 1), 2);
      expect(AppSpacing.gridColumns(AppSpacing.wide), 3);
      expect(AppSpacing.gridColumns(AppSpacing.wider - 1), 3);
      expect(AppSpacing.gridColumns(AppSpacing.wider), 4);
      expect(AppSpacing.gridColumns(4000), 4);
      expect(AppSpacing.gridColumns(0), 2);
    });
  });
}
