import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../icons/app_icon.dart';
import '../icons/app_icons.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_typography.dart';
import 'app_tag.dart';
import 'blueprint_frame.dart';
import 'hatched_surface.dart';

/// A selectable capture source (design `1a`).
///
/// [thumbnailHeight] carries the design's two sizes: the full-width display
/// entry and the two-column window grid.
class SourceCard extends StatefulWidget {
  const SourceCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onSelected,
    this.thumbnail,
    this.thumbnailHeight = 74,
    this.badge,
    this.titleStyle,
  });

  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onSelected;
  final Uint8List? thumbnail;
  final double thumbnailHeight;

  /// The `Default` tag on the entire-screen entry.
  final String? badge;

  final TextStyle? titleStyle;

  @override
  State<SourceCard> createState() => _SourceCardState();
}

class _SourceCardState extends State<SourceCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bool wide = widget.badge != null;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${widget.title}. ${widget.subtitle}',
      excludeSemantics: true,
      onTap: widget.onSelected,
      child: FocusableActionDetector(
        onShowFocusHighlight: (bool v) => setState(() => _focused = v),
        mouseCursor: SystemMouseCursors.click,
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onSelected();
              return null;
            },
          ),
        },
        child: GestureDetector(
          onTap: widget.onSelected,
          child: BlueprintFrame(
            selected: widget.selected || _focused,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  height: widget.thumbnailHeight,
                  child: DuotoneFilter(
                    child: (widget.thumbnail?.isEmpty ?? true)
                        ? HatchedSurface(stripe: wide ? 7 : 6)
                        : Image.memory(
                            widget.thumbnail!,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          ),
                  ),
                ),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: wide ? 8 : 7,
                    vertical: wide ? 7 : 6,
                  ),
                  decoration: BoxDecoration(
                    // The selected entry tints its caption as well as taking
                    // the outline: an outline alone is easy to miss in a grid
                    // of hairline objects.
                    color: widget.selected
                        ? AppColors.accent.withValues(alpha: 0.10)
                        : null,
                    border: const Border(
                      top: BorderSide(color: AppColors.divider),
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      if (widget.selected) ...<Widget>[
                        const AppIcon(
                          AppIcons.check,
                          size: 13,
                          color: AppColors.accent,
                        ),
                        const SizedBox(width: 6),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  widget.titleStyle ??
                                  AppTypography.bodyEmphasis.copyWith(
                                    fontSize: wide ? 12.5 : 12,
                                    color: widget.selected
                                        ? AppColors.accent800
                                        : AppColors.text,
                                  ),
                            ),
                            Text(
                              widget.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.monoSmall.copyWith(
                                color: AppColors.textMono,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.badge != null) ...<Widget>[
                        const SizedBox(width: 8),
                        AppTag(widget.badge!),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
