import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../support/harness.dart';

/// Quitting while a recording is running (§19.1).
///
/// "Quitting mid-recording is an ordinary user action, not a crash. The
/// application stops the capture, closes the devices and finalizes the artefact
/// for §18 recovery **before the process exits**, and that path carries its own
/// test." This is that test.
///
/// The path is `lib/main.dart`'s `AppLifecycleListener(onExitRequested:)` →
/// `CompositionRoot.dispose()` → `RecorderViewModel.dispose()` → the platform's
/// `dispose`. `main()` itself is not constructible in a unit test — it builds
/// the real object graph against the real plugin — so what is exercised here is
/// everything from the view model down, plus the one property `onExitRequested`
/// depends on: that the future it awaits does not complete until the platform
/// has finished.
void main() {
  test('quitting mid-recording tells the platform to let go', () async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.settings.setCameraEnabled(true);
    await harness.viewModel.requestStart();

    await harness.quit();

    // `dispose`, not `stop`: quitting is not finishing. The artefact stays a
    // `.part` for §18 startup recovery, and the platform's own dispose is what
    // aborts the capture and detaches the devices.
    expect(harness.recorder.calls, contains('dispose'));
    expect(harness.recorder.calls, isNot(contains('stop')));
  });

  test('nothing is left holding a device once the quit resolves', () async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.settings.setCameraEnabled(true);
    await harness.viewModel.requestStart();
    // The worst case: a sheet open, so a meter reference is outstanding and the
    // menu window is on screen when the user quits.
    await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);

    await harness.quit();

    final ResourceCensus census = await harness.recorder.debugResourceCensus();
    expect(census.sessionResourcesReleased, isTrue, reason: '$census');
    // Named, because these are the two §19.1 calls a "privacy indicator that
    // stays lit after the user has stopped" comes down to.
    expect(census.cameraSessions, 0);
    expect(census.microphoneSessions, 0);
    expect(census.meteringTaps, 0);
    expect(census.meterSubscriptions, 0);
  });

  test('the quit does not resolve before the platform has', () async {
    // The property `onExitRequested` rests on. It returns
    // `AppExitResponse.exit` as soon as its await completes, so a future that
    // resolves early is the process exiting on top of a capture that is still
    // being closed — which is exactly the crash that orphans `replayd` and
    // leaves the recording indicator lit.
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.viewModel.requestStart();

    final Completer<void> platformIsSlow = Completer<void>();
    harness.recorder.holdDispose = platformIsSlow;

    unawaited(harness.quit());
    bool resolved = false;
    unawaited(harness.viewModel.shutdown.then((_) => resolved = true));
    await pumpEventQueue();
    expect(
      resolved,
      isFalse,
      reason: 'the quit resolved while the platform was still disposing',
    );

    platformIsSlow.complete();
    await harness.viewModel.shutdown;
    expect(resolved, isTrue);
  });

  test('a platform that will not let go still lets the app quit', () async {
    // Never worth hanging the quit over: a user who asked to quit has to be
    // able to, and a platform that refuses is a warning in the log rather than
    // an application that cannot be closed.
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.viewModel.requestStart();
    harness.recorder.failOnDispose = true;

    await expectLater(harness.quit(), completes);
  });

  test('shutdown is safe to await on a view model never disposed', () async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();

    await expectLater(harness.viewModel.shutdown, completes);
  });
}
