import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:upload_core/upload_core.dart';

import '../../../app/app_scope.dart';
import '../../../core/formatting/formatters.dart';
import '../../../design_system/design_system.dart';
import '../../../upload/presentation/destination_account_text.dart';
import 'connect_destination_screen.dart';

/// Destination and storage — the only things that outlive a session
/// (design `1m`, §15).
///
/// Quality, frame rate and cursor are not repeated here: they are per-session
/// choices made on the launch screen, which persists its last values.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _folder = TextEditingController();

  /// Bumped when a destination screen returns, so the account lines re-resolve
  /// instead of showing the state from before the user connected.
  int _revision = 0;

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  Future<void> _openConnect(UploadDestination destination) async {
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: AppMotion.quick,
        pageBuilder: (BuildContext context, _, _) =>
            ConnectDestinationScreen(destination: destination),
      ),
    );
    if (mounted) {
      setState(() => _revision++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppScope scope = AppScope.of(context);
    final String selectedId = scope.settings.settings.uploadDestinationId;
    _folder.text =
        scope.settings.settings.localRecordingsDirectory ??
        scope.recorder.defaultRecordingsDirectoryPath;

    return AppPanel(
      title: 'Settings',
      titleBarTrailing: AppButton(
        label: 'Back',
        variant: AppButtonVariant.ghost,
        fontSize: 12,
        onPressed: () => Navigator.of(context).pop(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const AppKicker('Upload destination'),
          const SizedBox(height: 9),
          for (final UploadDestination destination
              in scope.destinations.all) ...<Widget>[
            _DestinationSetting(
              key: ValueKey<String>('${destination.id}-$_revision'),
              destination: destination,
              selected: destination.id == selectedId,
              onSelected: () =>
                  scope.settings.setUploadDestination(destination.id),
              onConnect: () => _openConnect(destination),
            ),
            const SizedBox(height: 10),
          ],
          const AppDivider(margin: EdgeInsets.symmetric(vertical: 6)),
          Text(
            'Local recordings folder',
            style: AppTypography.fieldLabel.copyWith(
              color: AppColors.textLabel,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: <Widget>[
              Expanded(
                child: AppTextField(
                  controller: _folder,
                  readOnly: true,
                  semanticLabel: 'Local recordings folder',
                ),
              ),
              const SizedBox(width: 8),
              AppButton(
                label: 'Choose',
                onPressed: () async {
                  final String? path = await getDirectoryPath(
                    confirmButtonText: 'Choose',
                  );
                  if (path != null) {
                    await scope.settings.setLocalRecordingsDirectory(path);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          const AppMonoText(
            'Changing this affects the next recording. Existing files stay '
            'where they are.',
          ),
        ],
      ),
    );
  }
}

class _DestinationSetting extends StatelessWidget {
  const _DestinationSetting({
    super.key,
    required this.destination,
    required this.selected,
    required this.onSelected,
    required this.onConnect,
  });

  final UploadDestination destination;
  final bool selected;
  final VoidCallback onSelected;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final UploadCapabilities capabilities = destination.capabilities;
    final int? limit = capabilities.maxFileSizeBytes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppRadio<bool>(
          value: true,
          groupValue: selected,
          onChanged: (_) => onSelected(),
          label: Text(destination.displayName),
          trailing: limit == null
              ? null
              : AppTag('${formatBytes(limit)} max', tone: AppTagTone.outline),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 24, top: 2),
          child: Row(
            children: <Widget>[
              Expanded(
                child: DestinationAccountText(
                  destination: destination,
                  placeholder: 'Not connected',
                  style: AppTypography.mono.copyWith(color: AppColors.textMono),
                ),
              ),
              const SizedBox(width: 8),
              // Every destination needs credentials before it can take a
              // recording, and there is nowhere else in the application to
              // supply them (§15, §16, §17).
              AppButton(
                label: 'Set up',
                variant: AppButtonVariant.ghost,
                fontSize: 12,
                onPressed: onConnect,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
