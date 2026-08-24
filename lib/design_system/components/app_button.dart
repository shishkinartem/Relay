import 'package:flutter/widgets.dart';

import '../icons/app_icon.dart';
import '../icons/app_icons.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'app_tooltip.dart';

/// `.btn-primary` / `.btn-secondary` / `.btn-ghost`.
///
/// The solid accent primary is the system's single deliberately filled object;
/// everything else is a hairline outline or bare text.
enum AppButtonVariant { primary, secondary, ghost }

/// A square, hairline-bordered button on the design system's tokens.
class AppButton extends StatefulWidget {
  const AppButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = AppButtonVariant.secondary,
    this.icon,
    this.expand = false,
    this.height,
    this.fontSize,
    this.busy = false,
    this.semanticLabel,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final AppIconData? icon;

  /// `.btn-block` — fills the available width.
  final bool expand;

  final double? height;
  final double? fontSize;

  /// Disables interaction and shows the pending state while an action runs.
  final bool busy;

  final String? semanticLabel;

  bool get _enabled => onPressed != null && !busy;

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget._enabled;
    final _ButtonPalette palette = _paletteFor(
      widget.variant,
      hovered: enabled && _hovered,
      pressed: enabled && _pressed,
    );

    final Widget content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        if (widget.icon != null) ...<Widget>[
          AppIcon(widget.icon!, size: 15, color: palette.foreground),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.button.copyWith(
              color: palette.foreground,
              fontSize: widget.fontSize,
            ),
          ),
        ),
      ],
    );

    // Merged, so the button is one node carrying the visible text as its label
    // rather than a container with a separate text node inside it. Setting a
    // label here as well would have it announced twice; `semanticLabel`
    // overrides only when the visible text is not the whole story.
    return MergeSemantics(
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.semanticLabel,
        onTap: enabled ? widget.onPressed : null,
        child: FocusableActionDetector(
          enabled: enabled,
          onShowHoverHighlight: (bool value) =>
              setState(() => _hovered = value),
          onShowFocusHighlight: (bool value) =>
              setState(() => _focused = value),
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed?.call();
                return null;
              },
            ),
          },
          child: GestureDetector(
            onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
            onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
            onTapCancel: enabled
                ? () => setState(() => _pressed = false)
                : null,
            onTap: enabled ? widget.onPressed : null,
            child: Opacity(
              opacity: enabled ? 1.0 : 0.45,
              child: _FocusRing(
                visible: _focused,
                child: AnimatedContainer(
                  duration: AppMotion.instant,
                  height: widget.height,
                  width: widget.expand ? double.infinity : null,
                  alignment: Alignment.center,
                  padding: EdgeInsets.symmetric(
                    vertical: widget.height == null ? AppSpacing.x2 : 0,
                    horizontal: widget.variant == AppButtonVariant.ghost
                        ? AppSpacing.x1
                        : AppSpacing.x3 * 1.2,
                  ),
                  decoration: BoxDecoration(
                    color: palette.background,
                    border: Border.all(color: palette.border),
                  ),
                  child: content,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.btn-icon` — the 36x36 square control used by the title bar and the
/// recording strip.
class AppIconButton extends StatefulWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    this.onPressed,
    this.variant = AppButtonVariant.secondary,
    this.size = 36,
    this.width,
    this.iconSize = 15,
    this.foreground,
    this.tooltip,
    this.hitSlop = EdgeInsets.zero,
  });

  final AppIconData icon;
  final String semanticLabel;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final double size;

  /// Overrides the square footprint when the design gives a control a
  /// different width — the ready screen's delete button is 44 x 38.
  final double? width;

  final double iconSize;

  /// Overrides the resolved foreground — used for the muted state, where the
  /// system dims the glyph rather than changing the frame.
  final Color? foreground;

  final String? tooltip;

  /// Transparent padding that belongs to the button's hit target but not to its
  /// drawing.
  ///
  /// The control strip's buttons are 32 px squares separated by 12 px of dead
  /// space, on a window floating over someone else's work. Spending that gap on
  /// the hit target instead costs nothing visually — the caller removes the gap
  /// it would otherwise insert — and stops a click three pixels wide of a
  /// button from doing nothing at all.
  final EdgeInsets hitSlop;

  @override
  State<AppIconButton> createState() => _AppIconButtonState();
}

class _AppIconButtonState extends State<AppIconButton> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onPressed != null;
    final _ButtonPalette palette = _paletteFor(
      widget.variant,
      hovered: enabled && _hovered,
      pressed: enabled && _pressed,
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      onTap: widget.onPressed,
      child: AppTooltip(
        message: widget.tooltip ?? widget.semanticLabel,
        child: FocusableActionDetector(
          enabled: enabled,
          onShowHoverHighlight: (bool value) =>
              setState(() => _hovered = value),
          onShowFocusHighlight: (bool value) =>
              setState(() => _focused = value),
          mouseCursor: enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onPressed?.call();
                return null;
              },
            ),
          },
          child: GestureDetector(
            // Opaque so the transparent hit slop answers a press as readily as
            // the drawn square does.
            behavior: HitTestBehavior.opaque,
            onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
            onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
            onTapCancel: enabled
                ? () => setState(() => _pressed = false)
                : null,
            onTap: widget.onPressed,
            child: Padding(
              padding: widget.hitSlop,
              child: Opacity(
                opacity: enabled ? 1.0 : 0.45,
                child: _FocusRing(
                  visible: _focused,
                  child: AnimatedContainer(
                    duration: AppMotion.instant,
                    width: widget.width ?? widget.size,
                    height: widget.size,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: palette.background,
                      border: Border.all(color: palette.border),
                    ),
                    child: AppIcon(
                      widget.icon,
                      size: widget.iconSize,
                      color: widget.foreground ?? palette.foreground,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ButtonPalette {
  const _ButtonPalette(this.background, this.foreground, this.border);

  final Color background;
  final Color foreground;
  final Color border;
}

_ButtonPalette _paletteFor(
  AppButtonVariant variant, {
  required bool hovered,
  required bool pressed,
}) {
  switch (variant) {
    case AppButtonVariant.primary:
      final Color background = pressed
          ? AppColors.accent700
          : hovered
          ? AppColors.accent600
          : AppColors.accent;
      return _ButtonPalette(background, AppColors.background, background);
    case AppButtonVariant.secondary:
      final Color background = pressed
          ? AppColors.pressedTint
          : hovered
          ? AppColors.hoverTint
          : const Color(0x00000000);
      return _ButtonPalette(background, AppColors.text, AppColors.divider);
    case AppButtonVariant.ghost:
      final Color background = pressed
          ? AppColors.accentPressedTint
          : hovered
          ? AppColors.accentHoverTint
          : const Color(0x00000000);
      return _ButtonPalette(
        background,
        AppColors.accent,
        const Color(0x00000000),
      );
  }
}

/// `:focus-visible { outline: 2px solid accent; outline-offset: 2px }`.
class _FocusRing extends StatelessWidget {
  const _FocusRing({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return child;
    }
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        child,
        Positioned(
          left: -4,
          top: -4,
          right: -4,
          bottom: -4,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: AppColors.accent, width: 2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
