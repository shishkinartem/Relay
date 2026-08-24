import 'dart:math' as math;
import 'dart:ui';

/// Minimal SVG path-data parser.
///
/// The design system is Lucide inline SVG on `currentColor`. Rather than
/// approximate those glyphs with a different icon font, the exact path data
/// from the canvas is drawn directly, so an icon in the app is the icon in the
/// design.
///
/// Supports the command set Lucide actually emits: `M m L l H h V v C c S s
/// Q q T t A a Z z`.
Path parseSvgPath(String data) {
  final _PathScanner scanner = _PathScanner(data);
  final Path path = Path();
  Offset current = Offset.zero;
  Offset start = Offset.zero;
  Offset? lastCubicControl;
  Offset? lastQuadraticControl;
  String command = '';

  while (!scanner.atEnd) {
    final String? next = scanner.tryCommand();
    if (next != null) {
      command = next;
    } else if (command.isEmpty) {
      break;
    } else if (command == 'M') {
      command = 'L';
    } else if (command == 'm') {
      command = 'l';
    }

    final bool relative = command.toLowerCase() == command;
    Offset resolve(double x, double y) =>
        relative ? Offset(current.dx + x, current.dy + y) : Offset(x, y);

    switch (command.toUpperCase()) {
      case 'M':
        final Offset p = resolve(scanner.number(), scanner.number());
        path.moveTo(p.dx, p.dy);
        current = start = p;
        lastCubicControl = lastQuadraticControl = null;
      case 'L':
        final Offset p = resolve(scanner.number(), scanner.number());
        path.lineTo(p.dx, p.dy);
        current = p;
        lastCubicControl = lastQuadraticControl = null;
      case 'H':
        final double x = scanner.number();
        final Offset p = Offset(relative ? current.dx + x : x, current.dy);
        path.lineTo(p.dx, p.dy);
        current = p;
        lastCubicControl = lastQuadraticControl = null;
      case 'V':
        final double y = scanner.number();
        final Offset p = Offset(current.dx, relative ? current.dy + y : y);
        path.lineTo(p.dx, p.dy);
        current = p;
        lastCubicControl = lastQuadraticControl = null;
      case 'C':
        final Offset c1 = resolve(scanner.number(), scanner.number());
        final Offset c2 = resolve(scanner.number(), scanner.number());
        final Offset p = resolve(scanner.number(), scanner.number());
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p.dx, p.dy);
        current = p;
        lastCubicControl = c2;
        lastQuadraticControl = null;
      case 'S':
        final Offset c1 = lastCubicControl == null
            ? current
            : Offset(
                2 * current.dx - lastCubicControl.dx,
                2 * current.dy - lastCubicControl.dy,
              );
        final Offset c2 = resolve(scanner.number(), scanner.number());
        final Offset p = resolve(scanner.number(), scanner.number());
        path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p.dx, p.dy);
        current = p;
        lastCubicControl = c2;
        lastQuadraticControl = null;
      case 'Q':
        final Offset c = resolve(scanner.number(), scanner.number());
        final Offset p = resolve(scanner.number(), scanner.number());
        path.quadraticBezierTo(c.dx, c.dy, p.dx, p.dy);
        current = p;
        lastQuadraticControl = c;
        lastCubicControl = null;
      case 'T':
        final Offset c = lastQuadraticControl == null
            ? current
            : Offset(
                2 * current.dx - lastQuadraticControl.dx,
                2 * current.dy - lastQuadraticControl.dy,
              );
        final Offset p = resolve(scanner.number(), scanner.number());
        path.quadraticBezierTo(c.dx, c.dy, p.dx, p.dy);
        current = p;
        lastQuadraticControl = c;
        lastCubicControl = null;
      case 'A':
        final double rx = scanner.number();
        final double ry = scanner.number();
        final double rotation = scanner.number();
        final bool largeArc = scanner.flag();
        final bool sweep = scanner.flag();
        final Offset p = resolve(scanner.number(), scanner.number());
        _arcTo(path, current, p, rx, ry, rotation, largeArc, sweep);
        current = p;
        lastCubicControl = lastQuadraticControl = null;
      case 'Z':
        path.close();
        current = start;
        lastCubicControl = lastQuadraticControl = null;
      default:
        return path;
    }
  }
  return path;
}

