import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../app/app_scope.dart';
import '../../../core/formatting/formatters.dart';
import '../../../design_system/design_system.dart';
import '../../recorder/application/recorder_view_model.dart';
import '../../recorder/domain/recording_naming.dart';
import '../../recorder/domain/session_state.dart';
import '../../recorder/presentation/widgets/destination_summary_row.dart';
import '../../settings/application/settings_controller.dart';
import 'delete_confirmation_dialog.dart';

/// The finalized recording, with Send and Delete (design `1i`, §13).
///
/// The name is editable here and nowhere else: it is the local file name and
/// the name sent to the destination. Renaming moves the file; it never
/// re-finalizes it, so the recording stays valid after a failed upload.
///
/// Keeping the recording is a **fact this screen states and an action it
/// offers**, not something the user has to infer.
///
/// It states it: `On this computer` names the folder the file is in, with a
/// button that opens it. Before, the folder was mentioned only inside a
/// sentence about a differently-named button.
///
/// It offers it twice, because there are two different questions. Without
/// sending, `Keep without sending` is a peer of Send in the footer — it was
/// previously a ghost link in the title bar labelled `New recording`, which
/// named the side effect rather than the intent. And *with* sending,
/// `Keep a copy on this computer` decides whether a confirmed upload still
/// removes the local file; the answer is read once, when Send is pressed
/// (`docs/adr/2026-09-08-keeping-the-local-copy-after-sending.md`).
///
/// §18's deletion rules are unchanged: a local file is still removed only on an
/// explicit Delete or a confirmed upload. The preference narrows the second
/// case; it adds no third trigger.
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
      titleBarTrailing: AppTag(state.everUploaded ? 'Sent' : 'Ready'),
      footer: _Actions(
        state: state,
        onCommitName: _commitName,
        onConfirmDelete: () => _confirmDelete(context, vm, state),
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
          // Where the file is, stated permanently rather than mentioned inside
          // a sentence about a button. The folder is the mono value; the file
          // name is the editable field directly above it, so the two together
          // are the whole location with nothing elided in the middle.
          AppRow(
            leading: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const AppKicker('On this computer'),
                AppTooltip(
                  message: state.recording.path,
                  child: AppMonoText(
                    vm.recordingsDirectoryPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            trailing: AppButton(
              label: 'Open folder',
              variant: AppButtonVariant.ghost,
              fontSize: 12,
              semanticLabel: 'Open the folder this recording is in',
              onPressed: () => unawaited(vm.openRecordingsFolder()),
            ),
          ),
          const AppDivider(margin: EdgeInsets.symmetric(vertical: 12)),
          const DestinationSummaryRow(kicker: 'Destination'),
          const SizedBox(height: 12),
          const _KeepAfterSendingRow(),
          if (state.everUploaded && state.lastError == null) ...<Widget>[
            const SizedBox(height: 12),
            const Center(
              child: AppMonoText(
                'Sent. The copy in the folder above was kept.',
              ),
            ),
          ],
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

/// Whether a confirmed send still removes the local file (§13).
///
/// On this screen rather than only in Settings because this is where the
/// question is live: the user is looking at a finished recording and deciding
/// what Send will do to it. The caption says the answer is remembered, because
/// a control on a per-file screen that silently rewrites a global default is a
/// trap.
class _KeepAfterSendingRow extends StatelessWidget {
  const _KeepAfterSendingRow();

  @override
  Widget build(BuildContext context) {
    final SettingsGateway settings = AppScope.of(context).settings;
    final bool keep = settings.settings.keepLocalCopyAfterSending;

    return AppRow(
      leading: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'Keep a copy on this computer',
            style: AppTypography.fieldLabel.copyWith(
              color: AppColors.textLabel,
            ),
          ),
          const SizedBox(height: 3),
          AppMonoText(
            keep
                ? 'After a confirmed send, the file stays in the folder above.'
                : 'After a confirmed send, the file is removed from the folder '
                      'above.',
            maxLines: 2,
          ),
          const SizedBox(height: 2),
          const AppMonoText('Remembered for every recording.'),
        ],
      ),
      trailing: AppOnOffControl(
        value: keep,
        semanticLabel: 'Keep a copy on this computer after sending',
        onChanged: settings.setKeepLocalCopyAfterSending,
      ),
    );
  }
}

/// Send, Delete and the way out that sends nothing — pinned below the body.
///
/// In the panel's footer rather than in the scrolling column, for the reason
/// [AppPanel.footer] exists: the committing actions must never be something the
/// user has to scroll to find. `Keep without sending` is a full-width peer of
/// Send, where it used to be a ghost link in the title bar named after its side
/// effect. Delete stays a 44-point icon and is deliberately not a peer of
/// either (design `1i`).
class _Actions extends StatelessWidget {
  const _Actions({
    required this.state,
    required this.onCommitName,
    required this.onConfirmDelete,
  });

  final SessionReady state;
  final VoidCallback onCommitName;
  final VoidCallback onConfirmDelete;

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    final bool sent = state.everUploaded;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: AppButton(
                label: sent ? 'Send again' : 'Send',
                icon: AppIcons.send,
                variant: sent
                    ? AppButtonVariant.secondary
                    : AppButtonVariant.primary,
                height: 38,
                onPressed: () {
                  onCommitName();
                  vm.send();
                },
              ),
            ),
            const SizedBox(width: 8),
            AppIconButton(
              icon: AppIcons.delete,
              semanticLabel: 'Delete this recording',
              tooltip: 'Delete this recording',
              size: 38,
              width: 44,
              onPressed: onConfirmDelete,
            ),
          ],
        ),
        const SizedBox(height: 8),
        AppButton(
          label: sent ? 'Done' : 'Keep without sending',
          variant: sent ? AppButtonVariant.primary : AppButtonVariant.secondary,
          expand: true,
          height: 38,
          semanticLabel: sent
              ? 'Done; the recording stays on this computer'
              : 'Keep without sending; the recording stays on this computer '
                    'and the recorder starts a new one',
          onPressed: () {
            onCommitName();
            vm.startNewSession();
          },
        ),
      ],
    );
  }
}
