import 'dart:ui';

/// Colour tokens ported from `design/_ds/industry-*/styles.css`.
///
/// Ported from the file's *effective* result, not the `:root` block alone: the
/// override at the end of the stylesheet strips card and dialog fills, so
/// surfaces are transparent hairline objects and [surface] is used only where
/// the system still fills something (inputs, the window title bar).
abstract final class AppColors {
  static const Color background = Color(0xFFF2F2F3);
  static const Color surface = Color(0xFFE9E9EA);
  static const Color text = Color(0xFF1D1F20);
  static const Color accent = Color(0xFF5980A6);
  static const Color accent2 = Color(0xFF728FAB);

  /// `color-mix(in srgb, #1d1f20 16%, transparent)`.
  static const Color divider = Color(0x291D1F20);

  /// The recording indicator. The single non-system colour in the design,
  /// used only for the live dot on the control strip.
  static const Color recordingIndicator = Color(0xFFB4413F);

  static const Color neutral100 = Color(0xFFF5F5F8);
  static const Color neutral200 = Color(0xFFE7E7EA);
  static const Color neutral300 = Color(0xFFD4D4D7);
  static const Color neutral400 = Color(0xFFB7B7BA);
  static const Color neutral500 = Color(0xFF98989B);
  static const Color neutral600 = Color(0xFF7A7A7D);
  static const Color neutral700 = Color(0xFF5D5D60);
  static const Color neutral800 = Color(0xFF424244);
  static const Color neutral900 = Color(0xFF2B2B2D);

  static const Color accent100 = Color(0xFFEEF6FF);
  static const Color accent200 = Color(0xFFD6EBFF);
  static const Color accent300 = Color(0xFFB5D9FD);
  static const Color accent400 = Color(0xFF94BCE3);
  static const Color accent500 = Color(0xFF749DC4);
  static const Color accent600 = Color(0xFF597EA3);
  static const Color accent700 = Color(0xFF416180);
  static const Color accent800 = Color(0xFF2C455D);
  static const Color accent900 = Color(0xFF1D2D3D);

  static const Color accent2100 = Color(0xFFEEF6FF);
  static const Color accent2200 = Color(0xFFD6EBFF);
  static const Color accent2300 = Color(0xFFBDD8F2);
  static const Color accent2400 = Color(0xFF9EBBD8);
  static const Color accent2500 = Color(0xFF7E9CB8);
  static const Color accent2600 = Color(0xFF627D98);
  static const Color accent2700 = Color(0xFF486077);
  static const Color accent2800 = Color(0xFF314457);
  static const Color accent2900 = Color(0xFF1F2D3A);

  /// `color-mix(in srgb, var(--color-text) <percent>%, transparent)` — the
  /// stylesheet's one way of deriving a softer ink.
  static Color ink(double percent) =>
      text.withValues(alpha: (percent / 100).clamp(0.0, 1.0));

  /// `.text-muted` — text at 55%.
  static Color get textMuted => ink(55);

  /// Secondary metadata, `.mono` — text at 60%.
  static Color get textMono => ink(60);

  /// `.k` kicker — text at 50%.
  static Color get textKicker => ink(50);

  /// Field labels — text at 70%.
  static Color get textLabel => ink(70);

  /// `.blueprint > .corner` — text at 55%.
  static Color get registrationMark => ink(55);

  /// `.btn-secondary:hover` / `.table tbody tr:hover` tints.
  static Color get hoverTint => ink(7);
  static Color get pressedTint => ink(14);
  static Color get rowHoverTint => ink(4);

  static Color get accentHoverTint => accent.withValues(alpha: 0.10);
  static Color get accentPressedTint => accent.withValues(alpha: 0.18);

  /// `.dialog-backdrop` — neutral-900 at 50%.
  static Color get dialogScrim => neutral900.withValues(alpha: 0.5);

  /// `::selection`.
  static Color get selection => accent.withValues(alpha: 0.3);
}
