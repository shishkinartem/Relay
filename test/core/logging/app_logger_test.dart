import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/logging/app_logger.dart';

const String _botToken = '7654321098:AAH9xQ2mZk3LpR7vTfWnJq4bYcXe1dGh8Ks';
const String _bearer = 'Bearer ya29.a0AfB_byC3xKQm7Lp2Rt9Vw4Zn6Hs1Dg8Jf0Uy';

void main() {
  const LogRedactor redactor = LogRedactor();

  group('LogRedactor keys', () {
    test('redacts every sensitive key fragment case-insensitively', () {
      final Map<String, Object?> redacted = redactor.redactFields(
        <String, Object?>{
          'telegramBotToken': 'plain',
          'CLIENT_SECRET': 'plain',
          'Password': 'plain',
          'Authorization': 'plain',
          'auth_state': 'plain',
          'refresh_token': 'plain',
          'code_verifier': 'plain',
          'apiKey': 'plain',
          'API_KEY': 'plain',
          'credentialStore': 'plain',
          'bearerHeader': 'plain',
        },
      );

      expect(
        redacted.values.every(
          (Object? value) => value == LogRedactor.placeholder,
        ),
        isTrue,
        reason: '$redacted',
      );
    });

    test('leaves harmless fields untouched', () {
      final Map<String, Object?> redacted = redactor.redactFields(
        <String, Object?>{
          'droppedFrames': 3,
          'encoderName': 'h264_videotoolbox',
        },
      );

      expect(redacted['droppedFrames'], 3);
      expect(redacted['encoderName'], 'h264_videotoolbox');
    });

    test('redacts a sensitive key whatever its value type', () {
      final Map<String, Object?> redacted = redactor.redactFields(
        <String, Object?>{
          'token': <String, Object?>{'value': 'plain'},
          'secrets': <String>['a', 'b'],
        },
      );

      expect(redacted['token'], LogRedactor.placeholder);
      expect(redacted['secrets'], LogRedactor.placeholder);
    });
  });

  group('LogRedactor values', () {
    test('redacts a telegram bot token shaped value', () {
      expect(redactor.redactText(_botToken), LogRedactor.placeholder);
    });

    test('redacts a bot token embedded in a longer string', () {
      final String redacted = redactor.redactText(
        'POST https://api.telegram.org/bot$_botToken/sendVideo failed',
      );

      expect(redacted, contains(LogRedactor.placeholder));
      expect(redacted, contains('sendVideo failed'));
      expect(redacted, isNot(contains('AAH9xQ2mZk3LpR7vTfWnJq4bYcXe1dGh8Ks')));
    });

    test('redacts a bearer credential', () {
      expect(
        redactor.redactText('header=$_bearer'),
        'header=${LogRedactor.placeholder}',
      );
    });

    test('leaves an ordinary colon-separated value alone', () {
      expect(redactor.redactText('12:34:56'), '12:34:56');
      expect(
        redactor.redactText('chatId=-1001234567890'),
        'chatId=-1001234567890',
      );
    });

    test('redacts inside nested maps and lists', () {
      final Map<String, Object?> redacted = redactor.redactFields(
        <String, Object?>{
          'request': <String, Object?>{
            'url': 'https://api.telegram.org/bot$_botToken/getMe',
            'headers': <Object?>[
              _bearer,
              <String, Object?>{'x-retry': 1},
            ],
          },
        },
      );

      final String flattened = redacted.toString();
      expect(flattened, isNot(contains('AAH9xQ2mZk3LpR7vTfWnJq4bYcXe1dGh8Ks')));
      expect(
        flattened,
        isNot(contains('ya29.a0AfB_byC3xKQm7Lp2Rt9Vw4Zn6Hs1Dg8Jf0Uy')),
      );
      expect(flattened, contains('x-retry: 1'));
    });
  });

  group('AppLogger', () {
    test('redacts before anything reaches a sink', () {
      final MemoryLogSink sink = MemoryLogSink();
      final AppLogger logger = AppLogger(sinks: <LogSink>[sink]);

      logger.error(
        'upload.failed',
        fields: <String, Object?>{
          'botToken': _botToken,
          'endpoint': 'https://api.telegram.org/bot$_botToken/sendVideo',
          'attempt': 2,
        },
        error: Exception('rejected token $_botToken'),
      );

      final LogRecord record = sink.records.single;
      expect(record.level, LogLevel.error);
      expect(record.event, 'upload.failed');
      expect(record.fields['botToken'], LogRedactor.placeholder);
      expect(record.fields['attempt'], 2);
      expect(
        record.fields['endpoint'],
        isNot(contains('AAH9xQ2mZk3LpR7vTfWnJq4bYcXe1dGh8Ks')),
      );
      expect(
        record.error.toString(),
        isNot(contains('AAH9xQ2mZk3LpR7vTfWnJq4bYcXe1dGh8Ks')),
      );
      expect(
        record.format(),
        isNot(contains('AAH9xQ2mZk3LpR7vTfWnJq4bYcXe1dGh8Ks')),
      );
    });

    test('does not mutate the caller field map', () {
      final Map<String, Object?> fields = <String, Object?>{'token': _botToken};

      AppLogger().info('probe', fields: fields);

      expect(fields['token'], _botToken);
    });

    test('records every level with its event and fields', () {
      final MemoryLogSink sink = MemoryLogSink();
      final AppLogger logger = AppLogger(sinks: <LogSink>[sink]);

      logger.debug('a');
      logger.info('b');
      logger.warn('c');
      logger.error('d');

      expect(
        sink.records.map((LogRecord r) => r.level).toList(growable: false),
        <LogLevel>[
          LogLevel.debug,
          LogLevel.info,
          LogLevel.warn,
          LogLevel.error,
        ],
      );
      expect(
        sink.records.map((LogRecord r) => r.event).toList(growable: false),
        <String>['a', 'b', 'c', 'd'],
      );
    });

    test('fans out to every sink', () {
      final MemoryLogSink first = MemoryLogSink();
      final MemoryLogSink second = MemoryLogSink();

      AppLogger(sinks: <LogSink>[first, second]).info('state.changed');

      expect(first.records, hasLength(1));
      expect(second.records, hasLength(1));
    });

    test('the diagnostics buffer is bounded and keeps the newest records', () {
      final AppLogger logger = AppLogger(bufferSize: 3);

      for (int i = 0; i < 10; i++) {
        logger.info('event.$i');
      }

      expect(logger.records, hasLength(3));
      expect(
        logger.records.map((LogRecord r) => r.event).toList(growable: false),
        <String>['event.7', 'event.8', 'event.9'],
      );
    });

    test('default buffer size is 500', () {
      expect(AppLogger().bufferSize, 500);
    });

    test('exports redacted diagnostics as one line per record', () {
      final AppLogger logger = AppLogger();

      logger.info('recording.started', fields: <String, Object?>{'fps': 30});
      logger.warn(
        'upload.retry',
        fields: <String, Object?>{
          'endpoint': 'https://api.telegram.org/bot$_botToken/x',
        },
      );

      final String export = logger.exportRedactedDiagnostics();

      expect(export.split('\n'), hasLength(2));
      expect(export, contains('recording.started'));
      expect(export, contains('fps=30'));
      expect(export, contains(LogRedactor.placeholder));
      expect(export, isNot(contains('AAH9xQ2mZk3LpR7vTfWnJq4bYcXe1dGh8Ks')));
    });
  });

  group('MemoryLogSink', () {
    test('is bounded and keeps the newest records', () {
      final MemoryLogSink sink = MemoryLogSink(capacity: 3);
      final AppLogger logger = AppLogger(sinks: <LogSink>[sink]);

      for (int i = 0; i < 10; i++) {
        logger.info('event.$i');
      }

      expect(sink.records, hasLength(3));
      expect(
        sink.records.map((LogRecord r) => r.event).toList(growable: false),
        <String>['event.7', 'event.8', 'event.9'],
      );
    });

    test('caps retention by default', () {
      final MemoryLogSink sink = MemoryLogSink();
      final AppLogger logger = AppLogger(sinks: <LogSink>[sink]);

      // A long recording emits one stats record per second; the sink must not
      // grow with the session.
      for (int i = 0; i < MemoryLogSink.defaultCapacity + 3600; i++) {
        logger.debug('recording.stats');
      }

      expect(sink.records, hasLength(MemoryLogSink.defaultCapacity));
    });

    test('clear drops the retained records', () {
      final MemoryLogSink sink = MemoryLogSink();
      AppLogger(sinks: <LogSink>[sink]).info('probe');

      sink.clear();

      expect(sink.records, isEmpty);
    });
  });
}
