import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import 'app_icons.dart';
import 'svg_path_parser.dart';

/// Renders an [AppIconData] at [size], scaled from its 24-unit viewBox.
///
/// Stroke width is expressed in viewBox units and scaled with the icon, which
/// is what keeps a 13px strip icon and a 17px alert icon looking like the same
/// family — the design system's stroke-width 1.5.
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.icon, {
    super.key,
    this.size = 15,
    this.color,
    this.strokeWidth = 1.5,
    this.semanticLabel,
  });

  final AppIconData icon;
  final double size;
  final Color? color;
  final double strokeWidth;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Color resolved =
        color ?? DefaultTextStyle.of(context).style.color ?? AppColors.text;
    final Widget painted = SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _AppIconPainter(
          icon: icon,
          color: resolved,
          strokeWidth: strokeWidth,
        ),
      ),
    );
    if (semanticLabel == null) {
      return ExcludeSemantics(child: painted);
    }
    return Semantics(label: semanticLabel, image: true, child: painted);
  }
}

class _AppIconPainter extends CustomPainter {
  _AppIconPainter({
    required this.icon,
    required this.color,
    required this.strokeWidth,
  });

  final AppIconData icon;
  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final double scale = size.shortestSide / icon.viewBox;
    canvas.save();
    canvas.scale(scale);

    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color
      ..isAntiAlias = true;
    final Paint fill = Paint()
      ..style = PaintingStyle.fill
      ..color = color
      ..isAntiAlias = true;

    for (final IconShape shape in icon.shapes) {
      final Paint paint = shape.filled ? fill : stroke;
      switch (shape) {
        case IconPath(:final String data):
          canvas.drawPath(parseSvgPath(data), paint);
        case IconRect(
          :final double x,
          :final double y,
          :final double width,
          :final double height,
        ):
          canvas.drawRect(Rect.fromLTWH(x, y, width, height), paint);
        case IconCircle(:final double cx, :final double cy, :final double r):
          canvas.drawCircle(Offset(cx, cy), r, paint);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AppIconPainter oldDelegate) =>
      oldDelegate.icon != icon ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth;
}
