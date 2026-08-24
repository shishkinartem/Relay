import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';
import '../tokens/app_typography.dart';

/// One row of an [AppFactTable].
class AppFact {
  const AppFact(this.label, this.value);

  final String label;
  final String value;
}

/// `.table` — label/value rows separated by a whisper of the text colour.
///
/// Used for the upload facts (design `1j`), the failure facts (`1k`) and the
/// picture-in-picture specification (`1h`).
class AppFactTable extends StatelessWidget {
  const AppFactTable({super.key, required this.facts});

  final List<AppFact> facts;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      for (final AppFact fact in facts)
        Container(
          padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.x2,
            horizontal: AppSpacing.x2,
          ),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: AppColors.ink(8))),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(child: Text(fact.label, style: AppTypography.tableCell)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  fact.value,
                  textAlign: TextAlign.right,
                  style: AppTypography.mono.copyWith(color: AppColors.textMono),
                ),
              ),
            ],
          ),
        ),
    ],
  );
}
