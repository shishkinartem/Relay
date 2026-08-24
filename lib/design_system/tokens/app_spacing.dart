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

  /// The main window is a fixed-width utility panel (design `00`).
  static const double panelWidth = 420.0;
  static const double panelMaxHeight = 560.0;
  static const double panelMinHeight = 460.0;

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
