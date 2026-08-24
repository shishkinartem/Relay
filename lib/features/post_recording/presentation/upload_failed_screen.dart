import 'package:flutter/widgets.dart';
import 'package:upload_core/upload_core.dart';

import '../../../app/app_scope.dart';
import '../../../core/errors/error_presentation.dart';
import '../../../core/formatting/formatters.dart';
import '../../../design_system/design_system.dart';
import '../../recorder/application/recorder_view_model.dart';
import '../../recorder/domain/session_state.dart';
import '../../settings/presentation/settings_screen.dart';

/// A failed upload with the local file intact (design `1k`, §13 failure rule).
///
/// Nothing is deleted and there is no automatic retry loop.
class UploadFailedScreen extends StatelessWidget {
  const UploadFailedScreen({super.key, required this.state});

  final SessionUploadFailed state;

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    final ErrorPresentation copy = ErrorPresentation.forUpload(state.error);
    // A destination that cannot take the file at all is not worth retrying;
    // changing destination is the way forward (§16 preflight failure).
    final bool retryFirst =
        state.error.kind != UploadErrorKind.fileTooLarge &&
        state.error.kind != UploadErrorKind.notConfigured;

    final Widget retry = AppButton(
      label: state.canResume ? 'Resume upload' : 'Try again',
      variant: retryFirst
          ? AppButtonVariant.primary
          : AppButtonVariant.secondary,
      height: 38,
      onPressed: () => vm.send(destinationId: state.destinationId),
    );
    final Widget change = AppButton(
      label: 'Change destination',
      variant: retryFirst
          ? AppButtonVariant.secondary
          : AppButtonVariant.primary,
      height: 38,
      onPressed: () => Navigator.of(context).push<void>(
        PageRouteBuilder<void>(
          transitionDuration: AppMotion.quick,
          pageBuilder: (BuildContext context, _, _) => const SettingsScreen(),
        ),
      ),
    );

    return AppPanel(
      title: 'Recorder',
      titleBarTrailing: const AppTag('Failed', tone: AppTagTone.outline),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          BlueprintFrame(
            borderColor: AppColors.accent,
            padding: const EdgeInsets.all(11),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.only(top: 2),
                  child: AppIcon(
                    AppIcons.warning,
                    size: 17,
                    color: AppColors.accent700,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(copy.title, style: AppTypography.h5),
                      const SizedBox(height: 2),
                      Text(
                        copy.body,
                        style: AppTypography.bodyXSmall.copyWith(
                          color: AppColors.ink(70),
                        ),
                      ),
                      if (copy.technical != null) ...<Widget>[
                        const SizedBox(height: 6),
                        AppMonoText(copy.technical!),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          AppFactTable(
            facts: <AppFact>[
              AppFact(
                'Local file',
                'retained · ${formatBytes(state.recording.sizeBytes)}',
              ),
              AppFact(
                'Uploaded',
                '${formatBytes(state.bytesConfirmed)} confirmed',
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(child: retryFirst ? retry : change),
              const SizedBox(width: 8),
              retryFirst ? change : retry,
            ],
          ),
          const SizedBox(height: 4),
          AppButton(
            label: 'Keep the file and decide later',
            variant: AppButtonVariant.ghost,
            fontSize: 12,
            expand: true,
            onPressed: vm.keepRecordingForLater,
          ),
        ],
      ),
    );
  }
}
