import 'package:flutter/widgets.dart';

import '../core/logging/app_logger.dart';
import '../design_system/design_system.dart';

/// Shown when the object graph could not be built.
///
/// A desktop application that fails to start must say so. A black window is
/// not a state — it is the absence of one, and it tells the user nothing.
class StartupFailureApp extends StatelessWidget {
  const StartupFailureApp({
    super.key,
    required this.error,
    required this.stackTrace,
  });

  final Object error;
  final StackTrace stackTrace;

  /// Redaction applies here too.
  ///
  /// This is the one error path in the application that did not route through
  /// [LogRedactor], while `ErrorPresentation` redacts every technical line it
  /// shows. A screen the user is being invited to photograph and send is the
  /// last place to make an exception.
  static const LogRedactor _redactor = LogRedactor();

  /// The first frames of the stack, redacted.
  ///
  /// `main` catches `(error, stackTrace)` and passes both here; the trace was
  /// then never rendered, never logged and never used. It is the only thing
  /// that localises a startup failure inside the object graph, and the logger
  /// does not exist yet at that point — so if this screen does not show it,
  /// nothing does.
  ///
  /// Bounded to the frames that identify the failure: the whole trace would
  /// push the message itself off a small window.
  String get _trace {
    final List<String> frames = _redactor
        .redactText(stackTrace.toString())
        .split('\n')
        .where((String line) => line.trim().isNotEmpty)
        .take(8)
        .toList(growable: false);
    return frames.join('\n');
  }

  @override
  Widget build(BuildContext context) => WidgetsApp(
    title: 'Relay',
    color: AppColors.accent,
    debugShowCheckedModeBanner: false,
    pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
        PageRouteBuilder<T>(
          settings: settings,
          pageBuilder: (_, _, _) => builder(context),
        ),
    home: RelayTheme(
      child: AppPanel(
        title: 'Recorder',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const AppKicker('Could not start'),
            const SizedBox(height: 12),
            BlueprintFrame(
              borderColor: AppColors.accent,
              padding: const EdgeInsets.all(11),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: AppIcon(
                      AppIcons.warning,
                      size: 17,
                      color: AppColors.accent700,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          'Relay could not set itself up',
                          style: AppTypography.h5,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Nothing was recorded and nothing was deleted. The '
                          'details below identify what failed.',
                          style: AppTypography.bodyXSmall.copyWith(
                            color: AppColors.ink(70),
                          ),
                        ),
                        const SizedBox(height: 6),
                        AppMonoText(_redactor.redactText(error.toString())),
                        if (_trace.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 6),
                          AppMonoText(_trace),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
