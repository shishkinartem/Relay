import 'package:flutter/widgets.dart';

import '../../../app/app_scope.dart';
import '../../../core/formatting/formatters.dart';
import '../../../design_system/design_system.dart';
import '../../recorder/application/recorder_view_model.dart';
import '../../recorder/domain/recording_naming.dart';
import '../../recorder/domain/session_state.dart';

/// Upload in flight (design `1j`).
///
/// Progress is bytes the destination has confirmed, so it never shows 100%
/// before the remote object exists.
class UploadingScreen extends StatelessWidget {
  const UploadingScreen({super.key, required this.state});

  final SessionUploading state;

  @override
  Widget build(BuildContext context) {
    final AppScope scope = AppScope.of(context);
    final RecorderViewModel vm = scope.recorder;
    final String destinationName = scope.destinations
        .resolve(state.destinationId)
        .displayName;

    return AppPanel(
      title: 'Recorder',
      titleBarTrailing: const AppTag('Uploading'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          AppMonoText(
            RecordingNaming.fileName(state.name),
            fontSize: 11.5,
            color: AppColors.text,
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                '${(state.fraction * 100).round()}%',
                style: AppTypography.numericDisplay,
              ),
              const Spacer(),
              AppMonoText(
                '${formatBytes(state.bytesSent)} of '
                '${formatBytes(state.totalBytes)}',
              ),
            ],
          ),
          const SizedBox(height: 7),
          AppProgressBar(
            value: state.fraction,
            semanticLabel: 'Upload progress',
          ),
          const SizedBox(height: 7),
          AppMonoText(_transportLine(destinationName)),
          const SizedBox(height: 16),
          AppFactTable(
            facts: <AppFact>[
              const AppFact('Validated', 'size ok for this destination'),
              AppFact('Retries', '${state.retries}'),
              const AppFact('On success', 'delete local file'),
            ],
          ),
          const SizedBox(height: 14),
          AppButton(
            label: state.cancelling ? 'Cancelling…' : 'Cancel upload',
            expand: true,
            height: 38,
            onPressed: state.cancelling ? null : vm.cancelUpload,
          ),
        ],
      ),
    );
  }

  String _transportLine(String destinationName) {
    final StringBuffer buffer = StringBuffer(destinationName);
    if (state.resumed) {
      buffer.write(' · resumed session');
    }
    if (state.chunkIndex != null && state.chunkCount != null) {
      buffer.write(' · chunk ${state.chunkIndex} / ${state.chunkCount}');
    }
    return buffer.toString();
  }
}
