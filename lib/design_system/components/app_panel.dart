import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// `.tb` — the window header: a title and a trailing slot.
///
/// The design draws macOS traffic lights here because the canvas has no real
/// window chrome. The application does: the window's own title bar is made
/// transparent and this row is laid out underneath it, so the real buttons are
/// the ones on screen and nothing is duplicated. [leadingInset] reserves the
/// space they occupy.
class AppTitleBar extends StatelessWidget {
  const AppTitleBar({
    super.key,
    required this.title,
    this.trailing,
    this.leadingInset = 78,
  });

  final String title;
  final Widget? trailing;

  /// Room for the system window buttons. Zero in the overlay windows, which
  /// have no chrome at all.
  final double leadingInset;

  @override
  Widget build(BuildContext context) => Container(
    height: AppSpacing.titleBarHeight,
    padding: EdgeInsets.only(left: leadingInset, right: 11),
    decoration: const BoxDecoration(
      color: AppColors.surface,
      border: Border(bottom: BorderSide(color: AppColors.divider)),
    ),
    child: Row(
      children: <Widget>[
        Text(
          title,
          style: AppTypography.titleBar.copyWith(color: AppColors.ink(75)),
        ),
        const Spacer(),
        ?trailing,
      ],
    ),
  );
}

/// `.win` + `.pad` — the 420px utility panel every screen lives in.
class AppPanel extends StatelessWidget {
  const AppPanel({
    super.key,
    required this.title,
    required this.child,
    this.titleBarTrailing,
    this.footer,
    this.scrollable = true,
    this.padding = const EdgeInsets.all(AppSpacing.panelPadding),
  });

  final String title;
  final Widget child;
  final Widget? titleBarTrailing;

  /// Pinned below the scrolling body.
  ///
  /// A screen whose list can outgrow the panel keeps its committing action
  /// here, so that action is never something the user has to scroll to find.
  final Widget? footer;

  final bool scrollable;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final Widget body = Padding(padding: padding, child: child);
    return ColoredBox(
      color: AppColors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppTitleBar(title: title, trailing: titleBarTrailing),
          Expanded(
            child: scrollable
                ? RawScrollbar(
                    thumbColor: AppColors.ink(28),
                    thickness: 4,
                    radius: Radius.zero,
                    child: SingleChildScrollView(primary: false, child: body),
                  )
                : body,
          ),
          if (footer != null)
            DecoratedBox(
              decoration: const BoxDecoration(
                color: AppColors.background,
                border: Border(top: BorderSide(color: AppColors.divider)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.panelPadding),
                child: footer,
              ),
            ),
        ],
      ),
    );
  }
}
