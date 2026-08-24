import 'package:flutter/widgets.dart';

import '../../../../design_system/design_system.dart';

/// An icon, a label and a control — the launch screen's repeated row.
class LabelledControlRow extends StatelessWidget {
  const LabelledControlRow({
    super.key,
    required this.icon,
    required this.label,
    required this.control,
  });

  final AppIconData icon;
  final String label;
  final Widget control;

  @override
  Widget build(BuildContext context) => AppRow(
    leading: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppIcon(icon, size: 15),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.bodySmall,
          ),
        ),
      ],
    ),
    trailing: control,
  );
}
