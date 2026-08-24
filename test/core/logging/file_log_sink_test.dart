import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/logging/app_logger.dart';
import 'package:relay/core/logging/file_log_sink.dart';

/// A record with a body of a known size, so a rotation threshold can be
/// reached in a countable number of writes rather than approximately.
LogRecord recordOf(String event) => LogRecord(
  level: LogLevel.info,
  event: event,
  timestamp: DateTime.utc(2026, 8, 23, 12),
);

void main() {
  late Directory directory;
  late File logFile;
  late File previousFile;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('relay_log_');
    logFile = File('${directory.path}/relay.log');
    previousFile = File('${logFile.path}.1');
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  group('writing', () {
    test('a record reaches the file and survives the sink', () async {
      // The whole point of this sink: the ring buffer dies with the process,
      // and the process dying is the case you wanted diagnostics for.
      final FileLogSink? sink = await FileLogSink.open(logFile);
      expect(sink, isNotNull);

      sink!.write(recordOf('recording_started'));
      await sink.close();

      expect(logFile.readAsStringSync(), contains('recording_started'));
    });

    test('the parent directory is created rather than assumed', () async {
      final File nested = File('${directory.path}/logs/deeper/relay.log');
      final FileLogSink? sink = await FileLogSink.open(nested);
      expect(sink, isNotNull);

      sink!.write(recordOf('nested'));
      await sink.close();

      expect(nested.readAsStringSync(), contains('nested'));
    });

    test('an existing file is appended to, not truncated', () async {
      logFile.writeAsStringSync('earlier session\n');

      final FileLogSink? sink = await FileLogSink.open(logFile);
      sink!.write(recordOf('later_session'));
      await sink.close();

      final String contents = logFile.readAsStringSync();
      expect(contents, contains('earlier session'));
      expect(contents, contains('later_session'));
    });

    test('records are written in the order they were logged', () async {
      final FileLogSink? sink = await FileLogSink.open(logFile);
      for (int i = 0; i < 20; i++) {
        sink!.write(recordOf('event_$i'));
      }
      await sink!.close();

      final List<String> lines = logFile
          .readAsLinesSync()
          .where((String line) => line.isNotEmpty)
          .toList(growable: false);
      expect(lines, hasLength(20));
      expect(lines.first, contains('event_0'));
      expect(lines.last, contains('event_19'));
    });
  });

  group('bounds', () {
    test('the file rotates instead of growing without limit', () async {
      // A recorder runs for hours. An unbounded log on the user's disk is the
      // same defect as an unbounded frame queue, and this is the assertion
      // that keeps it from becoming one.
      final FileLogSink? sink = await FileLogSink.open(logFile, maxBytes: 512);

      for (int i = 0; i < 200; i++) {
        sink!.write(recordOf('padding_event_number_$i'));
      }
      await sink!.close();

      expect(
        previousFile.existsSync(),
        isTrue,
        reason: 'rotated at least once',
      );
      expect(logFile.lengthSync(), lessThanOrEqualTo(512 * 2));
      expect(previousFile.lengthSync(), lessThanOrEqualTo(512 * 2));
    });

    test('exactly one previous generation is kept', () async {
      final FileLogSink? sink = await FileLogSink.open(logFile, maxBytes: 256);
      for (int i = 0; i < 400; i++) {
        sink!.write(recordOf('event_$i'));
      }
      await sink!.close();

      final List<String> logs =
          directory
              .listSync()
              .whereType<File>()
              .map((File f) => f.path.split(Platform.pathSeparator).last)
              .toList(growable: false)
            ..sort();
      expect(logs, <String>['relay.log', 'relay.log.1']);
    });

    test('a file already at the cap rotates before the first write', () async {
      logFile.writeAsStringSync('x' * 900);

      final FileLogSink? sink = await FileLogSink.open(logFile, maxBytes: 512);
      sink!.write(recordOf('fresh_start'));
      await sink.close();

      expect(previousFile.readAsStringSync(), startsWith('x'));
      expect(logFile.readAsStringSync(), contains('fresh_start'));
      expect(logFile.readAsStringSync(), isNot(contains('x' * 100)));
    });

    test('rotation evicts the oldest records, never one in the middle', () async {
      // A bounded log necessarily drops history, so "nothing is lost" is the
      // wrong guarantee to ask for. The one that matters when reading a log is
      // that what survives is a contiguous tail: a gap in the middle would mean
      // a record vanished at a rotation boundary, and the reader would have no
      // way to tell.
      final FileLogSink? sink = await FileLogSink.open(logFile, maxBytes: 400);
      for (int i = 0; i < 60; i++) {
        sink!.write(recordOf('kept_$i'));
      }
      await sink!.close();

      final List<int> survivors = <int>[
        for (final String line in <String>[
          if (previousFile.existsSync()) ...previousFile.readAsLinesSync(),
          ...logFile.readAsLinesSync(),
        ])
          if (line.contains('kept_')) int.parse(line.split('kept_').last),
      ];

      expect(survivors, isNotEmpty);
      expect(survivors.last, 59, reason: 'the newest record is always kept');
      for (int i = 1; i < survivors.length; i++) {
        expect(
          survivors[i],
          survivors[i - 1] + 1,
          reason: 'no gap between ${survivors[i - 1]} and ${survivors[i]}',
        );
      }
    });

    test('a backlog larger than the cap is dropped and counted', () async {
      // The backlog exists so a record logged mid-rotation is not lost. It is
      // bounded for the same reason the media queues are, and a silent drop
      // would make the log lie about its own completeness.
      final FileLogSink? sink = await FileLogSink.open(logFile, maxBytes: 64);
      for (int i = 0; i < FileLogSink.maxPendingLines + 50; i++) {
        sink!.write(recordOf('flood_$i'));
      }
      await sink!.close();

      final String everything =
          '${previousFile.existsSync() ? previousFile.readAsStringSync() : ''}'
          '${logFile.readAsStringSync()}';
      expect(everything, contains('log_backlog_dropped'));
    });
  });

  group('failure never reaches the caller', () {
    test(
      'a path that cannot be opened yields null, not an exception',
      () async {
        // A logger that brings the application down when the disk is full is
        // worse than no logger at all.
        final File blocked = File('${logFile.path}/impossible/relay.log');
        logFile.writeAsStringSync('not a directory');

        expect(await FileLogSink.open(blocked), isNull);
      },
    );

    test('close is idempotent', () async {
      final FileLogSink? sink = await FileLogSink.open(logFile);
      sink!.write(recordOf('once'));

      await sink.close();
      await expectLater(sink.close(), completes);
    });

    test('a write after close is dropped rather than thrown', () async {
      final FileLogSink? sink = await FileLogSink.open(logFile);
      await sink!.close();

      expect(() => sink.write(recordOf('too_late')), returnsNormally);
      expect(logFile.readAsStringSync(), isNot(contains('too_late')));
    });
  });

  group('redaction', () {
    test('what the logger redacts is what reaches the file', () async {
      // The sink is downstream of `AppLogger.log`, which redacts at capture
      // time. This asserts the composition, because a file on a user's disk is
      // the one place a leaked token would outlive the process.
      final FileLogSink? sink = await FileLogSink.open(logFile);
      final AppLogger logger = AppLogger(sinks: <LogSink>[sink!]);

      logger.info(
        'destination_connected',
        fields: <String, Object?>{
          'botToken': '123456789:AAHfake_token_value_padded_to_length_x',
          'chatId': '4242',
        },
      );
      await sink.close();

      final String contents = logFile.readAsStringSync();
      expect(contents, contains('destination_connected'));
      expect(contents, contains('4242'));
      expect(contents, contains(LogRedactor.placeholder));
      expect(contents, isNot(contains('AAHfake_token_value')));
    });
  });
}
