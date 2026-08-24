import 'package:flutter/widgets.dart';

import '../../../app/app_scope.dart';
import '../../../core/formatting/formatters.dart';
import '../../../design_system/design_system.dart';
import '../../recorder/application/recorder_view_model.dart';
import '../../recorder/domain/recording_naming.dart';
import '../../recorder/domain/session_state.dart';
import '../../recorder/presentation/widgets/destination_summary_row.dart';
import 'delete_confirmation_dialog.dart';

/// The finalized recording, with Send and Delete (design `1i`, §13).
///
/// The name is editable here and nowhere else: it is the local file name and
/// the name sent to the destination. Renaming moves the file; it never
/// re-finalizes it, so the recording stays valid after a failed upload.
///
/// `New recording` is the third way out, beside Send and Delete: it returns to
/// the recorder ready to start again, and leaves the file exactly where it is.
/// Nothing is uploaded and nothing is deleted — §18 only ever deletes on an
/// explicit Delete or a confirmed upload — so this is the "I will deal with it
/// later" exit that otherwise did not exist.
class ReadyScreen extends StatefulWidget {
  const ReadyScreen({super.key, required this.state});

  final SessionReady state;

  @override
  State<ReadyScreen> createState() => _ReadyScreenState();
}

class _ReadyScreenState extends State<ReadyScreen> {
  late final TextEditingController _name = TextEditingController(
    text: widget.state.name,
  );
  late final FocusNode _nameFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(() {
      if (!_nameFocus.hasFocus) {
        _commitName();
      }
    });
  }

  @override
  void didUpdateWidget(ReadyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state.name != oldWidget.state.name && !_nameFocus.hasFocus) {
      _name.text = widget.state.name;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _commitName() {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    vm.renameRecording(_name.text);
  }

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    final SessionReady state = widget.state;

    return AppPanel(
      title: 'Recorder',
      titleBarTrailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const AppTag('Ready'),
          const SizedBox(width: 8),
          AppButton(
            label: 'New recording',
            variant: AppButtonVariant.ghost,
            fontSize: 12,
            semanticLabel: 'New recording; this one stays on disk',
            onPressed: () {
              _commitName();
              vm.startNewSession();
            },
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          BlueprintFrame(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox(
                  height: 104,
                  child: DuotoneFilter(child: HatchedSurface(stripe: 8)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: AppColors.divider)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: AppTextField(
                              controller: _name,
                              focusNode: _nameFocus,
                              monospace: true,
                              minHeight: 30,
                              semanticLabel: 'Recording name',
                              onSubmitted: (_) => _commitName(),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const AppMonoText('.${RecordingNaming.extension}'),
                        ],
                      ),
                      const SizedBox(height: 5),
                      AppMonoText(_describe(state)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          const DestinationSummaryRow(kicker: 'Destination'),
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: AppButton(
                  label: 'Send',
                  icon: AppIcons.send,
                  variant: AppButtonVariant.primary,
                  height: 38,
                  onPressed: () {
                    _commitName();
                    vm.send();
                  },
                ),
              ),
              const SizedBox(width: 8),
              AppIconButton(
                icon: AppIcons.delete,
                semanticLabel: 'Delete recording',
                size: 38,
                width: 44,
                onPressed: () => _confirmDelete(context, vm, state),
              ),
            ],
          ),
          const SizedBox(height: 9),
          const Center(
            child: AppMonoText('Local file is kept until upload is confirmed'),
          ),
          const SizedBox(height: 3),
          Center(
            child: AppMonoText(
              'New recording keeps this one in '
              '${vm.defaultRecordingsDirectoryPath}',
              textAlign: TextAlign.center,
            ),
          ),
          if (state.lastError != null) ...<Widget>[
            const SizedBox(height: 9),
            Center(
              child: AppMonoText(
                state.lastError!.message,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _describe(SessionReady state) =>
      '${formatShortDuration(state.recording.duration)} · '
      '${state.recording.height}p${state.recording.frameRate} · H.264 / AAC · '
      '${formatBytes(state.recording.sizeBytes)}';

  Future<void> _confirmDelete(
    BuildContext context,
    RecorderViewModel vm,
    SessionReady state,
  ) async {
    // Confirm only while the recording has never been uploaded — the
    // irreversible case (docs/adr/2026-08-22-delete-confirmation.md).
    if (state.everUploaded) {
      await vm.deleteRecording();
      return;
    }
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext context) => DeleteConfirmationDialog(
        duration: state.recording.duration,
        sizeBytes: state.recording.sizeBytes,
      ),
    );
    if (confirmed ?? false) {
      await vm.deleteRecording();
    }
  }
}
