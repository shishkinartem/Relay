import 'package:flutter/widgets.dart';
import 'package:upload_core/upload_core.dart';

import '../../../../app/app_scope.dart';
import '../../../../design_system/design_system.dart';
import '../../../../upload/presentation/destination_account_text.dart';
import '../../../settings/presentation/settings_screen.dart';

/// `Send to <destination>` with a Change action (design `1c`, `1i`).
///
/// The account line comes from the destination itself, so an unconfigured
/// destination says so instead of the screen guessing.
///
/// Change opens **Settings**, which is where the destination is chosen and
/// where it is connected. A separate picker meant two places that answered the
/// same question and only one of them could set the credentials.
class DestinationSummaryRow extends StatelessWidget {
  const DestinationSummaryRow({super.key, this.kicker = 'Send to'});

  final String kicker;

  @override
  Widget build(BuildContext context) {
    final AppScope scope = AppScope.of(context);
    final UploadDestination destination = scope.destinations.resolve(
      scope.settings.settings.uploadDestinationId,
    );

    return AppRow(
      leading: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppKicker(kicker),
          DestinationAccountText(
            destination: destination,
            prefix: destination.displayName,
          ),
        ],
      ),
      trailing: AppButton(
        label: 'Change',
        variant: AppButtonVariant.ghost,
        fontSize: 12,
        onPressed: () => Navigator.of(context).push<void>(
          PageRouteBuilder<void>(
            transitionDuration: AppMotion.quick,
            pageBuilder: (BuildContext context, _, _) => const SettingsScreen(),
          ),
        ),
      ),
    );
  }
}
