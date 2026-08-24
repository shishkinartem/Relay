import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/formatting/formatters.dart';

const int _kib = 1024;
const int _mib = 1024 * _kib;
const int _gib = 1024 * _mib;

void main() {
  group('formatBytes', () {
    test('formats bytes and kilobytes without decimals', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(-1), '0 B');
      expect(formatBytes(1), '1 B');
      expect(formatBytes(1023), '1023 B');
      expect(formatBytes(_kib), '1 KB');
      expect(formatBytes(_kib * 512), '512 KB');
    });

    test('formats megabytes with one decimal', () {
      expect(formatBytes(_mib), '1 MB');
      expect(formatBytes(_mib * 412), '412 MB');
      expect(formatBytes((_mib * 648.5).round()), '649 MB');
    });

    test('formats gigabytes with two decimals', () {
      expect(formatBytes((_gib * 1.02).round()), '1.02 GB');
      expect(formatBytes(_gib), '1.00 GB');
      expect(formatBytes(_gib * 3), '3.00 GB');
    });

    test('crosses each unit threshold at the right byte count', () {
      expect(formatBytes(_kib - 1), '1023 B');
      expect(formatBytes(_mib - 1), '1 MB');
      expect(formatBytes(_gib - 1), '1.00 GB');
      expect(formatBytes(_gib * _kib), '1.00 TB');
    });

    test(
      'promotes rather than printing a full unit worth of the smaller one',
      () {
        expect(formatBytes(_gib - _mib), '1023 MB');
        expect(formatBytes(_gib - 1024), '1.00 GB');
      },
    );
  });

  group('formatClock', () {
    test('always pads the hour', () {
      expect(formatClock(Duration.zero), '00:00:00');
      expect(formatClock(const Duration(seconds: 5)), '00:00:05');
      expect(formatClock(const Duration(minutes: 14, seconds: 32)), '00:14:32');
    });

    test('rolls over an hour', () {
      expect(
        formatClock(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '01:02:03',
      );
      expect(
        formatClock(const Duration(hours: 12, minutes: 59, seconds: 59)),
        '12:59:59',
      );
      expect(formatClock(const Duration(hours: 100)), '100:00:00');
    });

    test('drops sub-second precision and clamps negatives', () {
      expect(formatClock(const Duration(milliseconds: 1999)), '00:00:01');
      expect(formatClock(const Duration(seconds: -30)), '00:00:00');
    });
  });

  group('formatShortDuration', () {
    test('is MM:SS under an hour', () {
      expect(
        formatShortDuration(const Duration(minutes: 14, seconds: 32)),
        '14:32',
      );
      expect(formatShortDuration(const Duration(seconds: 7)), '00:07');
      expect(
        formatShortDuration(const Duration(minutes: 59, seconds: 59)),
        '59:59',
      );
    });

    test('adds an unpadded hour past the hour', () {
      expect(formatShortDuration(const Duration(hours: 1)), '1:00:00');
      expect(
        formatShortDuration(const Duration(hours: 2, minutes: 5, seconds: 9)),
        '2:05:09',
      );
    });
  });

  group('formatFileTimestamp', () {
    test('is YYYY-MM-DD-HHmm', () {
      expect(
        formatFileTimestamp(DateTime(2026, 8, 22, 14, 22)),
        '2026-08-22-1422',
      );
    });

    test('pads every component', () {
      expect(
        formatFileTimestamp(DateTime(2026, 1, 2, 3, 4)),
        '2026-01-02-0304',
      );
      expect(
        formatFileTimestamp(DateTime(2026, 12, 31, 23, 59)),
        '2026-12-31-2359',
      );
    });

    test('composes the default recording name', () {
      expect(
        'recording-${formatFileTimestamp(DateTime(2026, 8, 22, 14, 22, 51))}',
        'recording-2026-08-22-1422',
      );
    });
  });
}
