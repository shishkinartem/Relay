import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';

/// `repeating-linear-gradient(135deg, …)` — the system's stand-in for content
/// that is not a real image.
///
/// Used wherever a thumbnail has not arrived yet, so an empty slot still reads
/// as a wireframe object rather than a hole.
class HatchedSurface extends StatelessWidget {
  const HatchedSurface({
    super.key,
    this.stripe = 7,
    this.dark = AppColors.neutral300,
    this.light = AppColors.neutral200,
    this.child,
  });

  final double stripe;
  final Color dark;
  final Color light;
  final Widget? child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _HatchPainter(stripe: stripe, dark: dark, light: light),
    child: child,
  );
}

class _HatchPainter extends CustomPainter {
  const _HatchPainter({
    required this.stripe,
    required this.dark,
    required this.light,
  });

  final double stripe;
  final Color dark;
  final Color light;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = light);
    final Paint paint = Paint()
      ..color = dark
      ..strokeWidth = stripe
      ..style = PaintingStyle.stroke;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final double span = size.width + size.height;
    // 135deg stripes: draw along the down-right diagonal, spaced by 2 x stripe.
    for (double offset = -size.height; offset < span; offset += stripe * 2) {
      canvas.drawLine(
        Offset(offset, 0),
        Offset(offset + size.height, size.height),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HatchPainter oldDelegate) =>
      oldDelegate.stripe != stripe ||
      oldDelegate.dark != dark ||
      oldDelegate.light != light;
}

/// `.duotone` — photographic content washed in the accent, like a screen print.
class DuotoneFilter extends StatelessWidget {
  const DuotoneFilter({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return child;
    }
    // `.duotone` is `overflow: hidden` in the stylesheet, and the clip is not
    // decoration: a colour-filter layer with no clip takes its hue across
    // everything painted inside it, flooding the screen.
    return ClipRect(
      child: ColorFiltered(
        colorFilter: const ui.ColorFilter.mode(
          AppColors.accent,
          BlendMode.color,
        ),
        child: child,
      ),
    );
  }
}
