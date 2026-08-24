const int _kib = 1024;
const List<String> _byteUnits = <String>['B', 'KB', 'MB', 'GB', 'TB'];
const List<int> _byteUnitDecimals = <int>[0, 0, 0, 2, 2];

/// Human byte size in binary units.
///
/// Precision follows the design's own examples: whole units up to MB
/// (`412 MB`, `648 MB`, `50 MB` in `1n`, `1k` and `1m`) and two decimals from
/// GB up (`1.02 GB` in `1i`).
String formatBytes(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  const int lastUnit = 4;
  double value = bytes.toDouble();
  int unit = 0;
  while (unit < lastUnit && value >= _kib) {
    value /= _kib;
    unit++;
  }
  // Promote when rounding at this unit's precision would print a full unit's
  // worth, e.g. `1024.0 MB` instead of `1.00 GB`.
  if (unit < lastUnit &&
      double.parse(value.toStringAsFixed(_byteUnitDecimals[unit])) >= _kib) {
    value /= _kib;
    unit++;
  }
  return '${value.toStringAsFixed(_byteUnitDecimals[unit])} ${_byteUnits[unit]}';
}

/// `HH:MM:SS` elapsed time for the recording control strip (§6, design 1f).
String formatClock(Duration duration) {
  final Duration elapsed = duration.isNegative ? Duration.zero : duration;
  final String hours = elapsed.inHours.toString().padLeft(2, '0');
  final String minutes = _twoDigits(elapsed.inMinutes.remainder(60));
  final String seconds = _twoDigits(elapsed.inSeconds.remainder(60));
  return '$hours:$minutes:$seconds';
}

/// `MM:SS`, or `H:MM:SS` past the hour — the recording length on the ready
/// screen (design 1i, `14:32`).
String formatShortDuration(Duration duration) {
  final Duration elapsed = duration.isNegative ? Duration.zero : duration;
  final String minutes = _twoDigits(elapsed.inMinutes.remainder(60));
  final String seconds = _twoDigits(elapsed.inSeconds.remainder(60));
  if (elapsed.inHours == 0) {
    return '$minutes:$seconds';
  }
  return '${elapsed.inHours}:$minutes:$seconds';
}

/// `YYYY-MM-DD-HHmm` for default recording names, e.g.
/// `recording-2026-08-22-1422`.
String formatFileTimestamp(DateTime timestamp) {
  final String year = timestamp.year.toString().padLeft(4, '0');
  final String month = _twoDigits(timestamp.month);
  final String day = _twoDigits(timestamp.day);
  final String hour = _twoDigits(timestamp.hour);
  final String minute = _twoDigits(timestamp.minute);
  return '$year-$month-$day-$hour$minute';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');
