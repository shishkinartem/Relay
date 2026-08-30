import 'package:flutter/widgets.dart';

import '../icons/app_icon.dart';
import '../icons/app_icons.dart';
import '../tokens/app_colors.dart';

/// A row whose detail settings are put away until asked for (§33.2).
///
/// The row keeps its own primary control — the input's On / Off — outside the
/// disclosure's tap target, in [headerTrailing]. That separation is the whole
/// point: a user reaching for Off must never open a panel instead, and a user
/// reaching for the details must never mute an input instead.
///
/// The chevron and the label are both targets, because a chevron alone is a
/// 13 px target and the label beside it is the thing people aim at.
class AppDisclosure extends StatelessWidget {
  const AppDisclosure({
    super.key,
    required this.header,
    required this.expanded,
    required this.onToggle,
    required this.semanticLabel,
    required this.child,
    this.headerTrailing,
    this.enabled = true,
  });

  /// The tappable leading part of the row — typically an icon and a label.
  final Widget header;

  /// A control that belongs to the row but not to the disclosure. Its taps are
  /// its own.
  final Widget? headerTrailing;

  final bool expanded;

  /// Null-safe by construction: [enabled] false is what disables the toggle,
  /// so a caller cannot accidentally ship a row that looks open-able and is not.
  final ValueChanged<bool> onToggle;

  final String semanticLabel;

  /// Shown only while [expanded]. Built lazily by the caller, so a closed
  /// section costs nothing.
  final Widget child;

  /// False for a row with nothing to disclose — an input this platform gives no
  /// choice about. The chevron is not drawn at all rather than drawn dead: a
  /// control that cannot ever do anything is not a disabled control, it is not
  /// a control (§33.4).
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: enabled
                  ? _Target(
                      semanticLabel: semanticLabel,
                      expanded: expanded,
                      onTap: () => onToggle(!expanded),
                      child: header,
                    )
                  : header,
            ),
            ?headerTrailing,
            if (enabled) ...<Widget>[
              const SizedBox(width: 4),
              _Target(
                semanticLabel: semanticLabel,
                expanded: expanded,
                onTap: () => onToggle(!expanded),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(
                    child: RotatedBox(
                      quarterTurns: expanded ? 2 : 0,
                      child: AppIcon(
                        AppIcons.chevronDown,
                        size: 13,
                        color: expanded
                            ? AppColors.accent700
                            : AppColors.ink(45),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        if (expanded)
          Padding(
            // Indented under the row's icon and ruled, so the details read as
            // belonging to the input above them rather than as a new section.
            padding: const EdgeInsets.only(left: 22, top: 8),
            child: Container(
              padding: const EdgeInsets.only(left: 10),
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: AppColors.divider)),
              ),
              child: child,
            ),
          ),
      ],
    );
  }
}

/// One tap target of a disclosure. Two of them share the same semantics, so a
/// screen reader announces one expandable control rather than two.
class _Target extends StatelessWidget {
  const _Target({
    required this.semanticLabel,
    required this.expanded,
    required this.onTap,
    required this.child,
  });

  final String semanticLabel;
  final bool expanded;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    expanded: expanded,
    label: semanticLabel,
    onTap: onTap,
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(cursor: SystemMouseCursors.click, child: child),
    ),
  );
}