/// Endpoint-to-centre arc conversion, per the SVG implementation notes.
void _arcTo(
  Path path,
  Offset from,
  Offset to,
  double rx,
  double ry,
  double rotationDegrees,
  bool largeArc,
  bool sweep,
) {
  if (rx == 0 || ry == 0 || from == to) {
    path.lineTo(to.dx, to.dy);
    return;
  }
  rx = rx.abs();
  ry = ry.abs();
  final double phi = rotationDegrees * math.pi / 180.0;
  final double cosPhi = math.cos(phi);
  final double sinPhi = math.sin(phi);

  final double dx2 = (from.dx - to.dx) / 2.0;
  final double dy2 = (from.dy - to.dy) / 2.0;
  final double x1p = cosPhi * dx2 + sinPhi * dy2;
  final double y1p = -sinPhi * dx2 + cosPhi * dy2;

  final double lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
  if (lambda > 1) {
    final double scale = math.sqrt(lambda);
    rx *= scale;
    ry *= scale;
  }

  final double sign = largeArc == sweep ? -1.0 : 1.0;
  final double numerator = math.max(
    0.0,
    rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p,
  );
  final double denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
  final double coefficient = denominator == 0
      ? 0
      : sign * math.sqrt(numerator / denominator);

  final double cxp = coefficient * rx * y1p / ry;
  final double cyp = -coefficient * ry * x1p / rx;
  final double cx = cosPhi * cxp - sinPhi * cyp + (from.dx + to.dx) / 2.0;
  final double cy = sinPhi * cxp + cosPhi * cyp + (from.dy + to.dy) / 2.0;

  double angle(double ux, double uy, double vx, double vy) {
    final double dot = ux * vx + uy * vy;
    final double len =
        math.sqrt(ux * ux + uy * uy) * math.sqrt(vx * vx + vy * vy);
    if (len == 0) {
      return 0;
    }
    final double value = (dot / len).clamp(-1.0, 1.0);
    final double result = math.acos(value);
    return (ux * vy - uy * vx) < 0 ? -result : result;
  }

  final double startAngle = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
  double sweepAngle = angle(
    (x1p - cxp) / rx,
    (y1p - cyp) / ry,
    (-x1p - cxp) / rx,
    (-y1p - cyp) / ry,
  );
  if (!sweep && sweepAngle > 0) {
    sweepAngle -= 2 * math.pi;
  } else if (sweep && sweepAngle < 0) {
    sweepAngle += 2 * math.pi;
  }

  // A rotated ellipse cannot be expressed by arcTo's axis-aligned rect, so the
  // arc is emitted as cubic segments of at most a quarter turn each.
  final int segments = math.max(1, (sweepAngle.abs() / (math.pi / 2)).ceil());
  final double delta = sweepAngle / segments;
  final double alpha = 4 / 3 * math.tan(delta / 4);

  double theta = startAngle;
  Offset pointAt(double t) {
    final double x = cx + rx * math.cos(t) * cosPhi - ry * math.sin(t) * sinPhi;
    final double y = cy + rx * math.cos(t) * sinPhi + ry * math.sin(t) * cosPhi;
    return Offset(x, y);
  }

  Offset derivativeAt(double t) {
    final double x = -rx * math.sin(t) * cosPhi - ry * math.cos(t) * sinPhi;
    final double y = -rx * math.sin(t) * sinPhi + ry * math.cos(t) * cosPhi;
    return Offset(x, y);
  }

  for (int i = 0; i < segments; i++) {
    final double t1 = theta;
    final double t2 = theta + delta;
    final Offset p1 = pointAt(t1);
    final Offset p2 = pointAt(t2);
    final Offset d1 = derivativeAt(t1);
    final Offset d2 = derivativeAt(t2);
    path.cubicTo(
      p1.dx + alpha * d1.dx,
      p1.dy + alpha * d1.dy,
      p2.dx - alpha * d2.dx,
      p2.dy - alpha * d2.dy,
      p2.dx,
      p2.dy,
    );
    theta = t2;
  }
}

class _PathScanner {
  _PathScanner(this._data);

  final String _data;
  int _index = 0;

  bool get atEnd {
    _skipSeparators();
    return _index >= _data.length;
  }

  void _skipSeparators() {
    while (_index < _data.length) {
      final int code = _data.codeUnitAt(_index);
      if (code == 0x20 ||
          code == 0x2C ||
          code == 0x09 ||
          code == 0x0A ||
          code == 0x0D) {
        _index++;
      } else {
        break;
      }
    }
  }

  String? tryCommand() {
    _skipSeparators();
    if (_index >= _data.length) {
      return null;
    }
    final String c = _data[_index];
    if (RegExp(r'[MmLlHhVvCcSsQqTtAaZz]').hasMatch(c)) {
      _index++;
      return c;
    }
    return null;
  }

  double number() {
    _skipSeparators();
    final int startIndex = _index;
    if (_index < _data.length &&
        (_data[_index] == '-' || _data[_index] == '+')) {
      _index++;
    }
    while (_index < _data.length && _isDigitOrDot(_data[_index])) {
      _index++;
    }
    if (_index < _data.length &&
        (_data[_index] == 'e' || _data[_index] == 'E')) {
      _index++;
      if (_index < _data.length &&
          (_data[_index] == '-' || _data[_index] == '+')) {
        _index++;
      }
      while (_index < _data.length && _isDigit(_data[_index])) {
        _index++;
      }
    }
    return double.tryParse(_data.substring(startIndex, _index)) ?? 0.0;
  }

  /// Arc flags may be packed without separators (`a10 10 0 0 1 0 14.2`), so a
  /// flag is exactly one character.
  bool flag() {
    _skipSeparators();
    if (_index >= _data.length) {
      return false;
    }
    final String c = _data[_index];
    _index++;
    return c == '1';
  }

  bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  bool _isDigitOrDot(String c) => _isDigit(c) || c == '.';
}
