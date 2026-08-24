import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// `.radio` — the dot control used by the destination choices.
class AppRadio<T> extends StatefulWidget {
  const AppRadio({
    super.key,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    required this.label,
    this.trailing,
    this.enabled = true,
  });

  final T value;
  final T groupValue;
  final ValueChanged<T>? onChanged;

  /// The row content to the right of the dot.
  final Widget label;

  final Widget? trailing;
  final bool enabled;

  bool get selected => value == groupValue;

  @override
  State<AppRadio<T>> createState() => _AppRadioState<T>();
}

class _AppRadioState<T> extends State<AppRadio<T>> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bool interactive = widget.enabled && widget.onChanged != null;
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: widget.selected,
      enabled: interactive,
      child: FocusableActionDetector(
        enabled: interactive,
        onShowHoverHighlight: (bool v) => setState(() => _hovered = v),
        onShowFocusHighlight: (bool v) => setState(() => _focused = v),
        mouseCursor: interactive
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onChanged?.call(widget.value);
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: interactive ? () => widget.onChanged!(widget.value) : null,
          behavior: HitTestBehavior.opaque,
          child: Row(
            children: <Widget>[
              _RadioDot(
                selected: widget.selected,
                highlighted: _hovered || _focused,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DefaultTextStyle(
                  style: AppTypography.input,
                  child: widget.label,
                ),
              ),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

class _RadioDot extends StatelessWidget {
  const _RadioDot({required this.selected, required this.highlighted});

  final bool selected;
  final bool highlighted;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: AppMotion.instant,
    width: 16,
    height: 16,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: selected ? AppColors.accent : null,
      border: Border.all(
        color: selected || highlighted ? AppColors.accent : AppColors.divider,
        width: 1.5,
      ),
    ),
    // `box-shadow: inset 0 0 0 4px var(--color-bg)`: a 4px ground-coloured ring
    // inside the accent disc, leaving a 5px accent centre.
    child: selected
        ? Center(
            child: Container(
              width: 13,
              height: 13,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.background,
              ),
              child: Center(
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.accent,
                  ),
                ),
              ),
            ),
          )
        : null,
  );
}
