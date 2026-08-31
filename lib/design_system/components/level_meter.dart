import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';

/// design gap: the canvas draws no meter anywhere, in any state — not the live
/// bar, not the dead one §33.7 requires, not the clipping mark. Every one of
/// those is a decision taken here rather than read off a screen:
/// `design/README.md` → *The v0.5 interface has no design backing*.
///
/// The live input level, drawn as a ticked bar (§33.2).
///
/// Two values, not one: [level] fills the bar and is the sustained loudness a
/// user reads as "am I coming through", while [peak] is a hairline marker for
/// the loudest instant, which is what says "too hot" before anything clips.
/// Drawing only the average hides clipping; drawing only the peak jitters.
///
/// A presentation component. It owns no timer, no decay and no device: it draws
/// the numbers it is given, so the same widget renders identically in a test.
class AppLevelMeter extends StatelessWidget {
  const AppLevelMeter({
    super.key,
    required this.level,
    required this.peak,
    required this.semanticLabel,
    this.enabled = true,
    this.height = 8,
  }) : assert(height > 0, 'height must be positive');

  /// Sustained level, `0..1` linear amplitude.
  final double level;

  /// Loudest instant, `0..1` linear amplitude.
  final double peak;

  /// False draws the bar dead — dashed, unfilled.
  ///
  /// The state for "this input is off", "the permission is missing" and
  /// "nothing is metering". Deliberately drawn rather than hidden: a control
  /// that disappears reads as a layout bug, and "off" must not look the same as
  /// "broken" (§33.7).
  final bool enabled;

  final double height;

  final String semanticLabel;

  /// Above this the loudest instant is at the top of the scale, and the tail of
  /// the bar is drawn in the recording colour so clipping is visible as such.
  static const double clippingThreshold = 0.98;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel,
    value: enabled ? '${(level.clamp(0.0, 1.0) * 100).round()}%' : null,
    child: SizedBox(
      height: height,
      child: CustomPaint(
        painter: _LevelMeterPainter(
          level: level.clamp(0.0, 1.0),
          peak: peak.clamp(0.0, 1.0),
          enabled: enabled,
        ),
      ),
    ),
  );
}

class _LevelMeterPainter extends CustomPainter {
  const _LevelMeterPainter({
    required this.level,
    required this.peak,
    required this.enabled,
  });

  final double level;
  final double peak;
  final bool enabled;

  /// One tick every 6 logical pixels — the stylesheet's
  /// `repeating-linear-gradient(90deg, transparent 0 5px, ink 5px 6px)`.
  static const double _tickSpacing = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = Offset.zero & size;

    // Ticks first, so the fill covers them: a filled segment reads as solid,
    // an empty one as ruled.
    final Paint tick = Paint()
      ..color = AppColors.ink(enabled ? 10 : 7)
      ..strokeWidth = 1;
    for (double x = _tickSpacing; x < size.width; x += _tickSpacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), tick);
    }

    if (enabled && level > 0) {
      final double fillWidth = size.width * level;
      final bool clipping = peak >= AppLevelMeter.clippingThreshold;
      canvas.drawRect(
        Rect.fromLTWH(0, 0, fillWidth, size.height),
        Paint()..color = AppColors.accent,
      );
      if (clipping) {
        // Only the tail turns red. A bar that goes red end to end says the
        // input is broken; what actually happened is that the loudest instant
        // reached the top of the scale.
        final double hotStart = size.width * AppLevelMeter.clippingThreshold;
        if (fillWidth > hotStart) {
          canvas.drawRect(
            Rect.fromLTWH(hotStart, 0, fillWidth - hotStart, size.height),
            Paint()..color = AppColors.recordingIndicator,
          );
        }
      }
    }

    if (enabled && peak > 0) {
      // Clamped inside the bar so the marker is still visible at full scale,
      // where an unclamped one would be painted exactly on the border.
      final double x = (size.width * peak).clamp(0.0, size.width - 1);
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 1, size.height),
        Paint()..color = AppColors.accent800,
      );
    }

    final Paint border = Paint()
      ..color = AppColors.divider
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    if (enabled) {
      canvas.drawRect(bounds.deflate(0.5), border);
    } else {
      _drawDashedRect(canvas, bounds.deflate(0.5), border);
    }
  }

  /// The dead bar's dashed outline. Flutter has no dashed stroke, and the
  /// alternative — a solid outline at a lower opacity — reads as an enabled
  /// meter that happens to be quiet, which is the one thing it must not.
  static void _drawDashedRect(Canvas canvas, Rect rect, Paint paint) {
    const double dash = 3;
    const double gap = 3;
    for (double x = rect.left; x < rect.right; x += dash + gap) {
      final double end = (x + dash).clamp(rect.left, rect.right);
      canvas
        ..drawLine(Offset(x, rect.top), Offset(end, rect.top), paint)
        ..drawLine(Offset(x, rect.bottom), Offset(end, rect.bottom), paint);
    }
    for (double y = rect.top; y < rect.bottom; y += dash + gap) {
      final double end = (y + dash).clamp(rect.top, rect.bottom);
      canvas
        ..drawLine(Offset(rect.left, y), Offset(rect.left, end), paint)
        ..drawLine(Offset(rect.right, y), Offset(rect.right, end), paint);
    }
  }

  @override
  bool shouldRepaint(_LevelMeterPainter oldDelegate) =>
      oldDelegate.level != level ||
      oldDelegate.peak != peak ||
      oldDelegate.enabled != enabled;
}
