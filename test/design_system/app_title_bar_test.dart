import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/design_system/design_system.dart';

/// `.tb` — what the window header reserves on its leading edge.
///
/// It shipped as a hardcoded 78, the room macOS's traffic lights take on a
/// transparent full-size title bar, and no caller could say otherwise. On a
/// host that keeps its own caption the Flutter view starts below it, so those
/// 78 points were a dead gap down the left of every screen — which is what the
/// first Windows run drew.
void main() {
  /// The header row's own padding, read off the widget rather than measured on
  /// screen: what is asserted is the room the design system reserves.
  EdgeInsets headerPadding(WidgetTester tester) {
    final Container header = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(AppTitleBar),
            matching: find.byType(Container),
          )
          .first,
    );
    return header.padding! as EdgeInsets;
  }

  Future<void> pumpHeader(
    WidgetTester tester, {
    double? hostInset,
    double? leadingInset,
  }) async {
    final Widget header = AppTitleBar(
      title: 'Recorder',
      leadingInset: leadingInset,
    );
    await tester.pumpWidget(
      RelayTheme(
        child: hostInset == null
            ? header
            : AppWindowChrome(titleBarLeadingInset: hostInset, child: header),
      ),
    );
  }

  test('the inset tokens are the design values, not a widget literal', () {
    // `.tb { padding: 0 11px }` in `design/Screen Recorder - Desktop MVP.dc.html`.
    expect(AppSpacing.titleBarPadding, 11);
    expect(AppSpacing.titleBarWindowButtonsInset, 78);
  });

  testWidgets('a host that draws its own title bar leaves only the padding', (
    WidgetTester tester,
  ) async {
    await pumpHeader(tester, hostInset: AppSpacing.titleBarPadding);

    // Symmetrical, because there is nothing of the system's over this row to
    // keep clear of: the caption is above the Flutter view, not on top of it.
    expect(headerPadding(tester).left, AppSpacing.titleBarPadding);
    expect(headerPadding(tester).right, AppSpacing.titleBarPadding);
  });

  testWidgets('a host that overlays its window buttons keeps their room', (
    WidgetTester tester,
  ) async {
    await pumpHeader(tester, hostInset: AppSpacing.titleBarWindowButtonsInset);

    expect(headerPadding(tester).left, AppSpacing.titleBarWindowButtonsInset);
  });

  testWidgets('an overlay window overrides the host, having no chrome at all', (
    WidgetTester tester,
  ) async {
    // A property of that window rather than of the machine: the control strip
    // and the input menu are frameless whatever the host does (§6, §33.4).
    await pumpHeader(
      tester,
      hostInset: AppSpacing.titleBarWindowButtonsInset,
      leadingInset: 0,
    );

    expect(headerPadding(tester).left, 0);
  });

  testWidgets('with no host to ask, the reservation stands', (
    WidgetTester tester,
  ) async {
    // The documented fallback. The trees with no scope above them are the ones
    // with no host window — a widget test and the design-review renders, whose
    // canvas draws the buttons into this row exactly as macOS does.
    await pumpHeader(tester);

    expect(headerPadding(tester).left, AppSpacing.titleBarWindowButtonsInset);
  });
}
