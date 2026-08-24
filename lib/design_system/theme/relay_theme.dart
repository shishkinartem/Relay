import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_typography.dart';

/// The application's typed theme surface.
///
/// The design is a single deliberate light wireframe, so the tokens are the
/// theme. This wrapper exists so a screen never sets a default text style or a
/// ground colour by hand, and so a test can assert the whole tree is themed.
///
/// It also supplies [Directionality]. The overlay windows run in their own
/// Flutter engines with no `WidgetsApp` above them, so the theme is the only
/// place that can provide one.
class RelayTheme extends StatelessWidget {
  const RelayTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: DefaultSelectionStyle(
      cursorColor: AppColors.accent,
      selectionColor: AppColors.selection,
      child: DefaultTextStyle(
        style: AppTypography.body,
        child: ColoredBox(color: AppColors.background, child: child),
      ),
    ),
  );
}
