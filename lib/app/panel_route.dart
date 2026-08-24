import 'package:flutter/widgets.dart';

import '../design_system/design_system.dart';

/// The transition every in-panel screen is pushed with.
///
/// One definition, because the panel is a single window: a screen that arrives
/// with a different motion reads as a different surface. Extracted from the
/// launch screen when the preflight also needed a way into Settings — a
/// permission Relay cannot grant is no reason to lock the user out of the
/// destination setup, which needs no permission at all.
Route<T> panelRoute<T>(Widget child) => PageRouteBuilder<T>(
  transitionDuration: AppMotion.quick,
  pageBuilder: (BuildContext context, _, _) => child,
  transitionsBuilder: (
    BuildContext context,
    Animation<double> animation,
    _,
    Widget child,
  ) => FadeTransition(opacity: animation, child: child),
);
