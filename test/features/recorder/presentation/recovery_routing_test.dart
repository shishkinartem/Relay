import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/app/relay_app.dart';
import 'package:relay/features/post_recording/presentation/ready_screen.dart';
import 'package:relay/features/recorder/domain/session_state.dart';
import 'package:relay/features/recorder/presentation/preflight_screen.dart';
import 'package:relay/features/recorder/presentation/recovery_screen.dart';
import 'package:relay/features/recorder/presentation/transient_screens.dart';

import '../../../support/fakes.dart';
import '../../../support/harness.dart';

/// Where the recovery screen belongs in the router (§18, design `1n`).
///
/// §18 asks for the unfinished artefact to be found *at startup*, and the
/// screen that offers it is a launch screen. The check used to sit ahead of the
/// session-state switch, so it outranked every other screen — and because the
/// recorder re-scans after each stop, an artefact some earlier crash left
/// behind came back mid-session and took the window away from the recording the
/// user was making and from the file the stop had just produced.
///
/// Gating it on idle would have been the opposite mistake. A launch is not
/// always idle: where screen recording has never been granted, `initialize`
/// scans and then raises the blocking preflight (§23), so the offer has to
/// survive that state too — and that machine is the one most likely to be
/// holding a `.part`. So both launch states are covered here, and both states
/// that own a file of their own are covered as refusals.
void main() {
  /// A session whose recordings folder already holds an unfinished `.part`,
  /// exactly as a crashed earlier run leaves one.
  ///
  /// [screenRecording] is what the platform says about the one permission
  /// there is no recording without; the launch state follows from it, because
  /// `initialize` scans and then raises the blocking preflight.
  Future<TestHarness> harnessWithArtifact({
    PermissionStatus screenRecording = PermissionStatus.granted,
  }) async {
    final Directory directory = Directory.systemTemp.createTempSync(
      'relay_recovery_route_',
    );
    File('${directory.path}${Platform.pathSeparator}recording-3c9d02.part')
        .writeAsBytesSync(List<int>.filled(4096, 3));
    final TestHarness harness = await TestHarness.create(
      directory: directory,
      permissions: FakeRecorderPermissions(
        statuses: <PermissionKind, PermissionStatus>{
          PermissionKind.screenRecording: screenRecording,
          PermissionKind.microphone: PermissionStatus.granted,
          PermissionKind.camera: PermissionStatus.granted,
        },
      ),
    );
    addTearDown(harness.dispose);
    await harness.initialize();
    return harness;
  }

  /// `pumpAndSettle` cannot be used while a transient screen is up: it draws an
  /// indeterminate [AppProgressBar], whose controller repeats forever, so the
  /// tree never settles.
  Future<void> pumpFrames(WidgetTester tester, [int frames = 6]) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  testWidgets('an artefact found at launch is offered on the launch screen', (
    WidgetTester tester,
  ) async {
    await loadDesignFonts();
    final TestHarness harness = await harnessWithArtifact();

    await tester.pumpWidget(harness.wrap(const RelayHome()));
    await tester.pumpAndSettle();

    expect(harness.viewModel.state, isA<SessionIdle>());
    expect(harness.viewModel.hasRecoverableArtifacts, isTrue);
    expect(find.byType(RecoveryScreen), findsOneWidget);
  });

  testWidgets('and on a first launch, before the screen grant', (
    WidgetTester tester,
  ) async {
    // The launch state is not always idle. `initialize` scans for artefacts
    // and then calls `_presentBlockingPermissionIfNeeded`, so a machine that
    // has never granted screen recording is already in the blocking preflight
    // (§23, design `1d`) before the first frame is built. Gating the offer on
    // idle alone hid it on exactly the machine most likely to be holding a
    // `.part`: recovery finalizes a file the previous process wrote, captures
    // nothing, and needs no grant to do it.
    await loadDesignFonts();
    final TestHarness harness = await harnessWithArtifact(
      screenRecording: PermissionStatus.denied,
    );
    expect(harness.viewModel.state, isA<SessionPreflight>());

    await tester.pumpWidget(harness.wrap(const RelayHome()));
    await tester.pumpAndSettle();

    expect(find.byType(RecoveryScreen), findsOneWidget);
    expect(find.byType(PreflightScreen), findsNothing);

    // And the preflight is not lost behind it: once the artefact is answered
    // for, the window goes back to the state that owns it, which still has
    // something to say.
    harness.viewModel.keepArtifacts();
    await tester.pumpAndSettle();

    expect(find.byType(PreflightScreen), findsOneWidget);
    expect(find.byType(RecoveryScreen), findsNothing);
  });

  testWidgets('a live recording keeps the screen it is on', (
    WidgetTester tester,
  ) async {
    await loadDesignFonts();
    final TestHarness harness = await harnessWithArtifact();
    await harness.viewModel.requestStart();

    await tester.pumpWidget(harness.wrap(const RelayHome()));
    await pumpFrames(tester);

    expect(
      harness.viewModel.hasRecoverableArtifacts,
      isTrue,
      reason: 'the artefact is untouched by a session that did not create it',
    );
    expect(find.byType(RecoveryScreen), findsNothing);
    expect(find.byType(TransientScreen), findsOneWidget);
    // AppKicker upper-cases its label.
    expect(find.text('RECORDING'), findsOneWidget);
  });

  testWidgets('and the recording a stop produces is not stolen either', (
    WidgetTester tester,
  ) async {
    await loadDesignFonts();
    final TestHarness harness = await harnessWithArtifact();
    harness.recorder.stopResult = _seed(harness);
    await harness.viewModel.requestStart();

    await tester.pumpWidget(harness.wrap(const RelayHome()));
    await pumpFrames(tester);
    // The stop re-scans the folder, which is what put the older artefact back
    // in front of the file the user just made.
    await harness.viewModel.stop();
    await tester.pumpAndSettle();

    expect(harness.viewModel.hasRecoverableArtifacts, isTrue);
    expect(find.byType(RecoveryScreen), findsNothing);
    expect(find.byType(ReadyScreen), findsOneWidget);
  });
}

/// The finalized file a stop hands back, on disk like the real one.
RecordingFile _seed(TestHarness harness) {
  final File file = File(
    '${harness.directory.path}${Platform.pathSeparator}'
    'recording-8f2a11.mp4',
  )..writeAsBytesSync(List<int>.filled(2048, 7));
  return RecordingFile(
    path: file.path,
    recordingId: '8f2a11',
    sizeBytes: 2048,
    duration: const Duration(minutes: 1, seconds: 12),
    createdAt: DateTime.utc(2026, 8, 22, 14, 22),
    width: 1920,
    height: 1080,
    frameRate: 30,
  );
}
