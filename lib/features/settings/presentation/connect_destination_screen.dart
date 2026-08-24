import 'package:flutter/widgets.dart';
import 'package:upload_core/upload_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/app_scope.dart';
import '../../../core/logging/app_logger.dart';
import '../../../design_system/design_system.dart';

/// Connects one upload destination (§15, §16, §17).
///
/// Every destination describes its own [DestinationSetup] — the steps, the
/// fields, the name of the action — so this screen renders any destination and
/// adding one later touches nothing here
/// (`docs/architecture/uploads.md`).
class ConnectDestinationScreen extends StatefulWidget {
  const ConnectDestinationScreen({super.key, required this.destination});

  final UploadDestination destination;

  @override
  State<ConnectDestinationScreen> createState() =>
      _ConnectDestinationScreenState();
}

class _ConnectDestinationScreenState extends State<ConnectDestinationScreen> {
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};

  bool _loading = true;
  bool _busy = false;
  bool _connected = false;
  String? _account;
  String? _error;
  String? _errorDetail;

  DestinationSetup get _setup => widget.destination.setup;

  @override
  void initState() {
    super.initState();
    for (final DestinationField field in _setup.fields) {
      _controllers[field.key] = TextEditingController();
    }
    _load();
  }

  @override
  void dispose() {
    for (final TextEditingController controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final Map<String, String> values = await widget.destination
        .storedSetupValues();
    final bool connected = await widget.destination.isConnected();
    final String? account = await widget.destination.describeAccount();
    if (!mounted) {
      return;
    }
    for (final DestinationField field in _setup.fields) {
      // A secret is written once and never read back out for display, so its
      // field stays empty and an empty submission means "keep what you have".
      if (!field.secret) {
        _controllers[field.key]!.text = values[field.key] ?? '';
      }
    }
    setState(() {
      _loading = false;
      _connected = connected;
      _account = account;
    });
  }

  Future<void> _connect() async {
    // Read before the first await: the scope is looked up through the element
    // tree, which this widget may have left by the time the flow returns.
    final Logger logger = AppScope.of(context).logger;
    setState(() {
      _busy = true;
      _error = null;
      _errorDetail = null;
    });
    try {
      await widget.destination.connect(<String, String>{
        for (final DestinationField field in _setup.fields)
          field.key: _controllers[field.key]!.text,
      });
      for (final DestinationField field in _setup.fields) {
        if (field.secret) {
          _controllers[field.key]!.clear();
        }
      }
      await _load();
    } on UploadError catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _errorDetail = error.details;
        });
      }
    } on Object catch (error) {
      // Something no destination anticipated. The detail is shown rather than
      // swallowed: "check the values and your network" is what this used to
      // say, and it is advice, not information — it cannot distinguish a
      // mistyped credential from a keychain that refused to open. Destinations
      // redact their own secrets before throwing (§26, §27).
      logger.error(
        'destination_connect_failed',
        fields: <String, Object?>{
          'destinationId': widget.destination.id,
          'error': error.runtimeType.toString(),
        },
      );
      if (mounted) {
        setState(() {
          _error =
              'The connection could not be completed. Relay was not expecting '
              'this failure, so the reason is reported as it arrived:';
          _errorDetail = '${error.runtimeType}: $error';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _disconnect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.destination.disconnect();
      await _load();
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final DestinationSetup setup = _setup;
    return AppPanel(
      title: widget.destination.displayName,
      titleBarTrailing: AppButton(
        label: 'Back',
        variant: AppButtonVariant.ghost,
        fontSize: 12,
        onPressed: () => Navigator.of(context).pop(),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const AppKicker('Connection'),
          const SizedBox(height: 9),
          AppRow(
            leading: Text(
              widget.destination.displayName,
              style: AppTypography.bodyEmphasis,
            ),
            trailing: AppTag(
              _loading
                  ? 'Checking'
                  : _connected
                  ? 'Connected'
                  : 'Not connected',
              tone: _connected ? AppTagTone.accent : AppTagTone.outline,
            ),
          ),
          const SizedBox(height: 4),
          AppMonoText(_account ?? 'No account is configured yet.'),
          const AppDivider(margin: EdgeInsets.symmetric(vertical: 12)),
          const AppKicker('How to connect'),
          const SizedBox(height: 7),
          for (int index = 0; index < setup.steps.length; index++) ...<Widget>[
            _Step(number: index + 1, text: setup.steps[index]),
            const SizedBox(height: 7),
          ],
          if (setup.helpUrl != null) ...<Widget>[
            const SizedBox(height: 1),
            AppButton(
              label: setup.helpLabel,
              variant: AppButtonVariant.ghost,
              fontSize: 12,
              onPressed: () => launchUrl(
                setup.helpUrl!,
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],
          if (setup.fields.isNotEmpty) ...<Widget>[
            const AppDivider(margin: EdgeInsets.symmetric(vertical: 12)),
            const AppKicker('Credentials'),
            const SizedBox(height: 9),
            for (final DestinationField field in setup.fields) ...<Widget>[
              AppTextField(
                controller: _controllers[field.key]!,
                label: field.optional
                    ? '${field.label} (optional)'
                    : field.label,
                obscureText: field.secret,
                monospace: field.secret,
                semanticLabel: field.label,
              ),
              if (field.hint != null) ...<Widget>[
                const SizedBox(height: 4),
                AppMonoText(field.hint!),
              ],
              if (field.helpUrl != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: AppButton(
                    label: field.helpLabel ?? 'How to get this',
                    variant: AppButtonVariant.ghost,
                    fontSize: 12,
                    onPressed: () => launchUrl(
                      field.helpUrl!,
                      mode: LaunchMode.externalApplication,
                    ),
                  ),
                ),
              const SizedBox(height: 11),
            ],
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 2),
            _ErrorNote(message: _error!, detail: _errorDetail),
            const SizedBox(height: 11),
          ],
          Row(
            children: <Widget>[
              Expanded(
                child: AppButton(
                  label: setup.actionLabel,
                  variant: AppButtonVariant.primary,
                  expand: true,
                  busy: _busy,
                  onPressed: _loading || _busy ? null : _connect,
                ),
              ),
              if (_connected) ...<Widget>[
                const SizedBox(width: 8),
                AppButton(
                  label: 'Disconnect',
                  onPressed: _busy ? null : _disconnect,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      SizedBox(
        width: 18,
        child: AppMonoText('$number.', color: AppColors.accent),
      ),
      Expanded(child: Text(text, style: AppTypography.bodySmall)),
    ],
  );
}

/// The reason a connection was refused, in the destination's own words.
///
/// The same accent-framed warning the failed-upload screen uses (design `1k`);
/// the system has no separate danger colour.
class _ErrorNote extends StatelessWidget {
  const _ErrorNote({required this.message, this.detail});

  final String message;

  /// The service's own words, or the unexpected failure as it arrived.
  final String? detail;

  @override
  Widget build(BuildContext context) => BlueprintFrame(
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
              Text(message, style: AppTypography.bodySmall),
              if (detail != null) ...<Widget>[
                const SizedBox(height: 5),
                AppMonoText(detail!),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
