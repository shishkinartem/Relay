/// Output quality preset (§10).
///
/// A preset defines the target canvas policy, not a fixed pixel rectangle: the
/// source aspect ratio is preserved, so only the bounding height is fixed here.
enum RecordingQuality {
  hd720(720, '720p'),
  fullHd1080(1080, '1080p'),

  /// The source's own pixels, scaled by nothing.
  ///
  /// [targetHeight] is `0`, and that sentinel is what crosses the channel: both
  /// hosts decode `quality` as an opaque string and size the canvas from
  /// `targetHeight`, so `0` has to mean "no bounding box" on the far side too.
  ///
  /// This exists because a bounding box is the wrong instrument on a display
  /// whose backing store is denser than its point grid. Capturing a Retina
  /// panel into a 1280x720 or 1920x1080 box resamples text once, before
  /// anything that understands glyphs sees it, and no later bitrate recovers
  /// the stems it smeared.
  native(0, 'Native');

  const RecordingQuality(this.targetHeight, this.label);

  /// Height of the 16:9 reference canvas for this preset, or 0 for [native],
  /// which has no reference canvas.
  final int targetHeight;

  final String label;

  /// Whether the canvas follows the source instead of a preset box.
  bool get followsSourceResolution => targetHeight == 0;

  /// Width of the 16:9 reference canvas. Meaningless for [native].
  int get referenceWidth => (targetHeight * 16 / 9).round();

  static RecordingQuality fromName(String name) => values.firstWhere(
    (RecordingQuality q) => q.name == name,
    orElse: () => RecordingQuality.native,
  );
}
