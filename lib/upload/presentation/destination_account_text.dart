import 'package:flutter/widgets.dart';
import 'package:upload_core/upload_core.dart';

import '../../design_system/design_system.dart';

/// Renders a destination's account line, resolved once per destination.
///
/// `describeAccount()` may touch the network, so the future is created in
/// `initState` and only re-created when the destination changes. Building it
/// inside `build` would start a fresh request on every frame and rebuild
/// forever.
class DestinationAccountText extends StatefulWidget {
  const DestinationAccountText({
    super.key,
    required this.destination,
    this.placeholder = 'Not configured',
    this.style,
    this.prefix,
  });

  final UploadDestination destination;
  final String placeholder;
  final TextStyle? style;

  /// Rendered before the account, e.g. the destination's display name.
  final String? prefix;

  @override
  State<DestinationAccountText> createState() => _DestinationAccountTextState();
}

class _DestinationAccountTextState extends State<DestinationAccountText> {
  late Future<String?> _account = widget.destination.describeAccount();

  @override
  void didUpdateWidget(DestinationAccountText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.destination.id != widget.destination.id) {
      _account = widget.destination.describeAccount();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
    future: _account,
    builder: (BuildContext context, AsyncSnapshot<String?> snapshot) {
      final String? account = snapshot.data;
      final String text = account == null
          ? (widget.prefix ?? widget.placeholder)
          : widget.prefix == null
          ? account
          : '${widget.prefix} · $account';
      return Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: widget.style ?? AppTypography.bodySmall,
      );
    },
  );
}
