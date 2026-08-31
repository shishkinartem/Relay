import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../support/harness.dart';

/// §19.1's two census tests.
///
/// **Census equality** — census at launch, ten start → stop cycles, census
/// again, assert equal. **Post-session** — census after one stop, assert every
/// row of §19.1's first table is zero.
///
/// The level is the view model against `FakeHostResources`, and that is a real
/// limitation worth stating: what these prove is that the *application* drives
/// a host that obeys §19.1 back to where it started — every `releaseSession`
/// sent, every meter stopped, every overlay hidden, on every exit. They cannot
/// prove that ScreenCaptureKit or WASAPI let go of anything, because no Dart
/// test can see a native object graph. That half belongs to a real integration
/// run, which is why `docs/development/compatibility-matrix.md` records it as
/// unverified rather than this file claiming it.
///
/// What makes them able to fail: the fake models a host that releases what
/// §19.1 says it must, and nothing more. A teardown step the view model skips
/// leaves a row standing.
void main() {
  /// One session, start to finished-and-left. The release is what leaving the
  /// post-recording screen does, and every one of Send, Delete and New
  /// recording does it.
  Future<void> runOneSession(TestHarness harness) async {
    await harness.viewModel.requestStart();
    await harness.viewModel.stop();
    harness.viewModel.keepRecordingForLater();
    await pumpEventQueue();
  }

  test('one cycle and ten cycles end holding exactly the same', () async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();

    await runOneSession(harness);
    final ResourceCensus afterFirst = await harness.recorder
        .debugResourceCensus();

    for (int i = 0; i < 9; i++) {
      await runOneSession(harness);
    }

    // Not "small enough" and not "no worse than": exactly equal. §19.1's rule
    // is that ten cycles end holding what the first one did — no additional
    // engine, texture registration, observer, event monitor, hook, capture
    // session, thread or timer.
    expect(await harness.recorder.debugResourceCensus(), afterFirst);
  });

  test('the same holds with the camera on and a sheet opened', () async {
    // The path that owns the most: a camera preview window with a texture, a
    // menu with its dismissal monitor, and a meter reference the sheet took.
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.settings.setCameraEnabled(true);

    Future<void> cycle() async {
      await harness.viewModel.requestStart();
      await harness.viewModel.openInputMenu(MediaDeviceKind.microphone);
      // Stopped with the sheet still open, which §19.1 calls out by name: the
      // sheet closes with the session and its meter reference goes with it.
      await harness.viewModel.stop();
      harness.viewModel.keepRecordingForLater();
      await pumpEventQueue();
    }

    await cycle();
    final ResourceCensus afterFirst = await harness.recorder
        .debugResourceCensus();

    for (int i = 0; i < 9; i++) {
      await cycle();
    }

    expect(await harness.recorder.debugResourceCensus(), afterFirst);
  });

  test('a launch census bounds every row of the first table', () async {
    // The baseline the equality test cannot use, and why. §19.1's second table
    // lets a host keep its overlay engines for the life of the process, and one
    // that does creates them when the first session shows a window — so a
    // launch census is short by exactly those engines. Every row of the *first*
    // table is zero in both, and that is the assertion worth making against it.
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.settings.setCameraEnabled(true);

    final ResourceCensus atLaunch = await harness.recorder
        .debugResourceCensus();
    expect(atLaunch.sessionResourcesReleased, isTrue, reason: '$atLaunch');

    for (int i = 0; i < 10; i++) {
      await runOneSession(harness);
    }

    final ResourceCensus afterTen = await harness.recorder
        .debugResourceCensus();
    expect(afterTen.sessionResourcesReleased, isTrue, reason: '$afterTen');
    // The engines are the only row allowed to differ, so re-comparing with them
    // equalised has to be an equality again — which is what says nothing *else*
    // grew while the engines did.
    expect(
      ResourceCensus.fromMap(<String, Object?>{
        ...afterTen.toMap(),
        'overlayEngines': atLaunch.overlayEngines,
      }),
      atLaunch,
    );
  });

  test('after one session every row of §19.1 first table is zero', () async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.settings.setCameraEnabled(true);

    await runOneSession(harness);

    final ResourceCensus census = await harness.recorder.debugResourceCensus();
    expect(census.sessionResourcesReleased, isTrue, reason: '$census');
    // Named individually as well, so a failure says which row survived rather
    // than only that one did.
    expect(census.captureStreams, 0);
    expect(census.cameraSessions, 0);
    expect(census.microphoneSessions, 0);
    expect(census.meteringTaps, 0);
    expect(census.meterSubscriptions, 0);
    expect(census.registeredTextures, 0);
    expect(census.eventMonitors, 0);
    expect(census.sessionTimers, 0);
    expect(census.powerAssertions, 0);
    expect(census.writers, 0);
    expect(census.compositors, 0);
  });

  test('the capture is released by the stop, before finalization', () async {
    // §19.1 puts the capture's release *before* finalization begins, so the
    // recording indicator goes out when Stop is pressed rather than when the
    // post-recording screen appears. Read while the session is still `ready`.
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.viewModel.requestStart();

    await harness.viewModel.stop();

    final ResourceCensus census = await harness.recorder.debugResourceCensus();
    expect(census.captureStreams, 0);
    expect(census.sessionTimers, 0);
    expect(census.powerAssertions, 0);
  });

  test('a fatal capture error leaves nothing behind either', () async {
    // §19.1 "applies to every exit — Stop, Abort, a fatal capture error, and
    // the user quitting mid-recording". This is the abort path: a fatal error
    // is what raises it, and the quit path has its own test in
    // `test/app/quit_mid_recording_test.dart`.
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.settings.setCameraEnabled(true);
    await harness.viewModel.requestStart();

    harness.recorder.emit(
      const RecorderErrorEvent(
        RecorderErrorCode.captureFailed,
        'The capture stopped.',
      ),
    );
    await pumpEventQueue();

    final ResourceCensus census = await harness.recorder.debugResourceCensus();
    expect(census.sessionResourcesReleased, isTrue, reason: '$census');
  });

  test('the census is falsifiable: a skipped release shows up', () async {
    // The guard on the two tests above. A fake that answered with a constant
    // would make them pass against a view model that tore nothing down, so this
    // asserts the model can report a leak at all.
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.viewModel.requestStart();
    await harness.viewModel.stop();

    // Stopped but not left: the writer and the compositor are still held, which
    // is correct here and would be a leak once the user has moved on.
    final ResourceCensus midway = await harness.recorder.debugResourceCensus();
    expect(midway.sessionResourcesReleased, isFalse);
    expect(midway.writers, 1);
    expect(midway.compositors, 1);
  });
}
