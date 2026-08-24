import 'package:flutter/widgets.dart';

import '../../../core/formatting/formatters.dart';
import '../../../design_system/design_system.dart';

/// Shown only when the recording has never been uploaded (design `1l`).
///
/// Post-upload cleanup is automatic and silent, so this appears at most once
/// per recording.
class DeleteConfirmationDialog extends StatelessWidget {
  const DeleteConfirmationDialog({
    super.key,
    required this.duration,
    required this.sizeBytes,
  });

  final Duration duration;
  final int sizeBytes;

  @override
  Widget build(BuildContext context) => AppDialog(
    title: 'Delete this recording?',
    body:
        '${formatShortDuration(duration)} · ${formatBytes(sizeBytes)}. '
        'It has not been uploaded, and this cannot be undone.',
    actions: <Widget>[
      AppButton(
        label: 'Keep',
        onPressed: () => Navigator.of(context).pop(false),
      ),
      AppButton(
        label: 'Delete',
        variant: AppButtonVariant.primary,
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ],
  );
}
