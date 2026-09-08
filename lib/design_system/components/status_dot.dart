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
  const StatusDot({super.key, required this.active, this.size = 8, this.color});

  final bool active;
  final double size;

  /// Overrides the marker's colour in both forms.
  ///
  /// The control strip's pre-roll needs it: a dot that is filled but not
  /// [AppColors.recordingIndicator] is the one state that is neither recording
  /// nor paused (§6). Null keeps the two colours this component shipped with —
  /// and `recordingIndicator` is deliberately not reused for a countdown, since
  /// painting a pre-roll red asserts a recording that does not exist.
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: active ? (color ?? AppColors.recordingIndicator) : null,
      border: active ? null : Border.all(color: color ?? AppColors.neutral600),
    ),
  );
}
