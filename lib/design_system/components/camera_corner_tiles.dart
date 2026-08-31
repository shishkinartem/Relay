import 'package:flutter/widgets.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_typography.dart';

/// The four named places the camera picture-in-picture can be put (§33.5).
///
/// Shared rather than duplicated, for the same reason [CameraPresetTiles] is:
/// the same four choices are offered in two places that cannot see each other
/// — the launch screen's camera section, and the camera sheet the strip's
/// chevron opens during recording. Two drawings of one choice drift, and the
/// drift is invisible until someone opens both.
///
/// **design gap:** the connected design has no camera placement control of any
/// kind — nor a `Shape and size` block, which is the same gap. Both post-date
/// it. This draws each corner the way the preset tiles draw each shape, which
/// is the nearest thing the design system does say; see `design/README.md`.
///
/// A presentation component: it renders a selection and raises an intent, so it
/// works identically inside a widget test, the main window and an overlay
/// engine.
class CameraCornerTiles extends StatelessWidget {
  const CameraCornerTiles({
    super.key,
    required this.selected,
    required this.onChoose,
    this.corners = CameraOverlayCorner.values,
    this.compact = false,
  });

  /// The corner drawn as chosen, or null where none is — a tile sitting at a
  /// free position it was dragged to is in none of the four.
  final CameraOverlayCorner? selected;
  final ValueChanged<CameraOverlayCorner> onChoose;

  /// What the caller has to offer, in the order it offers it. Taken rather than
  /// assumed so the sheet draws exactly the snapshot it was pushed.
  final List<CameraOverlayCorner> corners;

  /// The overlay sheet is 268 points wide and stacked under a device list; the
  /// launch screen has a whole panel. Compact tightens the padding rather than
  /// shrinking the type, because the labels have to stay legible over whatever
  /// is being recorded — the same trade [CameraPresetTiles] makes.
  final bool compact;

  /// Two rows of two, which is the shape of the thing being chosen: a list of
  /// four would name the corners without showing where any of them is.
  static const int _perRow = 2;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      for (int row = 0; row * _perRow < corners.length; row++) ...<Widget>[
        if (row > 0) const SizedBox(height: 5),
        Row(
          children: <Widget>[
            for (final CameraOverlayCorner corner
                in corners.skip(row * _perRow).take(_perRow)) ...<Widget>[
              Expanded(
                child: _CornerTile(
                  corner: corner,
                  selected: selected == corner,
                  compact: compact,
                  onPressed: () => onChoose(corner),
                ),
              ),
              if (corner != corners.skip(row * _perRow).take(_perRow).last)
                const SizedBox(width: 5),
            ],
          ],
        ),
      ],
    ],
  );
}

/// One named corner, drawn as a frame with the tile in the corner it names —
/// the same "show the choice before it is made" rule the shape presets follow.
class _CornerTile extends StatelessWidget {
  const _CornerTile({
    required this.corner,
    required this.selected,
    required this.compact,
    required this.onPressed,
  });

  final CameraOverlayCorner corner;
  final bool selected;
  final bool compact;
  final VoidCallback onPressed;

  static const Map<CameraOverlayCorner, Alignment> _alignments =
      <CameraOverlayCorner, Alignment>{
        CameraOverlayCorner.topLeft: Alignment.topLeft,
        CameraOverlayCorner.topRight: Alignment.topRight,
        CameraOverlayCorner.bottomLeft: Alignment.bottomLeft,
        CameraOverlayCorner.bottomRight: Alignment.bottomRight,
      };

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '${corner.label} picture-in-picture',
    excludeSemantics: true,
    onTap: onPressed,
    child: GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: compact
              ? const EdgeInsets.fromLTRB(7, 6, 7, 6)
              : const EdgeInsets.fromLTRB(7, 8, 7, 8),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.divider,
            ),
            color: selected ? AppColors.accentHoverTint : null,
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 22,
                height: 14,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.ink(28)),
                ),
                alignment: _alignments[corner],
                child: Container(
                  width: 7,
                  height: 5,
                  color: AppColors.accent700,
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  corner.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.bodyXSmall.copyWith(
                    fontSize: 10.5,
                    color: selected ? AppColors.accent800 : AppColors.text,
                    fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
