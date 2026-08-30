/// Spacing tokens — the design system's 0.85x scale.
///
/// The fractional pixel values are the system's own (`--space-*`); rounding
/// them here would drift the whole layout away from the canvas.
abstract final class AppSpacing {
  static const double x1 = 3.4;
  static const double x2 = 6.8;
  static const double x3 = 10.2;
  static const double x4 = 13.6;
  static const double x6 = 20.4;
  static const double x8 = 27.2;

  /// `.pad` — the panel's content inset.
  static const double panelPadding = 14.0;

  /// The reference width every screen is drawn at (design `00`), and the
  /// narrowest the window may be.
  static const double panelWidth = 420.0;
  static const double panelMaxHeight = 560.0;
  static const double panelMinHeight = 460.0;

  /// The panel has a width *range*, not a width (§33.6).
  ///
  /// Past 960 a utility panel is a window pretending to be an application: the
  /// content is a column of controls in an ocean, and every extra pixel makes
  /// it worse rather than better.
  static const double panelMaxWidth = 960.0;

  /// Breakpoints, in logical pixels of available width.
  ///
  /// Resolved against the layout's own constraints, never against a device or a
  /// platform name (§28). Below [wide] every screen is the reference layout,
  /// exactly as drawn.
  static const double wide = 560.0;
  static const double wider = 768.0;

  /// How many columns a grid of source cards takes at [width].
  ///
  /// Here rather than in the picker because it is the one place the breakpoints
  /// turn into a number, and a second grid must not be free to disagree.
  static int gridColumns(double width) {
    if (width >= wider) {
      return 4;
    }
    if (width >= wide) {
      return 3;
    }
    return 2;
  }

  /// `.tb` — window header height. Tall enough to host the system window
  /// buttons, which the transparent title bar overlays onto it.
  static const double titleBarHeight = 38.0;
}

/// Corner radii.
///
/// The system defines a `--radius-*` ramp, then overrides cards, buttons,
/// inputs, tags, segmented controls and dialogs back to `0`. Components use
/// [none]; the ramp is kept because the tokens still exist in the system.
abstract final class AppRadius {
  static const double none = 0.0;
  static const double sm = 2.0;
  static const double md = 4.0;
  static const double lg = 7.0;
}

/// Motion tokens. The system ships no animation of its own; these are the
/// minimal, consistent durations used for state transitions.
abstract final class AppMotion {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration quick = Duration(milliseconds: 140);
  static const Duration standard = Duration(milliseconds: 220);
}
