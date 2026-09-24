import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// What the host window is, for the parts of the design system that have to
/// lay out around it.
///
/// Here rather than in `theme/` because [AppTitleBar] is the only thing that
/// reads it, and a scope that lives beside its one consumer cannot drift away
/// from it. It carries a plain [double] on purpose: the design system may not
/// import the recorder platform interface, so the composition root is what
/// turns `WindowChrome` into a number and installs it (§28).
class AppWindowChrome extends InheritedWidget {
  const AppWindowChrome({
    super.key,
    required this.titleBarLeadingInset,
    required super.child,
  });

  /// What [AppTitleBar] must leave clear on its leading edge.
  final double titleBarLeadingInset;

  /// The installed inset, or the window-button reservation when no scope is
  /// above [context].
  ///
  /// The fallback is the reservation rather than the bare padding because the
  /// trees without a scope are the ones with no host window to ask: a widget
  /// test and the design-review renders, whose canvas draws the buttons in the
  /// header exactly as macOS does. A screen rendered for review should look
  /// like the screen that ships.
  static double leadingInsetOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AppWindowChrome>()
          ?.titleBarLeadingInset ??
      AppSpacing.titleBarWindowButtonsInset;

  @override
  bool updateShouldNotify(AppWindowChrome oldWidget) =>
      oldWidget.titleBarLeadingInset != titleBarLeadingInset;
}

/// `.tb` — the window header: a title and a trailing slot.
///
/// The design draws macOS traffic lights here because the canvas has no real
/// window chrome. Whether the *application* has any is the host's business:
/// macOS makes the window's own title bar transparent and lays this row out
/// underneath it, so the real buttons are the ones on screen and the row has
/// to keep out of their way, while a host that keeps its caption puts this row
/// below it, where the same reservation is a dead gap. That is what
/// [AppWindowChrome] answers, and why [leadingInset] no longer carries one
/// host's number as its default.
class AppTitleBar extends StatelessWidget {
  const AppTitleBar({
    super.key,
    required this.title,
    this.trailing,
    this.leadingInset,
  });

  final String title;
  final Widget? trailing;

  /// Room for the system window buttons, overriding [AppWindowChrome].
  ///
  /// Zero in a window that has no chrome at all whatever the host does — an
  /// overlay panel — which is a property of that window rather than of the
  /// machine, so it is passed rather than looked up.
  final double? leadingInset;

  @override
  Widget build(BuildContext context) => Container(
    height: AppSpacing.titleBarHeight,
    padding: EdgeInsets.only(
      left: leadingInset ?? AppWindowChrome.leadingInsetOf(context),
      right: AppSpacing.titleBarPadding,
    ),
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
