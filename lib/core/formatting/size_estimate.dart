import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:recorder_platform_interface/recorder_platform_interface.dart';

/// Capacity-planning estimate of recording size (§12).
///
/// These are **estimates for planning only**, never an encoder requirement and
/// never a promise about the produced file: real VBR output is much smaller for
/// static UI and larger for high-motion content. Use them to warn about a
/// destination limit, not to gate a recording.
///
/// The estimate is taken from the **canvas**, not from the quality preset. A
/// preset was enough while every preset named a fixed height; it stopped being
/// enough with [RecordingQuality.native], whose canvas is not known until a
/// source is picked and which on a Retina display is four times the pixels of
/// the preset that used to stand in for it. Guessing from the enum there would
/// understate a 14-inch MacBook's native recording roughly six-fold — on the
/// one line the user reads before pressing Start, and the number §16's 50 MB
/// Telegram ceiling rests on.
class RecordingSizeEstimator {
  const RecordingSizeEstimator();

  /// `size_GB_per_hour ~= total_bitrate_Mbps * 0.45` (§12).
  ///
  /// Decimal GB by construction: 1 Mbps for an hour is 3600 Mbit = 0.45 GB.
  static const double gigabytesPerHourPerMbps = 0.45;

  /// The unit of [gigabytesPerHourPerMbps] is the decimal gigabyte.
  static const int bytesPerGigabyte = 1000 * 1000 * 1000;

  /// ~192 Kbps AAC, the mixed microphone + system audio track (§8, §11).
  static const double audioBitrateMbps = 0.192;

  /// Bits per pixel per frame for screen content — the same constant both
  /// platforms actually encode with (§11), so the estimate and the file agree.
  ///
  /// It reproduces §12's two published anchors to under one percent:
  /// 1280x720 at 30 fps is 1.78 Mbps against the table's 1.8, and 1920x1080 at
  /// 30 fps is 4.01 against its 4.0. That is why a per-pixel rule could replace
  /// the old per-preset table without moving any number the specification
  /// quotes.
  static const double bitsPerPixelPerFrame = 0.0645;

  /// Floor and ceiling, matching the encoders. The floor keeps a small window
  /// watchable; the ceiling is the file-size and encoder-level guard.
  static const double minimumVideoBitrateMbps = 1.5;
  static const double maximumVideoBitrateMbps = 40.0;

  /// The canvas a recording of [source] at [quality] would encode.
  ///
  /// Null when no source is selected: there is no canvas to describe yet, and
  /// inventing one would put a confident number under a Start button that
  /// cannot be pressed.
  Size? canvasFor(CaptureSource? source, RecordingQuality quality) {
    if (source == null) {
      return null;
    }
    return const VideoCompositionConfiguration().resolveCanvasSize(
      sourceWidth: source.pixelWidth,
      sourceHeight: source.pixelHeight,
      quality: quality,
    );
  }

  double videoBitrateMbpsForCanvas(Size canvas, int frameRate) {
    final double pixels =
        math.max(2, canvas.width) * math.max(2, canvas.height);
    final double rate = math.max(1, frameRate).toDouble();
    final double mbps = bitsPerPixelPerFrame * pixels * rate / 1000000;
    return mbps.clamp(minimumVideoBitrateMbps, maximumVideoBitrateMbps);
  }

  double totalBitrateMbps(Size canvas, int frameRate) =>
      videoBitrateMbpsForCanvas(canvas, frameRate) + audioBitrateMbps;

  double gigabytesPerHour(Size canvas, int frameRate) =>
      totalBitrateMbps(canvas, frameRate) * gigabytesPerHourPerMbps;

  int estimatedBytes(Size canvas, int frameRate, Duration duration) =>
      (gigabytesPerHour(canvas, frameRate) *
              (duration.inMilliseconds / Duration.millisecondsPerHour) *
              bytesPerGigabyte)
          .round();

  /// e.g. `~ 1.9 GB / hour`. The tilde is load-bearing: this is an estimate.
  String describePerHour(Size canvas, int frameRate) =>
      '~ ${gigabytesPerHour(canvas, frameRate).toStringAsFixed(1)} GB / hour';
}
