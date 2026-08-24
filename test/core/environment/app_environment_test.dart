import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/environment/app_environment.dart';

const String _botToken = '7654321098:AAH9xQ2mZk3LpR7vTfWnJq4bYcXe1dGh8Ks';

void main() {
  group('parse', () {
    test('reads plain assignments', () {
      final AppEnvironment env = AppEnvironment.parse(
        'TELEGRAM_BOT_TOKEN=$_botToken\nTELEGRAM_CHAT_ID=-1001234567890\n',
      );

      expect(env.telegramBotToken, _botToken);
      expect(env.telegramChatId, '-1001234567890');
      expect(env.hasTelegramCredentials, isTrue);
    });

    test('skips blank lines and comment lines', () {
      final AppEnvironment env = AppEnvironment.parse('''
# Relay development configuration
   # indented comment

EXTRA_SETTING=123-abc.apps.googleusercontent.com

''');

      expect(env.value('EXTRA_SETTING'), '123-abc.apps.googleusercontent.com');
      expect(env.telegramBotToken, isNull);
    });

    test('strips matching surrounding quotes', () {
      final AppEnvironment env = AppEnvironment.parse(
        'TELEGRAM_CHAT_ID="-100123"\n'
        'EXTRA_SETTING=\'abc.apps.googleusercontent.com\'\n',
      );

      expect(env.telegramChatId, '-100123');
      expect(env.value('EXTRA_SETTING'), 'abc.apps.googleusercontent.com');
    });

    test('keeps an unmatched or inner quote', () {
      final AppEnvironment env = AppEnvironment.parse(
        'TELEGRAM_CHAT_ID="-100123\nEXTRA_SETTING=ab"cd\n',
      );

      expect(env.telegramChatId, '"-100123');
      expect(env.value('EXTRA_SETTING'), 'ab"cd');
    });

    test('ignores an export prefix', () {
      final AppEnvironment env = AppEnvironment.parse(
        'export TELEGRAM_BOT_TOKEN=$_botToken\n',
      );

      expect(env.telegramBotToken, _botToken);
    });

    test('preserves an equals sign inside a value', () {
      final AppEnvironment env = AppEnvironment.parse(
        'TELEGRAM_BOT_API_BASE_URL=http://localhost:8081/?a=1&b=2\n',
      );

      expect(env.telegramBotApiBaseUrl, 'http://localhost:8081/?a=1&b=2');
    });

    test('trims whitespace around the key and the value', () {
      final AppEnvironment env = AppEnvironment.parse(
        '  TELEGRAM_CHAT_ID  =   -100999   \n',
      );

      expect(env.telegramChatId, '-100999');
    });

    test('treats an empty value as absent', () {
      final AppEnvironment env = AppEnvironment.parse(
        'TELEGRAM_BOT_TOKEN=\nTELEGRAM_CHAT_ID=""\n',
      );

      expect(env.telegramBotToken, isNull);
      expect(env.telegramChatId, isNull);
      expect(env.hasTelegramCredentials, isFalse);
    });

    test('skips a line without an assignment', () {
      final AppEnvironment env = AppEnvironment.parse(
        'NOT_AN_ASSIGNMENT\n=novalue\nTELEGRAM_CHAT_ID=7\n',
      );

      expect(env.telegramChatId, '7');
      expect(env.value('NOT_AN_ASSIGNMENT'), isNull);
    });

    test('a later duplicate wins', () {
      final AppEnvironment env = AppEnvironment.parse(
        'TELEGRAM_CHAT_ID=1\nTELEGRAM_CHAT_ID=2\n',
      );

      expect(env.telegramChatId, '2');
    });

    test('handles carriage returns', () {
      final AppEnvironment env = AppEnvironment.parse(
        'TELEGRAM_CHAT_ID=5\r\nEXTRA_SETTING=abc\r\n',
      );

      expect(env.telegramChatId, '5');
      expect(env.value('EXTRA_SETTING'), 'abc');
    });

    test('requires both telegram values for hasTelegramCredentials', () {
      expect(
        AppEnvironment.parse('TELEGRAM_BOT_TOKEN=$_botToken')
            .hasTelegramCredentials,
        isFalse,
      );
      expect(
        AppEnvironment.parse('TELEGRAM_CHAT_ID=-100').hasTelegramCredentials,
        isFalse,
      );
    });
  });

  group('fromFile', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('relay_env_test');
    });

    tearDown(() {
      if (directory.existsSync()) {
        directory.deleteSync(recursive: true);
      }
    });

    test('is empty when the file is absent, which is the normal case', () {
      final AppEnvironment env = AppEnvironment.fromFile(
        File('${directory.path}/.env'),
      );

      expect(env.telegramBotToken, isNull);
      expect(env.value('EXTRA_SETTING'), isNull);
      expect(env.hasTelegramCredentials, isFalse);
    });

    test('reads an existing file', () {
      final File file = File('${directory.path}/.env')
        ..writeAsStringSync('EXTRA_SETTING=xyz.apps.googleusercontent.com\n');

      expect(
        AppEnvironment.fromFile(file).value('EXTRA_SETTING'),
        'xyz.apps.googleusercontent.com',
      );
    });
  });

  group('toString', () {
    test('does not leak any value', () {
      final AppEnvironment env = AppEnvironment.parse(
        'TELEGRAM_BOT_TOKEN=$_botToken\n'
        'TELEGRAM_CHAT_ID=-1001234567890\n'
        'EXTRA_SETTING=123-abc.apps.googleusercontent.com\n',
      );

      final String described = env.toString();

      expect(described, isNot(contains(_botToken)));
      expect(described, isNot(contains('AAH9xQ2mZk3LpR7vTfWnJq4bYcXe1dGh8Ks')));
      expect(described, isNot(contains('-1001234567890')));
      expect(described, isNot(contains('123-abc')));
      expect(described, contains('TELEGRAM_BOT_TOKEN'));
    });

    test('lists nothing for an empty environment', () {
      expect(
        const AppEnvironment.empty().toString(),
        'AppEnvironment(source: <none>, keys: )',
      );
    });

    test('names the document it was read from, so "not found" is visible', () {
      final AppEnvironment env = AppEnvironment.parse(
        'TELEGRAM_CHAT_ID=-1001234567890\n',
        sourcePath: '/somewhere/.env',
      );
      expect(env.sourcePath, '/somewhere/.env');
      expect(env.toString(), contains('/somewhere/.env'));
      expect(env.toString(), isNot(contains('-1001234567890')));
    });
  });
}
