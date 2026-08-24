import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/settings/app_settings.dart';
import 'package:relay/features/recorder/domain/session_state.dart';
import 'package:relay/features/recorder/presentation/preflight_screen.dart';

import '../../../support/fakes.dart';
import '../../../support/harness.dart';

/// The blocking preflight has one job: name the thing standing in the way and
/// offer the action that can change it. Which action that is depends on a
/// distinction the operating system does not make for us — never asked, asked
/// and awaiting a relaunch, refused, blocked by policy, or not asked at all
/// because the platform could not be reached. Offering the wrong one is how
/// this screen used to send a first-run user to a privacy list that does not
/// contain the application yet.
void main() {
  late TestHarness harness;

  Future<TestHarness> blockedBy(
    PermissionStatus screenRecording, {
    bool launchedByThisApp = true,
    bool failOnCheck = false,
  }) => TestHarness.create(
    recorder: FakeRecorder(
      capabilities: RecorderCapabilities(
        qualities: const <RecordingQuality>{RecordingQuality.fullHd1080},
        supportedFrameRates: const <int>{30},
        supportedSourceTypes: const <CaptureSourceType>{
          CaptureSourceType.display,
        },
        supportsCamera: true,
        supportsMicrophone: true,
        supportsSystemAudio: true,
        supportsPause: true,
        supportsCursorCapture: true,
        supportsHardwareEncoding: true,
        platformName: 'fake',
        screenRecordingNeedsRelaunch: true,
        screenRecordingLaunchedByThisApp: launchedByThisApp,
      ),
    ),
    permissions: FakeRecorderPermissions(
      statuses: <PermissionKind, PermissionStatus>{
        PermissionKind.screenRecording: screenRecording,
        PermissionKind.microphone: PermissionStatus.granted,
        PermissionKind.camera: PermissionStatus.granted,
      },
    )..failOnCheck = failOnCheck,
  );

  Future<void> showBlocking(WidgetTester tester) async {
    await harness.viewModel.initialize();
    expect(harness.viewModel.state, isA<SessionPreflight>());
    await tester.pumpWidget(
      harness.wrap(
        PreflightScreen(state: harness.viewModel.state as SessionPreflight),
      ),
    );
    await tester.pumpAndSettle();
  }

  tearDown(() async => harness.dispose());

  testWidgets('an unanswered permission offers the system prompt', (
    WidgetTester tester,
  ) async {
    harness = await blockedBy(PermissionStatus.notDetermined);
    await showBlocking(tester);

    expect(find.text('Allow screen recording…'), findsOneWidget);
    expect(find.text('Not asked yet'), findsOneWidget);

    await tester.tap(find.text('Allow screen recording…'));
    await tester.pumpAndSettle();
    expect(
      harness.permissions.calls,
      contains('request(screenRecording)'),
      reason: 'the primary action must raise the real system prompt',
    );
  });

  testWidgets('the privacy pane stays reachable even before asking', (
    WidgetTester tester,
  ) async {
    // The application is not in that privacy list until it has asked, so this
    // is deliberately not the primary action. It is still offered, because the
    // stored "already asked" flag can be wrong in either direction — resetting
    // the system's privacy database clears its answer but not our memory of
    // asking — and a screen carrying only the button that cannot work is the
    // dead end this flow keeps producing.
    harness = await blockedBy(PermissionStatus.notDetermined);
    await showBlocking(tester);

    expect(find.text('Open System Settings'), findsOneWidget);
    await tester.tap(find.text('Open System Settings'));
    await tester.pumpAndSettle();
    expect(
      harness.permissions.calls,
      contains('openSystemSettings(screenRecording)'),
    );
  });

  testWidgets('an answer awaiting a relaunch is not reported as a refusal', (
    WidgetTester tester,
  ) async {
    // The regression this screen exists for: the platform cannot show the
    // answer to a prompt raised in this process, and calling that "Not granted"
    // told a user who had just pressed Allow that they had refused.
    harness = await blockedBy(PermissionStatus.pendingRelaunch);
    await showBlocking(tester);

    expect(find.text('Restart to apply'), findsOneWidget);
    expect(find.text('Not granted'), findsNothing);
    expect(find.text('Quit and reopen Relay'), findsOneWidget);

    await tester.tap(find.text('Quit and reopen Relay'));
    await tester.pumpAndSettle();
    expect(harness.permissions.calls, contains('relaunchApplication'));
  });

  testWidgets(
    'a refused permission offers the pane and a re-ask, not a relaunch',
    (WidgetTester tester) async {
      harness = await blockedBy(PermissionStatus.denied);
      await showBlocking(tester);

      expect(find.text('Open System Settings'), findsOneWidget);
      expect(
        find.text(
          'macOS offers to quit and reopen Relay when you switch it on.',
        ),
        findsOneWidget,
        reason:
            'this is the one blocking state where the privacy pane raises its '
            'own Quit & Reopen, and a screen that repeats the offer without '
            'saying so reads as if the app needed asking twice',
      );
      expect(
        find.text('Quit and reopen Relay'),
        findsNothing,
        reason:
            'the privacy pane raises its own Quit & Reopen when Relay is switched '
            'on, so repeating the offer here asks the user to do what the system '
            'has already asked them',
      );
      expect(
        find.text('Ask the system anyway'),
        findsOneWidget,
        reason:
            'the stored flag can say "asked" when the system has no answer, and '
            'that user needs a way back to the prompt',
      );
      expect(
        find.text('Check again'),
        findsNothing,
        reason:
            're-reading in this process cannot show an answer the platform only '
            'applies to a fresh one',
      );

      await tester.tap(find.text('Open System Settings'));
      await tester.pumpAndSettle();
      expect(
        harness.permissions.calls,
        contains('openSystemSettings(screenRecording)'),
      );
    },
  );

  testWidgets('the refused state still reaches a relaunch through the prompt', (
    WidgetTester tester,
  ) async {
    // Dropping the relaunch button from `refused` is only safe because of this
    // path. A user who chose "Later" in the system's own Quit & Reopen comes
    // back to a permission that is granted and a process that cannot see it;
    // asking again makes the platform answer `pendingRelaunch`, which is the
    // state that does offer the relaunch. Without this the removal would be a
    // dead end, so it is the test that guards the decision.
    harness = await blockedBy(PermissionStatus.denied);
    await showBlocking(tester);

    harness.permissions.statuses[PermissionKind.screenRecording] =
        PermissionStatus.pendingRelaunch;
    await tester.tap(find.text('Ask the system anyway'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      harness.wrap(
        PreflightScreen(state: harness.viewModel.state as SessionPreflight),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Restart to apply'), findsOneWidget);
    expect(
      find.text('Quit and reopen Relay'),
      findsOneWidget,
      reason: 'the remedy has to remain reachable, one step further along',
    );
  });

  testWidgets('a policy-blocked permission offers no restart', (
    WidgetTester tester,
  ) async {
    harness = await blockedBy(PermissionStatus.restricted);
    await showBlocking(tester);

    expect(find.text('Blocked by policy'), findsOneWidget);
    expect(
      find.text('Quit and reopen Relay'),
      findsNothing,
      reason: 'restarting cannot change a policy, so it must not be offered',
    );
    expect(find.text('Allow screen recording…'), findsNothing);
  });

  testWidgets('a platform that cannot be asked says so, and offers a retry', (
    WidgetTester tester,
  ) async {
    // An unreachable platform and a first run read identically in the report —
    // every kind comes back notDetermined — so without this the user is offered
    // a prompt that will fail exactly the same way, silently, forever.
    harness = await blockedBy(
      PermissionStatus.notDetermined,
      failOnCheck: true,
    );
    await showBlocking(tester);

    expect(find.text('Unknown'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Allow screen recording…'), findsNothing);
  });

  testWidgets('a launch the system attributes elsewhere explains itself', (
    WidgetTester tester,
  ) async {
    harness = await blockedBy(
      PermissionStatus.notDetermined,
      launchedByThisApp: false,
    );
    await showBlocking(tester);

    expect(find.text('Given to another app'), findsOneWidget);
    expect(
      find.text('Quit and reopen Relay'),
      findsOneWidget,
      reason:
          'reopening through the launcher is what repairs the attribution, so '
          'it is the remedy, not merely a suggestion to quit',
    );
    expect(find.text('Quit Relay'), findsOneWidget);
  });

  testWidgets('Check again re-reads the permission and leaves the preflight', (
    WidgetTester tester,
  ) async {
    harness = await blockedBy(PermissionStatus.denied);
    await harness.viewModel.initialize();
    expect(harness.viewModel.state, isA<SessionPreflight>());

    // The user grants it outside the process, which is the only place it can be
    // granted, and comes back.
    harness.permissions.statuses[PermissionKind.screenRecording] =
        PermissionStatus.granted;
    await harness.viewModel.refreshPermissionsAndSources();

    expect(
      harness.viewModel.state,
      isNot(isA<SessionPreflight>()),
      reason: 'a granted permission ends the blocking preflight',
    );
  });

  testWidgets(
    'a still-refused re-check restates the preflight, not stale data',
    (WidgetTester tester) async {
      harness = await blockedBy(PermissionStatus.notDetermined);
      await harness.viewModel.initialize();
      final SessionPreflight before =
          harness.viewModel.state as SessionPreflight;
      expect(
        before.report[PermissionKind.screenRecording],
        PermissionStatus.notDetermined,
      );

      // The user answered the prompt with "Don't Allow" in an earlier run.
      harness.permissions.statuses[PermissionKind.screenRecording] =
          PermissionStatus.denied;
      await harness.viewModel.refreshPermissionsAndSources();

      final SessionPreflight after =
          harness.viewModel.state as SessionPreflight;
      expect(
        after.report[PermissionKind.screenRecording],
        PermissionStatus.denied,
        reason:
            'the screen must show the answer just read, or the user is offered '
            'an action for a state that no longer holds',
      );
    },
  );

  group('degraded (design 1d)', () {
    Future<void> showDegraded(WidgetTester tester) async {
      harness = await TestHarness.create(
        settings: const AppSettings(cameraEnabled: true),
        permissions: FakeRecorderPermissions(
          statuses: <PermissionKind, PermissionStatus>{
            PermissionKind.screenRecording: PermissionStatus.granted,
            PermissionKind.microphone: PermissionStatus.granted,
            PermissionKind.camera: PermissionStatus.denied,
          },
        ),
      );
      await harness.initialize();
      await harness.viewModel.requestStart();
      await tester.pumpWidget(
        harness.wrap(
          PreflightScreen(state: harness.viewModel.state as SessionPreflight),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the primary action says what it will do', (
      WidgetTester tester,
    ) async {
      await showDegraded(tester);

      expect(find.text('Record without camera'), findsOneWidget);
      expect(
        find.text('Start recording'),
        findsNothing,
        reason:
            'a screen reached from a button labelled "Start recording" cannot '
            'explain itself with the same words',
      );
      expect(find.text('This recording will have no camera.'), findsOneWidget);
    });

    testWidgets('Back leaves the preflight without recording', (
      WidgetTester tester,
    ) async {
      await showDegraded(tester);

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(harness.viewModel.state, isNot(isA<SessionPreflight>()));
      expect(
        harness.recorder.calls,
        isNot(contains('start')),
        reason: 'declining a preflight must not start anything',
      );
    });
  });

  testWidgets('no internal vocabulary reaches the screen', (
    WidgetTester tester,
  ) async {
    // `cameraEnabled = false — not required for this session` and `§4.3` were
    // shipped copy. The user is not reading the source.
    harness = await blockedBy(PermissionStatus.notDetermined);
    await harness.viewModel.initialize();

    for (final PermissionStatus status in <PermissionStatus>[
      PermissionStatus.notDetermined,
      PermissionStatus.denied,
      PermissionStatus.pendingRelaunch,
      PermissionStatus.restricted,
    ]) {
      await tester.pumpWidget(
        harness.wrap(
          PreflightScreen(
            state: SessionPreflight(
              report: PermissionReport(<PermissionKind, PermissionStatus>{
                PermissionKind.screenRecording: status,
                PermissionKind.microphone: PermissionStatus.granted,
                PermissionKind.camera: PermissionStatus.granted,
              }),
              blockingDenials: const <PermissionKind>{
                PermissionKind.screenRecording,
              },
              source: FakeRecorder.defaultSources.first,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      for (final Text text in tester.widgetList<Text>(find.byType(Text))) {
        final String value = text.data ?? '';
        expect(value, isNot(contains('=')), reason: 'in state ${status.name}');
        expect(value, isNot(contains('§')), reason: 'in state ${status.name}');
      }
    }
  });
}
