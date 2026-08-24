import 'package:flutter/widgets.dart';

import 'app_colors.dart';

/// Typography tokens — Barlow Condensed over Barlow, on the system's fixed
/// scale. Density moves spacing, never sizes.
abstract final class AppTypography {
  static const String headingFamily = 'Barlow Condensed';
  static const String bodyFamily = 'Barlow';

  /// `.mono` — the annotation/metadata voice.
  ///
  /// Vendored rather than resolved from the OS, so `ui-monospace` renders the
  /// same face on both platforms.
  static const String monoFamily = 'RelayMono';

  static const List<String> monoFamilyFallback = <String>[
    'Menlo',
    'SF Mono',
    'Consolas',
    'monospace',
  ];

  static const TextStyle _heading = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w600,
    height: 1.12,
    letterSpacing: -0.015 * 25,
    color: AppColors.text,
  );

  static const TextStyle h1 = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w600,
    fontSize: 42,
    height: 1.12,
    letterSpacing: -0.63,
    color: AppColors.text,
  );

  static const TextStyle h2 = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w600,
    fontSize: 32,
    height: 1.12,
    letterSpacing: -0.48,
    color: AppColors.text,
  );

  static const TextStyle h3 = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w600,
    fontSize: 25,
    height: 1.12,
    letterSpacing: -0.375,
    color: AppColors.text,
  );

  /// `.dialog-title`.
  static const TextStyle h4 = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w600,
    fontSize: 20,
    height: 1.12,
    letterSpacing: -0.3,
    color: AppColors.text,
  );

  /// The failure headline in design `1k`.
  static const TextStyle h5 = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w600,
    fontSize: 16,
    height: 1.12,
    letterSpacing: -0.24,
    color: AppColors.text,
  );

  /// `.card-title`.
  static const TextStyle cardTitle = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w600,
    fontSize: 17,
    height: 1.2,
    color: AppColors.text,
  );

  /// The big upload percentage in design `1j`.
  static const TextStyle numericDisplay = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w600,
    fontSize: 26,
    height: 1.0,
    color: AppColors.text,
  );

  /// `.tbt` — window title bar label.
  static const TextStyle titleBar = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w600,
    fontSize: 13,
    letterSpacing: 0.26,
    color: AppColors.text,
  );

  /// `.k` — the uppercase kicker that labels every section.
  static const TextStyle kicker = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w600,
    fontSize: 10,
    letterSpacing: 1.1,
    height: 1.4,
  );

  /// `.btn` — matches the input's 14px, the pair sits side by side.
  static const TextStyle button = TextStyle(
    fontFamily: headingFamily,
    fontWeight: FontWeight.w600,
    fontSize: 14,
    height: 1.2,
  );

  static const TextStyle body = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 15,
    height: 1.55,
    color: AppColors.text,
  );

  /// The default row voice across the panel screens.
  static const TextStyle bodySmall = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 13,
    height: 1.5,
    color: AppColors.text,
  );

  static const TextStyle bodyXSmall = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 12.5,
    height: 1.5,
    color: AppColors.text,
  );

  /// A row title that carries weight — source names, destination names.
  static const TextStyle bodyEmphasis = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w500,
    fontSize: 13,
    height: 1.4,
    color: AppColors.text,
  );

  /// `.field > label`.
  static const TextStyle fieldLabel = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 12,
    height: 1.3,
  );

  /// `.input`, `.seg-opt`.
  static const TextStyle input = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 14,
    height: 1.3,
    color: AppColors.text,
  );

  static const TextStyle segment = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 13,
    height: 1.3,
  );

  /// `.tag`.
  static const TextStyle tag = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 11,
    letterSpacing: 0.22,
    height: 1.3,
  );

  /// `.mono` — the annotation voice.
  static const TextStyle mono = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFamilyFallback,
    fontSize: 11,
    height: 1.5,
  );

  static const TextStyle monoSmall = TextStyle(
    fontFamily: monoFamily,
    fontFamilyFallback: monoFamilyFallback,
    fontSize: 10,
    height: 1.4,
  );

  /// `.table th`.
  static const TextStyle tableHeader = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 11,
    letterSpacing: 0.88,
    height: 1.4,
  );

  static const TextStyle tableCell = TextStyle(
    fontFamily: bodyFamily,
    fontWeight: FontWeight.w400,
    fontSize: 12.5,
    height: 1.5,
    color: AppColors.text,
  );

  static TextStyle get headingBase => _heading;
}
