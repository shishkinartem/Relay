import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_macos/recorder_macos.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:recorder_windows/recorder_windows.dart';
import 'package:relay/app/app_scope.dart';
import 'package:relay/app/relay_app.dart';
import 'package:relay/core/environment/app_environment.dart';
import 'package:relay/design_system/design_system.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

/// The host's window chrome, from the registered platform to a rendered header.
///
/// The join is the part that broke: `AppTitleBar` reserved 78 points for
/// macOS's traffic lights, every caller took the default, and nothing anywhere
/// asked the host whether it drew its own title bar. The screen tests all mount
/// `RelayHome` under the harness, so none of them went through the shell that
/// is supposed to answer that question — and on Windows the reservation shipped
/// as a dead gap on the leading edge.
///
/// So this mounts [RelayApp] itself against a registered platform, which is the
/// only path that carries the answer.
class _FakePlatform extends RecorderPlatform {
  _FakePlatform(this.windowChrome);

  @override
  final WindowChrome windowChrome;

  @override
  late final Recorder recorder = FakeRecorder();

  @override
  late final RecorderPermissions permissions = FakeRecorderPermissions();

  @override
  late final OverlayWindowController overlays = FakeOverlayWindowController();
}

void main() {
  late RecorderPlatform registered;

  setUp(() {
    registered = RecorderPlatform.instance;
  });

  tearDown(() {
    RecorderPlatform.instance = registered;
  });

  /// What the launch screen's header reserves when [chrome] is what the
  /// registered platform reports.
  Future<double> renderedInset(WidgetTester tester, WindowChrome chrome) async {
    RecorderPlatform.instance = _FakePlatform(chrome);
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);

    await tester.pumpWidget(
      RelayApp(
        scope: (Widget child) => AppScope(
          recorder: harness.viewModel,
          settings: harness.settings,
          destinations: harness.destinations,
          environment: const AppEnvironment(<String, String>{}),
          logger: harness.logger,
          child: child,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final Container header = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(AppTitleBar),
            matching: find.byType(Container),
          )
          .first,
    );
    return (header.padding! as EdgeInsets).left;
  }

  testWidgets('a separate title bar leaves the header its own padding', (
    WidgetTester tester,
  ) async {
    expect(
      await renderedInset(tester, WindowChrome.separateTitleBar),
      AppSpacing.titleBarPadding,
    );
  });

  testWidgets('overlaid window buttons keep the room they take', (
    WidgetTester tester,
  ) async {
    expect(
      await renderedInset(tester, WindowChrome.overlaidWindowButtons),
      AppSpacing.titleBarWindowButtonsInset,
    );
  });

  test('each shipped platform reports the window its runner makes', () {
    // The two halves of the fix, stated where a change to either runner has to
    // come past them. `macos/Runner/MainFlutterWindow.swift` makes the title
    // bar full-size and transparent; `windows/runner/win32_window.cpp` creates
    // a plain WS_OVERLAPPEDWINDOW and puts the view in the client rect.
    //
    // Imported here rather than in `lib/`, which is where
    // `test/architecture_test.dart` keeps the plugins out.
    expect(RecorderMacos().windowChrome, WindowChrome.overlaidWindowButtons);
    expect(RecorderWindows().windowChrome, WindowChrome.separateTitleBar);

    // The ordinary window is the default, so a platform only has to speak up
    // when its runner does something to the title bar.
    expect(
      UnsupportedRecorderPlatform().windowChrome,
      WindowChrome.separateTitleBar,
    );
  });
}
