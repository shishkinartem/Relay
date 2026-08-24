import 'package:flutter/widgets.dart';

import '../icons/app_icon.dart';
import '../icons/app_icons.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// One option of an [AppSegmentedControl].
class AppSegment<T> {
  const AppSegment({
    required this.value,
    required this.label,
    this.icon,
    this.enabled = true,
  });

  final T value;
  final String label;
  final AppIconData? icon;
  final bool enabled;
}

/// `.seg` — the two-option control that carries every per-session choice on
/// the launch screen: source type, quality, frame rate, and each input toggle.
class AppSegmentedControl<T> extends StatelessWidget {
  const AppSegmentedControl({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final List<AppSegment<T>> segments;
  final T value;
  final ValueChanged<T>? onChanged;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final bool enabled = onChanged != null;
    return Semantics(
      label: semanticLabel,
      container: semanticLabel != null,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.divider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < segments.length; i++) ...<Widget>[
                if (i > 0)
                  Container(width: 1, height: 28, color: AppColors.divider),
                _Segment<T>(
                  segment: segments[i],
                  selected: segments[i].value == value,
                  onTap: enabled && segments[i].enabled
                      ? () => onChanged!(segments[i].value)
                      : null,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Segment<T> extends StatefulWidget {
  const _Segment({
    required this.segment,
    required this.selected,
    required this.onTap,
  });

  final AppSegment<T> segment;
  final bool selected;
  final VoidCallback? onTap;

  @override
  State<_Segment<T>> createState() => _SegmentState<T>();
}

class _SegmentState<T> extends State<_Segment<T>> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bool selected = widget.selected;
    final Color background = selected
        ? AppColors.accent
        : _hovered && widget.onTap != null
        ? AppColors.hoverTint
        : const Color(0x00000000);
    final Color foreground = selected ? AppColors.background : AppColors.text;

    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: selected,
      button: true,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        enabled: widget.onTap != null,
        onShowHoverHighlight: (bool v) => setState(() => _hovered = v),
        onShowFocusHighlight: (bool v) => setState(() => _focused = v),
        mouseCursor: widget.onTap != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: AppMotion.instant,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: background,
              border: _focused
                  ? Border.all(color: AppColors.accent, width: 2)
                  : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (widget.segment.icon != null) ...<Widget>[
                  AppIcon(widget.segment.icon!, size: 13, color: foreground),
                  const SizedBox(width: 6),
                ],
                Text(
                  widget.segment.label,
                  style: AppTypography.segment.copyWith(color: foreground),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The on/off segmented control used for microphone, system audio, camera and
/// cursor on the launch screen.
class AppOnOffControl extends StatelessWidget {
  const AppOnOffControl({
    super.key,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) => AppSegmentedControl<bool>(
    semanticLabel: semanticLabel,
    value: value,
    onChanged: onChanged,
    segments: const <AppSegment<bool>>[
      AppSegment<bool>(value: true, label: 'On'),
      AppSegment<bool>(value: false, label: 'Off'),
    ],
  );
}
