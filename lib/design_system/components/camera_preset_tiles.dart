import 'package:flutter/widgets.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_typography.dart';

/// The camera picture-in-picture's three shapes, as a row of tiles (§33.5).
///
/// Shared rather than duplicated because the same three choices are offered in
/// two places that cannot see each other: the launch screen's camera section,
/// and the camera sheet the strip's chevron opens during recording. Two drawings
/// of one choice drift, and the drift is invisible until someone opens both.
///
/// A presentation component: it renders a selection and raises an intent, so it
/// works identically inside a widget test, the main window and an overlay
/// engine.
class CameraPresetTiles extends StatelessWidget {
  const CameraPresetTiles({
    super.key,
    required this.selected,
    required this.onChoose,
    this.compact = false,
  });

  final CameraPipPreset selected;
  final ValueChanged<CameraPipPreset> onChoose;

  /// The overlay sheet is 268 points wide and stacked under a device list; the
  /// launch screen has a whole panel. Compact drops the second line and tightens
  /// the padding rather than shrinking the type, because the labels have to stay
  /// legible over whatever is being recorded.
  final bool compact;

  /// The label and the caption each preset carries, in the design's order.
  static const List<(CameraPipPreset, String, String)> presets =
      <(CameraPipPreset, String, String)>[
        (CameraPipPreset.camera, 'Camera', '16% · whole frame'),
        (CameraPipPreset.square, 'Square', '10% · cropped'),
        (CameraPipPreset.circle, 'Circle', '10% · cropped'),
      ];

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      for (final (CameraPipPreset preset, String label, String meta)
          in presets) ...<Widget>[
        Expanded(
          child: _PresetTile(
            preset: preset,
            label: label,
            meta: compact ? null : meta,
            selected: selected == preset,
            onPressed: () => onChoose(preset),
          ),
        ),
        if (preset != CameraPipPreset.circle) const SizedBox(width: 7),
      ],
    ],
  );
}

class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.label,
    required this.meta,
    required this.selected,
    required this.onPressed,
  });

  final CameraPipPreset preset;
  final String label;
  final String? meta;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: '$label picture-in-picture',
    excludeSemantics: true,
    onTap: onPressed,
    child: GestureDetector(
      onTap: onPressed,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: meta == null
              ? const EdgeInsets.fromLTRB(6, 7, 6, 6)
              : const EdgeInsets.fromLTRB(6, 8, 6, 7),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.divider,
            ),
            color: selected ? AppColors.accentHoverTint : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _Shape(preset: preset),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.bodyXSmall.copyWith(
                  fontSize: 10.5,
                  color: selected ? AppColors.accent800 : AppColors.text,
                  fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
              if (meta != null)
                Text(
                  meta!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.monoSmall.copyWith(
                    fontSize: 9,
                    color: AppColors.textKicker,
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The tile at each preset's proportions — the same three shapes the design
/// draws, so the choice is legible before it is made.
class _Shape extends StatelessWidget {
  const _Shape({required this.preset});

  final CameraPipPreset preset;

  @override
  Widget build(BuildContext context) => switch (preset) {
    CameraPipPreset.camera => Container(
      width: 30,
      height: 17,
      color: AppColors.accent700,
    ),
    CameraPipPreset.square => Container(
      width: 18,
      height: 18,
      color: AppColors.accent700,
    ),
    CameraPipPreset.circle => Container(
      width: 18,
      height: 18,
      decoration: const BoxDecoration(
        color: AppColors.accent700,
        shape: BoxShape.circle,
      ),
    ),
  };
}
