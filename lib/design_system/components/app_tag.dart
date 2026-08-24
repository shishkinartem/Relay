import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_typography.dart';

/// `.tag-*` — the four tag tints the system provides.
enum AppTagTone { accent, accentSecondary, neutral, outline }

/// `.tag` — a small square status chip.
class AppTag extends StatelessWidget {
  const AppTag(
    this.label, {
    super.key,
    this.tone = AppTagTone.accent,
    this.fontSize,
    this.opaqueBackground = false,
    this.dense = false,
  });

  final String label;
  final AppTagTone tone;
  final double? fontSize;

  /// The compact form the system uses for tags overlaid on content, where the
  /// stylesheet drops the padding to `1px 5px`.
  final bool dense;

  /// Outline tags placed over busy content sit on the panel ground so they
  /// stay legible (design `1p`).
  final bool opaqueBackground;

  @override
  Widget build(BuildContext context) {
    final (Color background, Color foreground, Color? border) = switch (tone) {
      AppTagTone.accent => (AppColors.accent100, AppColors.accent800, null),
      AppTagTone.accentSecondary => (
        AppColors.accent2100,
        AppColors.accent2800,
        null,
      ),
      AppTagTone.neutral => (AppColors.neutral100, AppColors.neutral800, null),
      AppTagTone.outline => (
        opaqueBackground ? AppColors.background : const Color(0x00000000),
        AppColors.accent,
        AppColors.accent,
      ),
    };

    return Container(
      padding: dense
          ? const EdgeInsets.symmetric(horizontal: 5, vertical: 1)
          : const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        border: border == null ? null : Border.all(color: border),
      ),
      child: Text(
        label,
        style: AppTypography.tag.copyWith(
          color: foreground,
          fontSize: fontSize,
        ),
      ),
    );
  }
}
