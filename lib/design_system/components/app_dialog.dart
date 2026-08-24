import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_shadows.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'blueprint_frame.dart';

/// `.dialog` inside `.dialog-backdrop` — a modal surface at the top elevation.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    required this.body,
    required this.actions,
    this.width = 340,
  });

  final String title;
  final String body;

  /// Secondary first, primary last — the system aligns actions to the end.
  final List<Widget> actions;

  final double width;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: AppColors.dialogScrim,
    child: Center(
      child: SizedBox(
        width: width,
        child: BlueprintFrame(
          background: AppColors.background,
          boxShadow: AppShadows.large,
          padding: const EdgeInsets.all(AppSpacing.x4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(title, style: AppTypography.h4),
              const SizedBox(height: AppSpacing.x3),
              Text(
                body,
                style: AppTypography.input.copyWith(color: AppColors.ink(85)),
              ),
              const SizedBox(height: AppSpacing.x3 + AppSpacing.x2),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  for (int i = 0; i < actions.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(width: AppSpacing.x2),
                    actions[i],
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Shows [dialog] over the current route.
///
/// Barrier dismissal is deliberately off for destructive confirmations: the
/// only ways out are the two explicit actions.
Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool dismissible = false,
}) {
  return Navigator.of(context, rootNavigator: true).push<T>(
    PageRouteBuilder<T>(
      opaque: false,
      barrierDismissible: dismissible,
      barrierColor: const Color(0x00000000),
      transitionDuration: AppMotion.instant,
      pageBuilder: (BuildContext context, _, _) => builder(context),
      transitionsBuilder: (
        BuildContext context,
        Animation<double> animation,
        _,
        Widget child,
      ) => FadeTransition(opacity: animation, child: child),
    ),
  );
}
