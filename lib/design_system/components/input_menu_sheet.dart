import 'package:flutter/widgets.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_shadows.dart';
import '../tokens/app_typography.dart';
import 'app_select.dart';
import 'app_text.dart';
import 'camera_preset_tiles.dart';
import 'level_meter.dart';

/// The device list a chevron opens (§33.4, design's device sheet).
///
/// A presentation component: it renders a snapshot and raises one intent. It
/// owns no device state, so the sheet in the overlay window and the sheet in a
/// widget test behave identically.
///
/// Every state it can be in is drawn rather than left blank — loading, empty,
/// a device lost, a level running — because this window floats over someone
/// else's screen and an empty panel there reads as a broken application.
class InputMenuSheet extends StatelessWidget {
  const InputMenuSheet({
    super.key,
    required this.state,
    required this.onChoose,
    this.onChoosePreset,
    this.onChooseCorner,
    this.onResetPosition,
  });

  final InputMenuOverlayState state;
  final ValueChanged<InputMenuItem> onChoose;

  /// The camera sheet's shape presets (§33.4, §33.5). Null in a context that
  /// cannot apply one, which draws no presets rather than dead ones.
  final ValueChanged<CameraPipPreset>? onChoosePreset;
  final ValueChanged<CameraOverlayCorner>? onChooseCorner;
  final VoidCallback? onResetPosition;

  /// The design's sheet width.
  static const double width = 268;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.ink(28)),
        boxShadow: AppShadows.large,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 7),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.divider)),
            ),
            child: AppKicker(state.title),
          ),
          ..._rows(),
          if (state.level != null) _meter(),
          if (state.presets.isNotEmpty && onChoosePreset != null) _shapes(),
          if (state.corners.isNotEmpty && onChooseCorner != null) _corners(),
          if (state.canResetPosition && onResetPosition != null)
            AppOptionTile(
              label: 'Reset position',
              meta: 'lower right',
              selected: false,
              onPressed: onResetPosition!,
            ),
          if (state.notice != null)
            Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
              decoration: BoxDecoration(
                color: AppColors.recordingIndicator.withValues(alpha: 0.06),
                border: const Border(top: BorderSide(color: AppColors.divider)),
              ),
              child: Text(
                state.notice!,
                style: AppTypography.bodyXSmall.copyWith(
                  color: AppColors.ink(80),
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _rows() {
    if (state.loading) {
      return <Widget>[
        // One disabled row while the platform answers — never an empty panel,
        // and never a list that appears to have loaded (§33.7).
        const _Message('Looking for devices…'),
      ];
    }
    final String? empty = state.emptyMessage;
    if (empty != null) {
      return <Widget>[_Message(empty)];
    }
    return <Widget>[
      for (final InputMenuItem item in state.items)
        AppOptionTile(
          label: item.label,
          meta: item.meta,
          selected: item.selected,
          enabled: item.enabled,
          onPressed: () => onChoose(item),
        ),
    ];
  }

  /// The camera's half of the sheet: the three shapes, where the microphone
  /// has its level meter (§33.4).
  ///
  /// Under the device list rather than above it, so the two sheets share one
  /// skeleton — kicker, list, the kind's own control — and a user who has
  /// learned one has learned the other.
  Widget _shapes() => Container(
    padding: const EdgeInsets.fromLTRB(10, 9, 10, 11),
    decoration: BoxDecoration(
      color: AppColors.ink(2),
      border: const Border(top: BorderSide(color: AppColors.divider)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const AppKicker('Shape and size'),
        const SizedBox(height: 7),
        CameraPresetTiles(
          // The default is what the tile is drawn at when nothing has been
          // chosen, which is the same thing the compositor does.
          selected: state.selectedPreset ?? CameraPipPreset.camera,
          onChoose: onChoosePreset!,
          compact: true,
        ),
      ],
    ),
  );

  /// Window mode's placement row (§33.5).
  ///
  /// Four named corners rather than a drag, because in window mode the preview
  /// is a separate captioned object and not the tile (design `1e`): there is
  /// nothing on screen to drag, and nothing that would show where a drag had
  /// put it. A named corner is legible without a preview.
  Widget _corners() => Container(
    padding: const EdgeInsets.fromLTRB(10, 9, 10, 11),
    decoration: BoxDecoration(
      color: AppColors.ink(2),
      border: const Border(top: BorderSide(color: AppColors.divider)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const AppKicker('Position'),
        const SizedBox(height: 7),
        for (int row = 0; row < 2; row++) ...<Widget>[
          if (row > 0) const SizedBox(height: 5),
          Row(
            children: <Widget>[
              for (final CameraOverlayCorner corner
                  in state.corners.skip(row * 2).take(2)) ...<Widget>[
                Expanded(
                  child: _CornerTile(
                    corner: corner,
                    selected: state.selectedCorner == corner,
                    onPressed: () => onChooseCorner!(corner),
                  ),
                ),
                if (corner != state.corners.skip(row * 2).take(2).last)
                  const SizedBox(width: 5),
              ],
            ],
          ),
        ],
      ],
    ),
  );

  Widget _meter() => Container(
    padding: const EdgeInsets.fromLTRB(10, 9, 10, 11),
    decoration: BoxDecoration(
      color: AppColors.ink(2),
      border: const Border(top: BorderSide(color: AppColors.divider)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppKicker(
          state.level!.isSilent ? 'Test — no sound' : 'Test — speak now',
        ),
        const SizedBox(height: 5),
        AppLevelMeter(
          level: state.level!.rms,
          peak: state.level!.peak,
          semanticLabel: '${state.title} level',
        ),
      ],
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    height: 34,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    alignment: Alignment.centerLeft,
    child: Text(
      text,
      style: AppTypography.bodyXSmall.copyWith(color: AppColors.ink(45)),
    ),
  );
}

/// One named corner, drawn as a frame with the tile in the corner it names —
/// the same "show the choice before it is made" rule the shape presets follow.
class _CornerTile extends StatelessWidget {
  const _CornerTile({
    required this.corner,
    required this.selected,
    required this.onPressed,
  });

  final CameraOverlayCorner corner;
  final bool selected;
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
          padding: const EdgeInsets.fromLTRB(7, 6, 7, 6),
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
