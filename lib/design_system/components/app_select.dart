import 'package:flutter/widgets.dart';

import '../icons/app_icon.dart';
import '../icons/app_icons.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_typography.dart';

/// design gap: no field of this kind appears on the canvas. Modelled on the
/// hairline rows `1c` and `1m` do draw, rather than invented — see
/// `design/README.md` → *The v0.5 interface has no design backing*.
///
/// The closed state of a choice: what is chosen, and a chevron to change it
/// (§33.2).
///
/// A hairline row rather than a filled control, because the system's objects
/// are line drawings and the one solid object on a screen is its primary
/// button.
class AppSelectField extends StatelessWidget {
  const AppSelectField({
    super.key,
    required this.label,
    required this.semanticLabel,
    this.meta,
    this.onPressed,
    this.expanded = false,
    this.height = 32,
  });

  /// What is currently chosen.
  final String label;

  /// A secondary word — `default`, a resolution, why there is no choice.
  final String? meta;

  final String semanticLabel;

  /// Null draws the field fixed: something the user is told, not asked.
  /// Its border is dashed, so "there is one of these" and "you may pick one"
  /// are not the same picture.
  final VoidCallback? onPressed;

  final bool expanded;
  final double height;

  @override
  Widget build(BuildContext context) {
    final bool interactive = onPressed != null;
    final Widget content = Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(
          color: interactive ? AppColors.divider : AppColors.ink(22),
        ),
        color: expanded ? AppColors.accentHoverTint : null,
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodyXSmall.copyWith(
                color: interactive ? AppColors.text : AppColors.textMono,
              ),
            ),
          ),
          if (meta != null) ...<Widget>[
            const SizedBox(width: 8),
            Text(
              meta!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.monoSmall.copyWith(
                color: AppColors.textKicker,
              ),
            ),
          ],
          if (interactive) ...<Widget>[
            const SizedBox(width: 8),
            RotatedBox(
              quarterTurns: expanded ? 2 : 0,
              child: AppIcon(
                AppIcons.chevronDown,
                size: 13,
                color: AppColors.ink(55),
              ),
            ),
          ],
        ],
      ),
    );

    if (!interactive) {
      return Semantics(
        label: semanticLabel,
        value: label,
        readOnly: true,
        excludeSemantics: true,
        child: content,
      );
    }
    return Semantics(
      button: true,
      expanded: expanded,
      label: semanticLabel,
      value: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: GestureDetector(
        onTap: onPressed,
        behavior: HitTestBehavior.opaque,
        child: MouseRegion(cursor: SystemMouseCursors.click, child: content),
      ),
    );
  }
}

/// One row of an open choice — the shape the control strip's action sheet will
/// reuse when it arrives (§33.4).
class AppOptionTile extends StatelessWidget {
  const AppOptionTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.meta,
    this.enabled = true,
  });

  final String label;
  final String? meta;
  final bool selected;

  /// False for a device the platform lists but cannot open. Shown and not
  /// selectable, so its absence is legible rather than mysterious (§33.7).
  final bool enabled;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final Widget content = Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      color: selected ? AppColors.accentHoverTint : null,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 15,
            child: selected
                ? const AppIcon(
                    AppIcons.check,
                    size: 12,
                    color: AppColors.accent,
                  )
                : null,
          ),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodyXSmall.copyWith(
                color: !enabled
                    ? AppColors.ink(40)
                    : selected
                    ? AppColors.accent800
                    : AppColors.text,
                fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ),
          if (meta != null) ...<Widget>[
            const SizedBox(width: 8),
            Text(
              meta!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.monoSmall.copyWith(
                color: AppColors.textKicker,
              ),
            ),
          ],
        ],
      ),
    );

    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      onTap: enabled ? onPressed : null,
      child: GestureDetector(
        onTap: enabled ? onPressed : null,
        behavior: HitTestBehavior.opaque,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: content,
        ),
      ),
    );
  }
}
