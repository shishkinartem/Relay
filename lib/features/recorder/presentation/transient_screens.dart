import 'package:flutter/widgets.dart';

import '../../../app/app_scope.dart';
import '../../../core/errors/error_presentation.dart';
import '../../../design_system/design_system.dart';
import '../application/recorder_view_model.dart';
import '../domain/session_state.dart';

/// The states the connected design does not cover.
///
/// design gap: `preparing`, `stopping`, `finalizing`, `deleting` and the fatal
/// capture errors have no designed screen. These are deliberately minimal and
/// built only from existing components, so replacing them with designed
/// screens later is a swap rather than a rewrite
/// (`docs/development/design-system.md` → *Missing states*).
class TransientScreen extends StatelessWidget {
  const TransientScreen({
    super.key,
    required this.kicker,
    required this.message,
  });

  final String kicker;
  final String message;

  @override
  Widget build(BuildContext context) => AppPanel(
    title: 'Recorder',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppKicker(kicker),
        const SizedBox(height: 12),
        const AppIndeterminateBar(semanticLabel: 'Working'),
        const SizedBox(height: 10),
        AppMonoText(message),
      ],
    ),
  );
}

/// A fatal capture failure. Any partial artefact stays on disk (§18).
class CaptureFailureScreen extends StatelessWidget {
  const CaptureFailureScreen({super.key, required this.state});

  final SessionFailed state;

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    final ErrorPresentation copy = ErrorPresentation.forRecorder(
      state.code,
      state.message,
    );

    return AppPanel(
      title: 'Recorder',
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
          if (state.retainedArtifactPath != null) ...<Widget>[
            const SizedBox(height: 14),
            AppFactTable(
              facts: <AppFact>[
                const AppFact('Partial recording', 'kept on disk'),
                AppFact(
                  'Location',
                  state.retainedArtifactPath!.split(RegExp(r'[\\/]')).last,
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          AppButton(
            label: 'Back',
            variant: AppButtonVariant.primary,
            expand: true,
            height: 38,
            onPressed: vm.startNewSession,
          ),
        ],
      ),
    );
  }
}
