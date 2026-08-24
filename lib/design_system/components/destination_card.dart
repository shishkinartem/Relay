import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';
import 'app_radio.dart';
import 'app_tag.dart';
import 'blueprint_frame.dart';

/// An upload destination choice, rendered from its own capabilities
/// (design `1o`).
///
/// The badge and the note are supplied by the caller from
/// `UploadCapabilities`, never decided here — a destination whose limit is
/// lifted stops showing a limit with no change to this component.
class DestinationCard extends StatelessWidget {
  const DestinationCard({
    super.key,
    required this.name,
    required this.account,
    required this.note,
    required this.selected,
    required this.onSelected,
    this.badge,
    this.badgeTone = AppTagTone.accent,
    this.accepted = true,
  });

  final String name;
  final String account;
  final String note;
  final bool selected;
  final VoidCallback onSelected;
  final String? badge;
  final AppTagTone badgeTone;

  /// False dims the card: the destination cannot take this file, and the user
  /// learns that before Send rather than mid-upload.
  final bool accepted;

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: accepted ? 1 : 0.6,
    child: BlueprintFrame(
      padding: const EdgeInsets.all(11),
      borderColor: selected ? AppColors.accent : AppColors.divider,
      background: selected ? AppColors.accent.withValues(alpha: 0.08) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppRadio<bool>(
            value: true,
            groupValue: selected,
            onChanged: (_) => onSelected(),
            trailing: badge == null ? null : AppTag(badge!, tone: badgeTone),
            label: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  name,
                  style: AppTypography.bodyEmphasis.copyWith(fontSize: 13.5),
                ),
                Text(
                  account,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.mono.copyWith(
                    fontSize: 10.5,
                    color: AppColors.textMono,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.x1 * 2),
          Text(
            note,
            style: AppTypography.mono.copyWith(color: AppColors.textMono),
          ),
        ],
      ),
    ),
  );
}
