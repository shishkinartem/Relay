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
}
