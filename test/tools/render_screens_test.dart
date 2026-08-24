@Tags(<String>['design-review'])
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/settings/app_settings.dart';
import 'package:relay/design_system/design_system.dart';
import 'package:relay/features/post_recording/presentation/delete_confirmation_dialog.dart';
import 'package:relay/features/post_recording/presentation/ready_screen.dart';
import 'package:relay/features/post_recording/presentation/upload_failed_screen.dart';
import 'package:relay/features/post_recording/presentation/uploading_screen.dart';
import 'package:relay/features/recorder/domain/session_state.dart';
import 'package:relay/features/recorder/presentation/launch_screen.dart';
import 'package:relay/features/recorder/presentation/preflight_screen.dart';
import 'package:relay/features/recorder/presentation/recovery_screen.dart';
import 'package:relay/features/recorder/presentation/source_picker_screen.dart';
import 'package:relay/features/settings/presentation/connect_destination_screen.dart';
import 'package:relay/features/settings/presentation/settings_screen.dart';
import 'package:upload_core/upload_core.dart';
import 'package:upload_telegram/upload_telegram.dart';
import 'package:upload_webdav/upload_webdav.dart';

import '../support/fakes.dart';
import '../support/harness.dart';

/// Renders every screen offscreen at the shipping panel size and writes a PNG.
///
/// Not an assertion suite: this is the tool the UI Definition of Done calls for
/// when it says to compare the implementation against the connected design
/// (`docs/development/design-system.md`). Run it with
/// `flutter test test/tools/render_screens_test.dart` and open
/// `build/design_review/`.
void main() {
  final Directory output = Directory('build/design_review');

  Future<void> capture(
    WidgetTester tester,
    String name,
    Widget screen, {
    Size size = panelSize,
  }) async {
    await loadDesignFonts();
    if (!output.existsSync()) {
      output.createSync(recursive: true);
    }
    final GlobalKey key = GlobalKey();
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MediaQuery(
          data: const MediaQueryData(size: panelSize, devicePixelRatio: 2),
          child: SizedBox.fromSize(size: size, child: screen),
        ),
      ),
    );
    // Bounded pumping rather than pumpAndSettle: a screen that never reaches a
    // quiescent frame must show up as a wrong picture, not as a hung suite.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    final RenderRepaintBoundary boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image? image = await tester.runAsync(
      () => boundary.toImage(pixelRatio: 2),
    );
    final ByteData? bytes = await tester.runAsync<ByteData?>(
      () async => image!.toByteData(format: ui.ImageByteFormat.png),
    );
    File('${output.path}/$name.png')
        .writeAsBytesSync(bytes!.buffer.asUint8List());
    image!.dispose();
  }

  testWidgets('1c launch screen', (WidgetTester tester) async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await capture(tester, '1c_launch', harness.wrap(const LaunchScreen()));
  });

  testWidgets('1a source picker', (WidgetTester tester) async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.viewModel.openSourcePicker();
    await capture(
      tester,
      '1a_source_picker',
      harness.wrap(const SourcePickerScreen()),
    );
  });

  testWidgets('1d preflight — camera requested but denied', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await TestHarness.create(
      settings: const AppSettings(cameraEnabled: true),
      permissions: FakeRecorderPermissions(
        statuses: <PermissionKind, PermissionStatus>{
          PermissionKind.screenRecording: PermissionStatus.granted,
          PermissionKind.microphone: PermissionStatus.granted,
          PermissionKind.camera: PermissionStatus.denied,
        },
      ),
    );
    addTearDown(harness.dispose);
    await harness.initialize();
    await harness.viewModel.requestStart();
    await capture(
      tester,
      '1d_preflight',
      harness.wrap(
        PreflightScreen(state: harness.viewModel.state as SessionPreflight),
      ),
    );
  });

  // The blocking preflight has no artboard on the canvas (see
  // `docs/development/design-system.md` → Missing states), so these renders are
  // the only way to look at the screen a first-run user actually meets. Every
  // state is captured: the one that ships most often is the one nobody had
  // seen.
  testWidgets('1d preflight — the blocking states', (
    WidgetTester tester,
  ) async {
    Future<void> blocking(
      String name,
      PermissionStatus screenRecording, {
      bool launchedByThisApp = true,
      bool failOnCheck = false,
    }) async {
      final TestHarness harness = await TestHarness.create(
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
            PermissionKind.camera: PermissionStatus.notDetermined,
          },
        )..failOnCheck = failOnCheck,
      );
      addTearDown(harness.dispose);
      await harness.initialize();
      await capture(
        tester,
        name,
        harness.wrap(
          PreflightScreen(state: harness.viewModel.state as SessionPreflight),
        ),
      );
    }

    await blocking('1d_blocked_not_asked', PermissionStatus.notDetermined);
    await blocking(
      '1d_blocked_pending_relaunch',
      PermissionStatus.pendingRelaunch,
    );
    await blocking('1d_preflight_blocked', PermissionStatus.denied);
    await blocking('1d_blocked_restricted', PermissionStatus.restricted);
    await blocking(
      '1d_blocked_check_failed',
      PermissionStatus.notDetermined,
      failOnCheck: true,
    );
    await blocking(
      '1d_blocked_wrong_launcher',
      PermissionStatus.notDetermined,
      launchedByThisApp: false,
    );
  });

  testWidgets('1f/1g control strip', (WidgetTester tester) async {
    await capture(
      tester,
      '1f_control_strip_recording',
      const RelayTheme(
        child: Center(
          child: RecordingControlStrip(
            elapsed: Duration(minutes: 14, seconds: 32),
            isPaused: false,
            microphoneEnabled: true,
            cameraEnabled: false,
            systemAudioEnabled: true,
          ),
        ),
      ),
      size: const Size(560, 90),
    );
    await capture(
      tester,
      '1g_control_strip_paused',
      const RelayTheme(
        child: Center(
          child: RecordingControlStrip(
            elapsed: Duration(minutes: 14, seconds: 32),
            isPaused: true,
            microphoneEnabled: false,
            cameraEnabled: false,
            systemAudioEnabled: true,
          ),
        ),
      ),
      size: const Size(660, 90),
    );
  });

  testWidgets('1e/1p camera preview surfaces', (WidgetTester tester) async {
    await capture(
      tester,
      '1e_camera_preview_window_mode',
      const RelayTheme(
        child: Center(
          child: SizedBox(
            width: 200,
            height: 140,
            child: CameraPreviewSurface(),
          ),
        ),
      ),
      size: const Size(260, 200),
    );
    await capture(
      tester,
      '1p_camera_preview_display_mode',
      const RelayTheme(
        child: Center(
          child: SizedBox(
            width: 168,
            height: 94,
            child: CameraPreviewSurface(matchesCompositedPip: true),
          ),
        ),
      ),
      size: const Size(220, 160),
    );
  });

  testWidgets('1i ready', (WidgetTester tester) async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await capture(
      tester,
      '1i_ready',
      harness.wrap(
        ReadyScreen(
          state: SessionReady(
            recording: FakeRecorder.sampleRecording(),
            name: 'recording-2026-08-22-1422',
          ),
        ),
      ),
    );
  });

  testWidgets('1j uploading', (WidgetTester tester) async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await capture(
      tester,
      '1j_uploading',
      harness.wrap(
        UploadingScreen(
          state: SessionUploading(
            recording: FakeRecorder.sampleRecording(),
            name: 'recording-2026-08-22-1422',
            destinationId: 'telegram',
            bytesSent: (1094813696 * 0.62).round(),
            totalBytes: 1094813696,
            chunkIndex: 42,
            chunkCount: 68,
          ),
        ),
      ),
    );
  });

  testWidgets('1k upload failed', (WidgetTester tester) async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await capture(
      tester,
      '1k_upload_failed',
      harness.wrap(
        UploadFailedScreen(
          state: SessionUploadFailed(
            recording: FakeRecorder.sampleRecording(),
            name: 'recording-2026-08-22-1422',
            destinationId: 'telegram',
            error: const UploadError.network(
              'The network dropped at 62%. Your recording is still on this Mac '
              'and can be resumed.',
            ),
            bytesConfirmed: 679477248,
            canResume: true,
          ),
        ),
      ),
    );
  });

  testWidgets('1l delete confirmation', (WidgetTester tester) async {
    await capture(
      tester,
      '1l_delete_confirmation',
      const RelayTheme(
        child: DeleteConfirmationDialog(
          duration: Duration(minutes: 14, seconds: 32),
          sizeBytes: 1094813696,
        ),
      ),
    );
  });

  testWidgets('1m settings', (WidgetTester tester) async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await capture(tester, '1m_settings', harness.wrap(const SettingsScreen()));
  });

  testWidgets('destination setup', (WidgetTester tester) async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    // Rendered from a real destination's own declaration: the screen has no
    // Telegram-specific markup to review (§15).
    await capture(
      tester,
      '1m_connect_webdav',
      harness.wrap(
        ConnectDestinationScreen(
          destination: WebDavUploadDestination(
            credentialStore: InMemoryCredentialStore(),
          ),
        ),
      ),
      size: const Size(AppSpacing.panelWidth, 900),
    );
    await capture(
      tester,
      '1m_connect_telegram',
      harness.wrap(
        ConnectDestinationScreen(
          destination: TelegramUploadDestination(
            config: TelegramConfig.unconfigured(),
            credentialStore: InMemoryCredentialStore(),
          ),
        ),
      ),
    );
  });

  testWidgets('1n startup recovery', (WidgetTester tester) async {
    final TestHarness harness = await TestHarness.create();
    addTearDown(harness.dispose);
    await harness.initialize();
    await capture(
      tester,
      '1n_recovery',
      harness.wrap(
        RecoveryScreen(
          artifact: IncompleteRecordingArtifact(
            path: '/tmp/relay/recording-8f2a11.part',
            recordingId: '8f2a11',
            sizeBytes: 432013312,
            modifiedAt: DateTime.now().subtract(const Duration(days: 1)),
          ),
        ),
      ),
    );
  });

  testWidgets('settings persisted values round-trip into the launch screen', (
    WidgetTester tester,
  ) async {
    final TestHarness harness = await TestHarness.create(
      settings: const AppSettings(
        quality: RecordingQuality.fullHd1080,
        frameRate: 60,
        cameraEnabled: true,
      ),
    );
    addTearDown(harness.dispose);
    await harness.initialize();
    await capture(
      tester,
      '1c_launch_1080p60_camera_on',
      harness.wrap(const LaunchScreen()),
    );
  });
}
