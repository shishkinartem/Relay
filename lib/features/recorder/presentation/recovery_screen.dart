import 'package:flutter/widgets.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../app/app_scope.dart';
import '../../../core/formatting/formatters.dart';
import '../../../design_system/design_system.dart';
import '../application/recorder_view_model.dart';

/// Shown once at launch when an unfinished `.part` artefact is found
/// (design `1n`, §18).
///
/// Never auto-deletes and never auto-finalizes: data-loss behaviour stays
/// explicit and user-initiated.
class RecoveryScreen extends StatelessWidget {
  const RecoveryScreen({super.key, required this.artifact});

  final IncompleteRecordingArtifact artifact;

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;

    return AppPanel(
      title: 'Recorder',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const AppKicker('Unfinished recording found'),
          const SizedBox(height: 11),
          BlueprintFrame(
            padding: const EdgeInsets.all(11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                AppMonoText(
                  artifact.path.split(RegExp(r'[\\/]')).last,
                  fontSize: 11.5,
                  color: AppColors.text,
                ),
                const SizedBox(height: 4),
                AppMonoText(
                  '${_relative(artifact.modifiedAt)} · '
                  '${formatBytes(artifact.sizeBytes)} · not finalized',
                ),
              ],
            ),
          ),
          const SizedBox(height: 13),
          Text(
            'The app closed before this recording was written out. Finalizing '
            'may recover most of it; nothing is deleted unless you choose to.',
            style: AppTypography.bodyXSmall.copyWith(color: AppColors.ink(70)),
          ),
          const SizedBox(height: 13),
          Row(
            children: <Widget>[
              Expanded(
                child: AppButton(
                  label: 'Try to finalize',
                  variant: AppButtonVariant.primary,
                  height: 38,
                  busy: vm.isBusy,
                  onPressed: () => vm.recoverArtifact(artifact),
                ),
              ),
              const SizedBox(width: 8),
              AppButton(
                label: 'Keep as is',
                height: 38,
                onPressed: vm.keepArtifacts,
              ),
            ],
          ),
          const SizedBox(height: 4),
          AppButton(
            label: 'Discard file',
            variant: AppButtonVariant.ghost,
            fontSize: 12,
            expand: true,
            onPressed: () => vm.discardArtifact(artifact),
          ),
        ],
      ),
    );
  }

  static String _relative(DateTime at) {
    final DateTime now = DateTime.now();
    final Duration age = now.difference(at);
    final String clock =
        '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    if (age.inDays == 0 && now.day == at.day) {
      return 'today $clock';
    }
    if (age.inDays <= 1) {
      return 'yesterday $clock';
    }
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')} $clock';
  }
}
