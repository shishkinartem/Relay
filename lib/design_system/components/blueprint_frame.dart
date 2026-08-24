import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';

/// The system's signature object: a square, transparent, hairline-bordered
/// surface with registration marks at its corners (`.blueprint` + `.corner`).
///
/// The marks are painted exactly where the stylesheet places them — a 11x11
/// cross per corner whose centre sits one pixel outside the frame — including
/// the stylesheet's own left/top asymmetry, so the frame reads identically to
/// the canvas.
class BlueprintFrame extends StatelessWidget {
  const BlueprintFrame({
    super.key,
    required this.child,
    this.showCorners = true,
    this.selected = false,
    this.borderColor,
    this.background,
    this.padding = EdgeInsets.zero,
    this.boxShadow,
  });

  final Widget child;
  final bool showCorners;

  /// Draws the accent selection outline (2px, offset 2px) used by the source
  /// picker and the chosen destination card.
  final bool selected;

  final Color? borderColor;
  final Color? background;
  final EdgeInsetsGeometry padding;
  final List<BoxShadow>? boxShadow;

  @override
  Widget build(BuildContext context) {
    final Widget frame = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: borderColor ?? AppColors.divider),
        boxShadow: boxShadow,
      ),
      child: child,
    );

    if (!showCorners && !selected) {
      return frame;
    }

    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        frame,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _BlueprintOverlayPainter(
                showCorners: showCorners,
                selected: selected,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BlueprintOverlayPainter extends CustomPainter {
  const _BlueprintOverlayPainter({
    required this.showCorners,
    required this.selected,
  });

  final bool showCorners;
  final bool selected;

  static const double _armLength = 11;
  static const double _inset = 6;
  static const double _crossOffset = 5;

  @override
  void paint(Canvas canvas, Size size) {
    if (selected) {
      final Paint outline = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = AppColors.accent;
      // Inset by half the stroke so the ring is fully inside the card's own
      // bounds: drawn outside, a neighbouring grid cell paints over it.
      canvas.drawRect(
        Rect.fromLTWH(1, 1, size.width - 2, size.height - 2),
        outline,
      );
    }
    if (!showCorners) {
      return;
    }

    final Paint mark = Paint()..color = AppColors.registrationMark;
    final double w = size.width;
    final double h = size.height;

    // Box origins for the four marks, mirroring the stylesheet's placement.
    final List<Offset> origins = <Offset>[
      const Offset(-_inset, -_inset),
      Offset(w + _inset - _armLength, -_inset),
      Offset(-_inset, h + _inset - _armLength),
      Offset(w + _inset - _armLength, h + _inset - _armLength),
    ];

    for (final Offset origin in origins) {
      canvas.drawRect(
        Rect.fromLTWH(origin.dx + _crossOffset, origin.dy, 1, _armLength),
        mark,
      );
      canvas.drawRect(
        Rect.fromLTWH(origin.dx, origin.dy + _crossOffset, _armLength, 1),
        mark,
      );
    }
  }

  @override
  bool shouldRepaint(_BlueprintOverlayPainter oldDelegate) =>
      oldDelegate.showCorners != showCorners ||
      oldDelegate.selected != selected;
}
