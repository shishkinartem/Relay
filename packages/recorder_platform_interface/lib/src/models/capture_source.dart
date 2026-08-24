import 'package:flutter/foundation.dart';

/// The kind of thing being captured.
///
/// A value object rather than a boolean such as `isFullScreen`
/// (`TECHNICAL_SPEC.md` §28). `region` is declared but deferred: the platform
/// layer reports which types it supports through
/// [RecorderCapabilities.supportedSourceTypes].
enum CaptureSourceType {
  /// One entire display. The default source (§4).
  display,

  /// One application window.
  window,

  /// A user-drawn rectangle. Deferred — no MVP platform reports support.
  region,
}

/// One selectable capture target as enumerated by the platform.
@immutable
class CaptureSource {
  const CaptureSource({
    required this.id,
    required this.type,
    required this.title,
    required this.subtitle,
    required this.pixelWidth,
    required this.pixelHeight,
    this.isCurrentDisplay = false,
    this.thumbnail,
  });

  /// Opaque, platform-owned identifier. Never parsed by application code.
  final String id;

  final CaptureSourceType type;

  /// Primary label — the display name, or the owning application name.
  final String title;

  /// Secondary label — display dimensions, or the window title.
  final String subtitle;

  final int pixelWidth;
  final int pixelHeight;

  /// True when this source is the display holding the main application
  /// window (§5). Used to preselect the default source.
  final bool isCurrentDisplay;

  /// Still PNG snapshot for the source list. Refreshed on focus, never streamed
  /// (§4.1). Null when the platform could not produce one.
  final Uint8List? thumbnail;

  double get aspectRatio => pixelHeight == 0 ? 0 : pixelWidth / pixelHeight;

  CaptureSource copyWith({Uint8List? thumbnail}) => CaptureSource(
    id: id,
    type: type,
    title: title,
    subtitle: subtitle,
    pixelWidth: pixelWidth,
    pixelHeight: pixelHeight,
    isCurrentDisplay: isCurrentDisplay,
    thumbnail: thumbnail ?? this.thumbnail,
  );

  @override
  bool operator ==(Object other) =>
      other is CaptureSource && other.id == id && other.type == type;

  @override
  int get hashCode => Object.hash(id, type);

  @override
  String toString() => 'CaptureSource($type, $id, $title)';
}
