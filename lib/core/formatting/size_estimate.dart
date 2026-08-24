import 'package:recorder_platform_interface/recorder_platform_interface.dart';

/// Capacity-planning estimate of recording size (§12).
///
/// These are **estimates for planning only**, never an encoder requirement and
/// never a promise about the produced file: real VBR output is much smaller for
/// static UI and larger for high-motion content. Use them to warn about a
/// destination limit, not to gate a recording.
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

  /// The §12 capacity-planning examples for the efficient screen-content
  /// profile, keyed by frame rate.
  static const Map<int, double> fullHdVideoBitrateMbps = <int, double>{
    30: 4.0,
    60: 8.0,
  };

  /// 720p carries about 45% of the 1080p bitrate at the same frame rate.
  static const double hd720BitrateScale = 0.45;

  double videoBitrateMbps(RecordingQuality quality, int frameRate) {
    final double fullHd = _fullHdVideoBitrateMbps(frameRate);
    return quality == RecordingQuality.fullHd1080
        ? fullHd
        : fullHd * hd720BitrateScale;
  }

  double totalBitrateMbps(RecordingQuality quality, int frameRate) =>
      videoBitrateMbps(quality, frameRate) + audioBitrateMbps;

  double gigabytesPerHour(RecordingQuality quality, int frameRate) =>
      totalBitrateMbps(quality, frameRate) * gigabytesPerHourPerMbps;

  int estimatedBytes(
    RecordingQuality quality,
    int frameRate,
    Duration duration,
  ) =>
      (gigabytesPerHour(quality, frameRate) *
              (duration.inMilliseconds / Duration.millisecondsPerHour) *
              bytesPerGigabyte)
          .round();

  /// e.g. `~ 1.9 GB / hour`. The tilde is load-bearing: this is an estimate.
  String describePerHour(RecordingQuality quality, int frameRate) =>
      '~ ${gigabytesPerHour(quality, frameRate).toStringAsFixed(1)} GB / hour';

  /// Frame rates outside the table interpolate linearly from the 30 fps
  /// reference, which reproduces the §12 examples at 60 and 120 fps.
  double _fullHdVideoBitrateMbps(int frameRate) {
    final double? tabulated = fullHdVideoBitrateMbps[frameRate];
    if (tabulated != null) {
      return tabulated;
    }
    final double at30 = fullHdVideoBitrateMbps[30]!;
    final double at60 = fullHdVideoBitrateMbps[60]!;
    final int fps = frameRate < 1 ? 1 : frameRate;
    return at30 + (fps - 30) * (at60 - at30) / 30;
  }
}
