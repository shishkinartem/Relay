import 'package:flutter/foundation.dart';

/// One drawable primitive of an icon.
///
/// Icons are described exactly as the design canvas describes them — Lucide
/// inline SVG — so the glyph in the app is the glyph in the design rather than
/// a lookalike from an icon font.
@immutable
sealed class IconShape {
  const IconShape({this.filled = false});

  final bool filled;
}

class IconPath extends IconShape {
  const IconPath(this.data, {super.filled});

  final String data;
}

class IconRect extends IconShape {
  const IconRect(this.x, this.y, this.width, this.height, {super.filled});

  final double x;
  final double y;
  final double width;
  final double height;
}

class IconCircle extends IconShape {
  const IconCircle(this.cx, this.cy, this.r, {super.filled});

  final double cx;
  final double cy;
  final double r;
}

/// An icon on the design system's 24x24 viewBox.
@immutable
class AppIconData {
  const AppIconData(this.shapes, {this.viewBox = 24});

  final List<IconShape> shapes;
  final double viewBox;
}

/// The Lucide subset the design uses, at stroke-width 1.5.
abstract final class AppIcons {
  static const AppIconData settings = AppIconData(<IconShape>[
    IconCircle(12, 12, 3),
    IconPath(
      'M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 '
      '1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 '
      '0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 '
      '1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 '
      '0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 '
      '1.65 0 0 0 9 4.6 1.65 1.65 0 0 0 10 3.09V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 '
      '1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 '
      '0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 '
      '0-1.51 1z',
    ),
  ]);

  static const IconPath _micBody = IconPath(
    'M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3z',
  );

  static const AppIconData microphone = AppIconData(<IconShape>[
    _micBody,
    IconPath('M19 10v2a7 7 0 0 1-14 0v-2M12 19v3'),
  ]);

  static const AppIconData microphoneOff = AppIconData(<IconShape>[
    _micBody,
    IconPath('M19 10v2a7 7 0 0 1-14 0v-2M12 19v3M2 2l20 20'),
  ]);

  static const IconPath _speakerBody = IconPath('M11 5 6 9H2v6h4l5 4V5z');

  static const AppIconData systemAudio = AppIconData(<IconShape>[
    _speakerBody,
    IconPath('M19.1 4.9a10 10 0 0 1 0 14.2M15.5 8.5a5 5 0 0 1 0 7'),
  ]);

  /// design gap: the canvas never draws system audio in its off state. The
  /// slash matches how the system draws microphone-off and camera-off.
  static const AppIconData systemAudioOff = AppIconData(<IconShape>[
    _speakerBody,
    IconPath('M19.1 4.9a10 10 0 0 1 0 14.2M15.5 8.5a5 5 0 0 1 0 7M2 2l20 20'),
  ]);

  static const IconPath _cameraLens = IconPath('m23 7-7 5 7 5V7z');

  static const AppIconData camera = AppIconData(<IconShape>[
    _cameraLens,
    IconRect(1, 5, 15, 14),
  ]);

  static const AppIconData cameraOff = AppIconData(<IconShape>[
    _cameraLens,
    IconRect(1, 5, 15, 14),
    IconPath('M2 22 22 2'),
  ]);

  static const AppIconData cursor = AppIconData(<IconShape>[
    IconPath('m4 2 14 12-6 1 3.5 6.5-2.5 1.3L9.5 16 4 20V2z'),
  ]);

  static const AppIconData chevronDown = AppIconData(<IconShape>[
    IconPath('m6 9 6 6 6-6'),
  ]);

  static const AppIconData check = AppIconData(<IconShape>[
    IconPath('M20 6 9 17l-5-5'),
  ]);

  static const AppIconData close = AppIconData(<IconShape>[
    IconPath('M18 6 6 18M6 6l12 12'),
  ]);

  static const AppIconData record = AppIconData(<IconShape>[
    IconCircle(12, 12, 7, filled: true),
  ]);

  static const AppIconData pause = AppIconData(<IconShape>[
    IconRect(6, 4, 4, 16, filled: true),
    IconRect(14, 4, 4, 16, filled: true),
  ]);

  static const AppIconData stop = AppIconData(<IconShape>[
    IconRect(5, 5, 14, 14, filled: true),
  ]);

  static const AppIconData play = AppIconData(<IconShape>[
    IconPath('m6 4 14 8-14 8V4z', filled: true),
  ]);

  static const AppIconData send = AppIconData(<IconShape>[
    IconPath('M12 19V5M5 12l7-7 7 7'),
  ]);

  static const AppIconData delete = AppIconData(<IconShape>[
    IconPath('M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6'),
  ]);

  static const AppIconData warning = AppIconData(<IconShape>[
    IconPath('M12 9v4M12 17h.01'),
    IconPath(
      'M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z',
    ),
  ]);
}
