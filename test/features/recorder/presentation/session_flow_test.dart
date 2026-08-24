import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/app/relay_app.dart';
import 'package:relay/design_system/design_system.dart';
import 'package:relay/features/post_recording/presentation/ready_screen.dart';
import 'package:relay/features/recorder/presentation/launch_screen.dart';
import 'package:relay/features/recorder/presentation/transient_screens.dart';

import '../../../support/harness.dart';

/// The two loops a session is actually operated through, end to end.
///
/// Every piece below is already covered on its own: the strip in
/// `design_system_test.dart`, the session in `recorder_view_model_test.dart`,
/// the state machine in `session_machine_test.dart`. What none of them cover
/// is the *joins* — that pressing Start moves the window to the recording
/// screen, and that a press on the strip comes back as a session change the
/// strip then redraws.
///
/// That second loop is the one that broke in the field. The commands travelled
/// and the session changed; the strip simply never showed it, and no test
/// noticed because no test ever rendered a strip from what a session pushed.
void main() {
  /// Renders whatever the session last pushed, and sends a press back the way
  /// the overlay engine does — through [OverlayCommand], not by calling the
  /// view model. Nothing is faked in between: this is the real strip
  /// component fed by the real snapshot.
  Widget liveStrip(TestHarness harness) => ListenableBuilder(
    listenable: harness.viewModel,
    builder: (BuildContext context, _) {
      final RecordingOverlayState state = harness.overlays.pushed.isEmpty
          ? const RecordingOverlayState()
          : harness.overlays.pushed.last;
      void send(OverlayCommand command) =>
          harness.overlays.commandController.add(command);
      return RecordingControlStrip(
        elapsed: state.elapsed,
        isPaused: state.isPaused,
        microphoneEnabled: state.microphoneEnabled,
        cameraEnabled: state.cameraEnabled,
        systemAudioEnabled: state.systemAudioEnabled,
        microphoneAvailable: state.microphoneAvailable,
        cameraAvailable: state.cameraAvailable,
        systemAudioAvailable: state.systemAudioAvailable,
        isStopping: state.isStopping,
        onToggleMicrophone: () => send(OverlayCommand.toggleMicrophone),
        onToggleCamera: () => send(OverlayCommand.toggleCamera),
        onToggleSystemAudio: () => send(OverlayCommand.toggleSystemAudio),
        onPauseOrResume: () => send(OverlayCommand.pauseOrResume),
        onStop: () => send(OverlayCommand.stop),
      );
    },
  );

  /// `pumpAndSettle` cannot be used while a transient screen is up: it draws
  /// an indeterminate [AppProgressBar], whose controller repeats forever, so
  /// the tree never settles. Frames are pumped by hand instead.
  Future<void> pumpFrames(WidgetTester tester, [int frames = 6]) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  group('the strip and the session, joined', () {
    testWidgets('Pause and Resume each change what the strip draws', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      await tester.pumpWidget(harness.wrap(liveStrip(harness)));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Pause'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Pause'));
      await tester.pumpAndSettle();

      expect(harness.recorder.calls, contains('pause'));
      expect(
        find.bySemanticsLabel('Resume'),
        findsOneWidget,
        reason:
            'a paused session must be visible on the strip, not only true '
            'in the state machine',
      );

      await tester.tap(find.bySemanticsLabel('Resume'));
      await tester.pumpAndSettle();

      expect(harness.recorder.calls, contains('resume'));
      expect(
        find.bySemanticsLabel('Pause'),
        findsOneWidget,
        reason:
            'and resuming must put the strip back, or the next press '
            'pauses again and Resume looks broken',
      );
    });

    testWidgets('the clock the strip draws follows the session', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      await tester.pumpWidget(harness.wrap(liveStrip(harness)));
      await tester.pumpAndSettle();

      harness.recorder.emit(
        const RecorderTickEvent(Duration(minutes: 1, seconds: 7)),
      );
      await tester.pumpAndSettle();
      expect(find.text('00:01:07'), findsOneWidget);

      // Paused, the timer holds — and it must hold on the strip, not merely in
      // the state machine that rejects the tick.
      await tester.tap(find.bySemanticsLabel('Pause'));
      await tester.pumpAndSettle();
      harness.recorder.emit(
        const RecorderTickEvent(Duration(minutes: 9, seconds: 9)),
      );
      await tester.pumpAndSettle();
      expect(find.text('00:01:07'), findsOneWidget);
    });

    testWidgets('a muted input is drawn muted', (WidgetTester tester) async {
      await loadDesignFonts();
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();

      await tester.pumpWidget(harness.wrap(liveStrip(harness)));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Microphone on'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Microphone on'));
      await tester.pumpAndSettle();

      expect(harness.recorder.calls, contains('setMicrophoneEnabled(false)'));
      expect(find.bySemanticsLabel('Microphone off'), findsOneWidget);
    });

    testWidgets('Stop disables the strip before the file exists', (
      WidgetTester tester,
    ) async {
      await loadDesignFonts();
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      await harness.viewModel.requestStart();
      harness.recorder.stopResult = _seed(harness);

      await tester.pumpWidget(harness.wrap(liveStrip(harness)));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Stop'));
      await tester.pumpAndSettle();

      // Finalization is not instant, and a second Stop or a Pause landing
      // during it would be asking the platform to change a session that is
      // already being written out.
      final RecordingOverlayState stopping = harness.overlays.pushed.firstWhere(
        (RecordingOverlayState s) => s.isStopping,
        orElse: () => const RecordingOverlayState(),
      );
      expect(stopping.isStopping, isTrue);
      expect(harness.recorder.calls, contains('stop'));
    });
  });

  group('the window follows the session', () {
    testWidgets('Start takes the panel to the recording screen and Stop '
        'brings back the recording', (WidgetTester tester) async {
      await loadDesignFonts();
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      harness.recorder.stopResult = _seed(harness);

      await tester.pumpWidget(harness.wrap(const RelayHome()));
      await tester.pumpAndSettle();
      expect(find.byType(LaunchScreen), findsOneWidget);

      await tester.tap(find.text('Start recording'));
      await pumpFrames(tester);

      expect(find.byType(TransientScreen), findsOneWidget);
      // AppKicker upper-cases its label.
      expect(find.text('RECORDING'), findsOneWidget);
      expect(
        harness.overlays.calls,
        containsAllInOrder(<String>[
          'showControlStrip',
          'setMainWindowVisible(false)',
        ]),
        reason: 'the strip is up before the panel leaves the screen',
      );

      await harness.viewModel.stop();
      await tester.pumpAndSettle();

      expect(find.byType(ReadyScreen), findsOneWidget);
      expect(find.text('01:12 · 1080p30 · H.264 / AAC · 2 KB'), findsOneWidget);
      expect(harness.overlays.calls, contains('setMainWindowVisible(true)'));
    });

    testWidgets('Delete asks first, and going through with it returns to the '
        'recorder with the file gone', (WidgetTester tester) async {
      await loadDesignFonts();
      final TestHarness harness = await TestHarness.create();
      addTearDown(harness.dispose);
      await harness.initialize();
      final RecordingFile recording = _seed(harness);
      harness.recorder.stopResult = recording;

      await tester.pumpWidget(harness.wrap(const RelayHome()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start recording'));
      await pumpFrames(tester);
      await harness.viewModel.stop();
      await tester.pumpAndSettle();

      final File onDisk = File(harness.viewModel.state.file!.path);
      expect(onDisk.existsSync(), isTrue);

      await tester.tap(find.bySemanticsLabel('Delete recording'));
      await tester.pumpAndSettle();

      // §18: a recording that was never uploaded is only deleted after the
      // user has been asked.
      expect(find.text('Delete this recording?'), findsOneWidget);
      expect(onDisk.existsSync(), isTrue);

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(onDisk.existsSync(), isTrue);
      expect(find.byType(ReadyScreen), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Delete recording'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(onDisk.existsSync(), isFalse);
      expect(find.byType(LaunchScreen), findsOneWidget);
    });
  });
}

/// A real file on disk, so deletion is exercised against the filesystem.
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
