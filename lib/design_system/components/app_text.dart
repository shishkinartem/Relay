import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_typography.dart';

/// `.k` — the uppercase kicker that labels every section of the panel.
class AppKicker extends StatelessWidget {
  const AppKicker(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: AppTypography.kicker.copyWith(color: color ?? AppColors.textKicker),
  );
}

/// `.mono` — the annotation voice used for metadata, sizes and diagnostics.
class AppMonoText extends StatelessWidget {
  const AppMonoText(
    this.text, {
    super.key,
    this.color,
    this.fontSize,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  final String text;
  final Color? color;
  final double? fontSize;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: textAlign,
    maxLines: maxLines,
    overflow: overflow,
    style: AppTypography.mono.copyWith(
      color: color ?? AppColors.textMono,
      fontSize: fontSize,
    ),
  );
}

/// `.hr` — a full-width hairline rule.
class AppDivider extends StatelessWidget {
  const AppDivider({
    super.key,
    this.margin = const EdgeInsets.symmetric(vertical: 2),
  });

  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) => Padding(
    padding: margin,
    child: Container(height: 1, color: AppColors.divider),
  );
}

/// `.rw` with `justify-content: space-between` — the panel's dominant layout:
/// a label on the left, a control on the right.
class AppRow extends StatelessWidget {
  const AppRow({
    super.key,
    required this.leading,
    required this.trailing,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  });

  final Widget leading;
  final Widget trailing;
  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: crossAxisAlignment,
    children: <Widget>[
      Flexible(child: leading),
      const SizedBox(width: 8),
      trailing,
    ],
  );
}
