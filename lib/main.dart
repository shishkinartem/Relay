import 'dart:async';

import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app/app_scope.dart';
import 'app/composition_root.dart';
import 'app/relay_app.dart';
import 'app/startup_failure_app.dart';
import 'features/recorder/presentation/overlay/camera_preview_window.dart';
import 'features/recorder/presentation/overlay/control_strip_window.dart';
import 'features/recorder/presentation/overlay/overlay_binding.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Composition is local work only — files and objects, no platform calls — so
  // the first frame is never waiting on the operating system. A failure here
  // shows a readable screen rather than a black window.
  final CompositionRoot root;
  try {
    root = await CompositionRoot.create().timeout(const Duration(seconds: 10));
  } on Object catch (error, stackTrace) {
    runApp(StartupFailureApp(error: error, stackTrace: stackTrace));
    return;
  }

  // Uncaught errors reach the log rather than only the console, which in a
  // release build is nowhere: `ConsoleLogSink` is gated behind `kDebugMode`.
  // Installed after composition, because before it there is no logger — a
  // failure earlier than this is what `StartupFailureApp` is for.
  final FlutterExceptionHandler? previousOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    root.logger.error(
      'flutter_error',
      fields: <String, Object?>{
        'library': details.library ?? 'unknown',
        'context': details.context?.toString() ?? '',
      },
      error: details.exception,
    );
    previousOnError?.call(details);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    root.logger.error('uncaught_error', error: error);
    // False: the error is recorded, not handled. Claiming otherwise would
    // suppress the framework's own reporting.
    return false;
  };

  // A desktop application is quit, not backgrounded, and `detached` is not
  // guaranteed to arrive before the process goes away — an exit request is.
  // This is what stops quitting mid-recording from leaving the capture, the
  // camera light and the power assertion behind.
  //
  // The listener registers itself with the binding, which owns it for the life
  // of the process; there is nothing here to hold or to cancel.
  AppLifecycleListener(
    onExitRequested: () async {
      await root.dispose();
      return AppExitResponse.exit;
    },
  );

  runApp(
    RelayApp(
      scope: (Widget child) => AppScope(
        recorder: root.recorder,
        settings: root.settings,
        destinations: root.destinations,
        environment: root.environment,
        logger: root.logger,
        child: child,
      ),
    ),
  );

  // Platform discovery runs after the first frame. It can block for as long as
  // macOS keeps its permission prompt up, and the UI must stay usable.
  unawaited(root.recorder.initialize());
}

/// Entry point for the control-strip overlay window's own Flutter engine.
///
/// The overlay is a separate top-level window created by the platform plugin
/// and excluded from capture (§6). It renders a snapshot pushed from the main
/// engine and raises intents back; it owns no session state.
///
/// [OverlayBinding], not the default one: an always-on-top window has to keep
/// drawing while the application is hidden behind whatever is being recorded.
@pragma('vm:entry-point')
void controlStripMain() {
  OverlayBinding.ensureInitialized();
  runApp(const ControlStripWindow());
}

/// Entry point for the camera-preview overlay window's own Flutter engine.
@pragma('vm:entry-point')
void cameraPreviewMain() {
  OverlayBinding.ensureInitialized();
  runApp(const CameraPreviewWindow());
}
