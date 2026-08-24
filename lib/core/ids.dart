import 'dart:math';

final Random _random = Random.secure();

/// A short, collision-resistant identifier for recordings and upload attempts.
///
/// Recording ids end up in file names, so the alphabet is restricted to
/// lowercase hex.
String newId([int bytes = 4]) {
  final StringBuffer buffer = StringBuffer();
  for (int i = 0; i < bytes; i++) {
    buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
