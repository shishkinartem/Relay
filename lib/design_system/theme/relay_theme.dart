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
  const RelayTheme({super.key, required this.child, this.ground = _default});

  final Widget child;

  /// What the surface behind [child] is painted with, or **null for nothing**.
  ///
  /// Null exists for one caller: the display-mode camera preview, whose window
  /// *is* the composited picture-in-picture (design `1p`). The compositor
  /// leaves every pixel outside the tile untouched, so a ground here would put
  /// a square of `#F2F2F3` on the user's screen around a circular tile — which
  /// is exactly what it did.
  ///
  /// Every other surface keeps the ground. The main window needs it, and the
  /// control strip and the input menu paint their own over the top of it, so
  /// removing it globally would buy nothing and risk a hairline of whatever is
  /// underneath wherever their own frame does not reach the window's edge.
  final Color? ground;

  /// Sentinel so `ground: null` is distinguishable from "not given".
  static const Color _default = AppColors.background;

  @override
  Widget build(BuildContext context) {
    final Widget body = ground == null
        ? child
        : ColoredBox(color: ground!, child: child);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultSelectionStyle(
        cursorColor: AppColors.accent,
        selectionColor: AppColors.selection,
        child: DefaultTextStyle(style: AppTypography.body, child: body),
      ),
    );
  }
}
