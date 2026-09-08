import 'package:flutter/widgets.dart';

import '../design_system/design_system.dart';
import '../features/post_recording/presentation/ready_screen.dart';
import '../features/post_recording/presentation/upload_failed_screen.dart';
import '../features/post_recording/presentation/uploading_screen.dart';
import '../features/recorder/application/recorder_view_model.dart';
import '../features/recorder/domain/session_state.dart';
import '../features/recorder/presentation/launch_screen.dart';
import '../features/recorder/presentation/preflight_screen.dart';
import '../features/recorder/presentation/recovery_screen.dart';
import '../features/recorder/presentation/transient_screens.dart';
import 'app_scope.dart';

/// The application shell.
///
/// Built on `WidgetsApp` rather than `MaterialApp`: the design system supplies
/// every visual value, and Material's defaults would compete with it.
class RelayApp extends StatelessWidget {
  const RelayApp({super.key, required this.scope});

  final AppScope Function(Widget child) scope;

  @override
  Widget build(BuildContext context) => WidgetsApp(
    title: 'Relay',
    color: AppColors.accent,
    debugShowCheckedModeBanner: false,
    pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
        PageRouteBuilder<T>(
          settings: settings,
          transitionDuration: AppMotion.quick,
          pageBuilder: (BuildContext context, _, _) => builder(context),
        ),
    builder: (BuildContext context, Widget? child) =>
        scope(RelayTheme(child: child ?? const SizedBox.shrink())),
    home: const RelayHome(),
  );
}

/// Chooses the screen for the current session state (§19, §29).
class RelayHome extends StatelessWidget {
  const RelayHome({super.key});

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    return ListenableBuilder(
      listenable: vm,
      builder: (BuildContext context, _) {
        if (vm.hasRecoverableArtifacts) {
          return RecoveryScreen(artifact: vm.pendingArtifacts.first);
        }
        return switch (vm.state) {
          SessionIdle() || SessionSelectingSource() => const LaunchScreen(),
          final SessionPreflight state => PreflightScreen(state: state),
          SessionPreparing() => const TransientScreen(
            kicker: 'Preparing',
            message: 'Getting ready to record.',
          ),
          // The main window is hidden during the pre-roll — that is the point
          // of it, since the recorder's own panel is the one window the user
          // cannot arrange around. A fixed message rather than a live count: a
          // hidden surface mirroring live state is a second place to get the
          // number wrong.
          SessionCountingDown() => const TransientScreen(
            kicker: 'Starting',
            message:
                'The countdown is on the control strip. Cancel it there to '
                'stop before anything is recorded.',
          ),
          final SessionActive state => TransientScreen(
            kicker: state.isStopping ? 'Stopping' : 'Recording',
            message: state.isStopping
                ? 'Saving your recording.'
                : 'The control strip is on your current display.',
          ),
          SessionFinalizing() => const TransientScreen(
            kicker: 'Saving',
            message: 'Writing the video file.',
          ),
          final SessionReady state => ReadyScreen(state: state),
          final SessionUploading state => UploadingScreen(state: state),
          final SessionUploadFailed state => UploadFailedScreen(state: state),
          final SessionDeleting state => TransientScreen(
            kicker: 'Deleting',
            message: state.afterUpload
                ? 'The upload was confirmed. Removing the local copy.'
                : 'Removing the local recording.',
          ),
          final SessionFailed state => CaptureFailureScreen(state: state),
        };
      },
    );
  }
}
