import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/formatting/size_estimate.dart';

void main() {
  const RecordingSizeEstimator estimator = RecordingSizeEstimator();

  group('video bitrate', () {
    test('matches the section 12 capacity-planning examples', () {
      expect(estimator.videoBitrateMbps(RecordingQuality.fullHd1080, 30), 4.0);
      expect(estimator.videoBitrateMbps(RecordingQuality.fullHd1080, 60), 8.0);
    });

    test('scales 720p to 45% of 1080p at the same frame rate', () {
      expect(
        estimator.videoBitrateMbps(RecordingQuality.hd720, 30),
        closeTo(1.8, 0.001),
      );
      expect(
        estimator.videoBitrateMbps(RecordingQuality.hd720, 60),
        closeTo(3.6, 0.001),
      );
    });

    test('interpolates an untabulated frame rate linearly from 30 fps', () {
      expect(
        estimator.videoBitrateMbps(RecordingQuality.fullHd1080, 45),
        closeTo(6.0, 0.001),
      );
      expect(
        estimator.videoBitrateMbps(RecordingQuality.fullHd1080, 120),
        closeTo(16.0, 0.001),
        reason: 'the section 12 future 1080p120 example',
      );
    });

    test('stays positive for a nonsensical frame rate', () {
      expect(
        estimator.videoBitrateMbps(RecordingQuality.fullHd1080, 0),
        greaterThan(0),
      );
    });
  });

  group('gigabytesPerHour', () {
    test('reproduces the section 12 table within tolerance', () {
      expect(
        estimator.gigabytesPerHour(RecordingQuality.fullHd1080, 30),
        closeTo(1.88, 0.02),
      );
      expect(
        estimator.gigabytesPerHour(RecordingQuality.fullHd1080, 60),
        closeTo(3.68, 0.02),
      );
    });

    test('includes the audio track', () {
      final double withAudio = estimator.gigabytesPerHour(
        RecordingQuality.fullHd1080,
        30,
      );
      const double videoOnly =
          4.0 * RecordingSizeEstimator.gigabytesPerHourPerMbps;

      expect(withAudio, greaterThan(videoOnly));
      expect(
        withAudio - videoOnly,
        closeTo(
          RecordingSizeEstimator.audioBitrateMbps *
              RecordingSizeEstimator.gigabytesPerHourPerMbps,
          0.0001,
        ),
      );
    });

    test('720p is smaller than 1080p at the same frame rate', () {
      expect(
        estimator.gigabytesPerHour(RecordingQuality.hd720, 30),
        lessThan(estimator.gigabytesPerHour(RecordingQuality.fullHd1080, 30)),
      );
    });
  });

  group('estimatedBytes', () {
    test('scales with duration', () {
      final int hour = estimator.estimatedBytes(
        RecordingQuality.fullHd1080,
        30,
        const Duration(hours: 1),
      );
      final int halfHour = estimator.estimatedBytes(
        RecordingQuality.fullHd1080,
        30,
        const Duration(minutes: 30),
      );

      expect(halfHour * 2, closeTo(hour, 2));
      expect(
        hour / RecordingSizeEstimator.bytesPerGigabyte,
        closeTo(
          estimator.gigabytesPerHour(RecordingQuality.fullHd1080, 30),
          0.001,
        ),
      );
    });

    test('counts the bytes the bitrate physically produces', () {
      // 4 Mbps video + 192 Kbps audio for an hour: the section 12 coefficient
      // is decimal GB, so an hour is bitrate x 3600 / 8 bytes.
      const double bitsPerHour = (4.0 + 0.192) * 1000 * 1000 * 3600;

      expect(
        estimator.estimatedBytes(
          RecordingQuality.fullHd1080,
          30,
          const Duration(hours: 1),
        ),
        closeTo(bitsPerHour / 8, 1),
      );
    });

    test('a one-minute 720p recording matches its bitrate in bytes', () {
      const double bitsPerMinute = (1.8 + 0.192) * 1000 * 1000 * 60;

      expect(
        estimator.estimatedBytes(
          RecordingQuality.hd720,
          30,
          const Duration(minutes: 1),
        ),
        closeTo(bitsPerMinute / 8, 1),
      );
    });

    test('a short recording clears the telegram 50 MB limit', () {
      final int bytes = estimator.estimatedBytes(
        RecordingQuality.hd720,
        30,
        const Duration(minutes: 1),
      );

      expect(bytes, lessThan(50 * 1024 * 1024));
    });
  });

  group('describePerHour', () {
    test('reads as an estimate', () {
      expect(
        estimator.describePerHour(RecordingQuality.fullHd1080, 30),
        '~ 1.9 GB / hour',
      );
      expect(
        estimator.describePerHour(RecordingQuality.fullHd1080, 60),
        '~ 3.7 GB / hour',
      );
      expect(
        estimator.describePerHour(RecordingQuality.hd720, 30),
        '~ 0.9 GB / hour',
      );
    });
  });
}
