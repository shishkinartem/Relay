import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_spacing.dart';

/// The bordered 8px bar with an accent fill (design `1j`).
///
/// [value] is the *confirmed* fraction. Nothing else may drive it: the upload
/// screen must never show progress the destination has not acknowledged.
class AppProgressBar extends StatelessWidget {
  const AppProgressBar({
    super.key,
    required this.value,
    this.height = 8,
    this.semanticLabel,
  }) : assert(value >= 0 && value <= 1, 'value must be a fraction');

  final double value;
  final double height;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel,
    value: '${(value * 100).round()}%',
    child: Container(
      height: height,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.divider),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: value,
          child: AnimatedContainer(
            duration: AppMotion.quick,
            color: AppColors.accent,
          ),
        ),
      ),
    ),
  );
}

/// An indeterminate variant for the undesigned `preparing` / `finalizing`
/// states — a sweeping accent band inside the same bordered track.
///
/// design gap: the canvas covers neither state, so this stays structurally
/// minimal rather than inventing new UX.
class AppIndeterminateBar extends StatefulWidget {
  const AppIndeterminateBar({super.key, this.height = 8, this.semanticLabel});

  final double height;
  final String? semanticLabel;

  @override
  State<AppIndeterminateBar> createState() => _AppIndeterminateBarState();
}

class _AppIndeterminateBarState extends State<AppIndeterminateBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.semanticLabel,
    child: Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(color: AppColors.divider),
      ),
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (BuildContext context, Widget? child) =>
              FractionallySizedBox(
                widthFactor: 0.3,
                alignment: Alignment(_controller.value * 2 - 1, 0),
                child: const ColoredBox(color: AppColors.accent),
              ),
        ),
      ),
    ),
  );
}
