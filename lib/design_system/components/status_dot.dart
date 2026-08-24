import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';

/// A small filled-or-outlined state marker.
///
/// The recording indicator on the control strip: filled while recording, an
/// empty outline while paused — the same distinction the strip makes with its
/// frame colour, so the state is legible twice. The preflight borrows the
/// outline for a permission nobody has answered yet, where a cross would
/// report a failure that has not happened.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.active, this.size = 8});

  final bool active;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: active ? AppColors.recordingIndicator : null,
      border: active ? null : Border.all(color: AppColors.neutral600),
    ),
  );
}
