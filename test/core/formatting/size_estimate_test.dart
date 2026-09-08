import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/formatting/size_estimate.dart';

void main() {
  const RecordingSizeEstimator estimator = RecordingSizeEstimator();

  // The two canvases §12's capacity-planning table is written about. The
  // estimate is taken from a canvas rather than from a preset name, because
  // `RecordingQuality.native` has no fixed height.
  const Size canvas720 = Size(1280, 720);
  const Size canvas1080 = Size(1920, 1080);

  group('video bitrate', () {
    test('reproduces the section 12 capacity-planning examples', () {
      // The per-pixel rule replaced a per-preset table, and it had to land on
      // the numbers §12 publishes or the specification would have gone stale
      // for a change that is meant to be continuous with it.
      expect(
        estimator.videoBitrateMbpsForCanvas(canvas1080, 30),
        closeTo(4.0, 0.05),
      );
      expect(
        estimator.videoBitrateMbpsForCanvas(canvas1080, 60),
        closeTo(8.0, 0.05),
      );
      expect(
        estimator.videoBitrateMbpsForCanvas(canvas720, 30),
        closeTo(1.8, 0.05),
      );
      expect(
        estimator.videoBitrateMbpsForCanvas(canvas720, 60),
        closeTo(3.6, 0.05),
      );
    });

    test('is linear in frame rate, as the section 12 table is', () {
      expect(
        estimator.videoBitrateMbpsForCanvas(canvas1080, 45),
        closeTo(6.0, 0.05),
      );
      expect(
        estimator.videoBitrateMbpsForCanvas(canvas1080, 120),
        closeTo(16.0, 0.2),
        reason: 'the section 12 future 1080p120 example',
      );
    });

    test('is priced per pixel, so a canvas between presets is not', () {
      // The defect this rule replaced: a 1512x982 Retina canvas has 1.6 times
      // the pixels of 720p and used to be given 720p's bitrate, because the old
      // step tested `height >= 1000` and 982 misses it by eighteen lines.
      const Size retina = Size(1512, 982);
      expect(
        estimator.videoBitrateMbpsForCanvas(retina, 30),
        greaterThan(estimator.videoBitrateMbpsForCanvas(canvas720, 30)),
      );
      expect(
        estimator.videoBitrateMbpsForCanvas(retina, 30),
        lessThan(estimator.videoBitrateMbpsForCanvas(canvas1080, 30)),
      );
    });

    test('is clamped at both ends', () {
      expect(
        estimator.videoBitrateMbpsForCanvas(const Size(64, 64), 30),
        RecordingSizeEstimator.minimumVideoBitrateMbps,
      );
      expect(
        estimator.videoBitrateMbpsForCanvas(const Size(7680, 4320), 60),
        RecordingSizeEstimator.maximumVideoBitrateMbps,
      );
    });

    test('stays positive for a nonsensical frame rate', () {
      expect(
        estimator.videoBitrateMbpsForCanvas(canvas1080, 0),
        greaterThan(0),
      );
    });
  });

  group('canvasFor', () {
    test('follows the source for the native preset', () {
      const CaptureSource retina = CaptureSource(
        id: 'display:1',
        type: CaptureSourceType.display,
        title: 'Built-in',
        subtitle: '3024 × 1964',
        pixelWidth: 3024,
        pixelHeight: 1964,
      );

      expect(
        estimator.canvasFor(retina, RecordingQuality.native),
        const Size(3024, 1964),
      );
      // The same display under a preset is bounded by that preset's box, which
      // is the whole difference the native preset exists to make.
      expect(
        estimator.canvasFor(retina, RecordingQuality.hd720)!.height,
        lessThanOrEqualTo(720),
      );
    });

    test('has nothing to describe with no source selected', () {
      expect(estimator.canvasFor(null, RecordingQuality.native), isNull);
    });
  });

  group('gigabytesPerHour', () {
    test('reproduces the section 12 table within tolerance', () {
      expect(estimator.gigabytesPerHour(canvas1080, 30), closeTo(1.88, 0.03));
      expect(estimator.gigabytesPerHour(canvas1080, 60), closeTo(3.68, 0.05));
    });

    test('includes the audio track', () {
      final double withAudio = estimator.gigabytesPerHour(canvas1080, 30);
      final double videoOnly =
          estimator.videoBitrateMbpsForCanvas(canvas1080, 30) *
          RecordingSizeEstimator.gigabytesPerHourPerMbps;

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
        estimator.gigabytesPerHour(canvas720, 30),
        lessThan(estimator.gigabytesPerHour(canvas1080, 30)),
      );
    });
  });

  group('estimatedBytes', () {
    test('scales with duration', () {
      final int hour = estimator.estimatedBytes(
        canvas1080,
        30,
        const Duration(hours: 1),
      );
      final int halfHour = estimator.estimatedBytes(
        canvas1080,
        30,
        const Duration(minutes: 30),
      );

      expect(halfHour * 2, closeTo(hour, 2));
      expect(
        hour / RecordingSizeEstimator.bytesPerGigabyte,
        closeTo(estimator.gigabytesPerHour(canvas1080, 30), 0.001),
      );
    });

    test('counts the bytes the bitrate physically produces', () {
      // The §12 coefficient is decimal GB, so an hour is bitrate x 3600 / 8
      // bytes. Read back from the estimator's own rate rather than a literal,
      // so this stays a statement about the arithmetic and not about the
      // constant.
      final double bitsPerHour =
          (estimator.videoBitrateMbpsForCanvas(canvas1080, 30) +
              RecordingSizeEstimator.audioBitrateMbps) *
          1000 *
          1000 *
          3600;

      expect(
        estimator.estimatedBytes(canvas1080, 30, const Duration(hours: 1)),
        closeTo(bitsPerHour / 8, 1),
      );
    });

    test('a one-minute 720p recording clears the telegram 50 MB limit', () {
      final int bytes = estimator.estimatedBytes(
        canvas720,
        30,
        const Duration(minutes: 1),
      );

      expect(bytes, lessThan(50 * 1024 * 1024));
    });

    test('a native Retina canvas is honest about being far larger', () {
      // The reason the estimate had to stop being a function of the preset
      // name: guessing 720p's number here understated a native recording about
      // six-fold, on the one line the user reads before pressing Start, and it
      // is the number §16's Telegram ceiling is judged against.
      const Size native = Size(3024, 1964);
      final int minuteNative = estimator.estimatedBytes(
        native,
        30,
        const Duration(minutes: 1),
      );

      expect(minuteNative, greaterThan(50 * 1024 * 1024));
      expect(
        minuteNative,
        greaterThan(
          5 *
              estimator.estimatedBytes(
                canvas720,
                30,
                const Duration(minutes: 1),
              ),
        ),
      );
    });
  });

  group('describePerHour', () {
    test('reads as an estimate', () {
      expect(estimator.describePerHour(canvas1080, 30), '~ 1.9 GB / hour');
      expect(estimator.describePerHour(canvas1080, 60), '~ 3.7 GB / hour');
      expect(estimator.describePerHour(canvas720, 30), '~ 0.9 GB / hour');
    });
  });
}
