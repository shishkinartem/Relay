/// Output quality preset (§10).
///
/// A preset defines the target canvas policy, not a fixed pixel rectangle: the
/// source aspect ratio is preserved, so only the bounding height is fixed here.
enum RecordingQuality {
  hd720(720, '720p'),
  fullHd1080(1080, '1080p');

  const RecordingQuality(this.targetHeight, this.label);

  /// Height of the 16:9 reference canvas for this preset.
  final int targetHeight;

  final String label;

  /// Width of the 16:9 reference canvas.
  int get referenceWidth => (targetHeight * 16 / 9).round();

  static RecordingQuality fromName(String name) => values.firstWhere(
    (RecordingQuality q) => q.name == name,
    orElse: () => RecordingQuality.hd720,
  );
}
