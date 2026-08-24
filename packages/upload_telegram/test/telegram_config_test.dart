import 'package:test/test.dart';
import 'package:upload_telegram/upload_telegram.dart';

void main() {
  const String botToken = '7654321:AAF-relay-test-token_do-not-use';
  const String chatId = '-1001234567890';

  group('TelegramConfig', () {
    test('hosted() targets the official API and keeps the documented cap', () {
      final TelegramConfig config = TelegramConfig.hosted(
        botToken: botToken,
        chatId: chatId,
      );

      expect(config.baseUrl.host, 'api.telegram.org');
      expect(config.isHostedApi, isTrue);
      expect(config.isConfigured, isTrue);
      expect(config.maxUploadBytes, TelegramConfig.hostedMaxUploadBytes);
      expect(TelegramConfig.hostedMaxUploadBytes, 50 * 1024 * 1024);
      expect(config.endpointLabel, 'Hosted Bot API');
    });

    test('an arbitrary base URL is a Local Bot API Server with no cap', () {
      final TelegramConfig config = TelegramConfig(
        botToken: botToken,
        chatId: chatId,
        baseUrl: Uri.parse('http://127.0.0.1:8081/telegram'),
      );

      expect(config.isHostedApi, isFalse);
      expect(config.maxUploadBytes, isNull);
      expect(config.endpointLabel, 'Local Bot API Server');
    });

    test('isConfigured needs both a token and a chat id', () {
      expect(TelegramConfig.unconfigured().isConfigured, isFalse);
      expect(
        TelegramConfig.hosted(botToken: botToken, chatId: '').isConfigured,
        isFalse,
      );
      expect(
        TelegramConfig.hosted(botToken: '', chatId: chatId).isConfigured,
        isFalse,
      );
    });

    test('toString never carries the bot token', () {
      final String described = TelegramConfig.hosted(
        botToken: botToken,
        chatId: chatId,
      ).toString();

      expect(described, isNot(contains(botToken)));
      expect(described, contains('Hosted Bot API'));
      expect(described, contains(chatId));
    });
  });
}
