import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:upload_core/upload_core.dart';
import 'package:upload_telegram/upload_telegram.dart';

const String _botToken = '7654321:AAF-relay-test-token_do-not-use';
const String _chatId = '-1001234567890';

const Map<String, String> _jsonHeaders = <String, String>{
  'content-type': 'application/json',
};

/// Connecting Telegram from Settings (§16).
///
/// The credentials are verified against the Bot API before anything is stored,
/// and the store — not `.env` — is what the destination uses afterwards.
void main() {
  late List<Uri> requests;

  http.Client respondingClient({
    bool tokenValid = true,
    bool chatValid = true,
  }) => MockClient((http.Request request) async {
    requests.add(request.url);
    final String method = request.url.pathSegments.last;
    if (method == 'getMe') {
      return tokenValid
          ? http.Response(
              jsonEncode(<String, Object?>{
                'ok': true,
                'result': <String, Object?>{
                  'id': 7654321,
                  'username': 'relay_test_bot',
                },
              }),
              200,
              headers: _jsonHeaders,
            )
          : http.Response(
              jsonEncode(<String, Object?>{
                'ok': false,
                'description': 'Unauthorized',
              }),
              401,
              headers: _jsonHeaders,
            );
    }
    if (method == 'getChat') {
      return chatValid
          ? http.Response(
              jsonEncode(<String, Object?>{
                'ok': true,
                'result': <String, Object?>{
                  'id': -1001234567890,
                  'title': 'Team standup',
                },
              }),
              200,
              headers: _jsonHeaders,
            )
          : http.Response(
              jsonEncode(<String, Object?>{
                'ok': false,
                'description': 'chat not found',
              }),
              400,
              headers: _jsonHeaders,
            );
    }
    return http.Response('{"ok":false}', 404, headers: _jsonHeaders);
  });

  TelegramUploadDestination destination({
    required CredentialStore store,
    TelegramConfig? seed,
    bool tokenValid = true,
    bool chatValid = true,
  }) => TelegramUploadDestination(
    config: seed ?? TelegramConfig.unconfigured(),
    credentialStore: store,
    client: respondingClient(tokenValid: tokenValid, chatValid: chatValid),
  );

  setUp(() => requests = <Uri>[]);

  test('the setup names what the user has to supply', () {
    final DestinationSetup setup = destination(store: InMemoryCredentialStore())
        .setup;
    expect(setup.kind, DestinationSetupKind.credentials);
    expect(setup.steps, isNotEmpty);
    expect(
      setup.fields.map((DestinationField f) => f.key),
      containsAll(<String>[
        TelegramUploadDestination.botTokenField,
        TelegramUploadDestination.chatIdField,
      ]),
    );
    final DestinationField token = setup.fields.firstWhere(
      (DestinationField f) => f.key == TelegramUploadDestination.botTokenField,
    );
    expect(token.secret, isTrue, reason: 'a bot token is a credential (§27)');
  });

  test('connecting verifies the credentials, then stores them', () async {
    final CredentialStore store = InMemoryCredentialStore();
    final TelegramUploadDestination telegram = destination(store: store);
    expect(await telegram.isConnected(), isFalse);

    await telegram.connect(<String, String>{
      TelegramUploadDestination.botTokenField: _botToken,
      TelegramUploadDestination.chatIdField: _chatId,
    });

    expect(requests.map((Uri uri) => uri.pathSegments.last), <String>[
      'getMe',
      'getChat',
    ], reason: 'the token and the chat are both checked before storing');
    expect(await telegram.isConnected(), isTrue);
    expect(await store.read(TelegramUploadDestination.botTokenKey), _botToken);
    expect(await store.read(TelegramUploadDestination.chatIdKey), _chatId);
    expect(await telegram.describeAccount(), contains('Team standup'));
  });

  test('a refused token is reported and nothing is stored', () async {
    final CredentialStore store = InMemoryCredentialStore();
    final TelegramUploadDestination telegram = destination(
      store: store,
      tokenValid: false,
    );

    await expectLater(
      telegram.connect(<String, String>{
        TelegramUploadDestination.botTokenField: _botToken,
        TelegramUploadDestination.chatIdField: _chatId,
      }),
      throwsA(isA<UploadError>()),
    );
    expect(await store.read(TelegramUploadDestination.botTokenKey), isNull);
    expect(await telegram.isConnected(), isFalse);
  });

  test('a chat the bot cannot see is reported and nothing is stored', () async {
    final CredentialStore store = InMemoryCredentialStore();
    final TelegramUploadDestination telegram = destination(
      store: store,
      chatValid: false,
    );

    await expectLater(
      telegram.connect(<String, String>{
        TelegramUploadDestination.botTokenField: _botToken,
        TelegramUploadDestination.chatIdField: _chatId,
      }),
      throwsA(
        isA<UploadError>().having(
          (UploadError e) => e.message,
          'message',
          contains('chat id'),
        ),
      ),
    );
    expect(await store.read(TelegramUploadDestination.chatIdKey), isNull);
  });

  test(
    'stored credentials outlive the process and beat the .env seed',
    () async {
      final CredentialStore store = InMemoryCredentialStore();
      await destination(store: store).connect(<String, String>{
        TelegramUploadDestination.botTokenField: _botToken,
        TelegramUploadDestination.chatIdField: _chatId,
      });

      // A fresh destination, as after a restart, still seeded from `.env`.
      final TelegramUploadDestination restarted = destination(
        store: store,
        seed: TelegramConfig(botToken: 'deployment-token', chatId: '1'),
      );
      expect(await restarted.isConnected(), isTrue);
      expect(restarted.config.chatId, _chatId);
      expect(restarted.config.botToken, _botToken);
    },
  );

  test('an empty token field keeps the stored one', () async {
    final CredentialStore store = InMemoryCredentialStore();
    final TelegramUploadDestination telegram = destination(store: store);
    await telegram.connect(<String, String>{
      TelegramUploadDestination.botTokenField: _botToken,
      TelegramUploadDestination.chatIdField: _chatId,
    });

    // The form never reads a secret back out, so it submits it empty.
    await telegram.connect(<String, String>{
      TelegramUploadDestination.botTokenField: '',
      TelegramUploadDestination.chatIdField: '-100999',
    });
    expect(telegram.config.botToken, _botToken);
    expect(telegram.config.chatId, '-100999');
  });

  test('the stored values offered back never include the token', () async {
    final CredentialStore store = InMemoryCredentialStore();
    final TelegramUploadDestination telegram = destination(store: store);
    await telegram.connect(<String, String>{
      TelegramUploadDestination.botTokenField: _botToken,
      TelegramUploadDestination.chatIdField: _chatId,
    });

    final Map<String, String> values = await telegram.storedSetupValues();
    expect(values[TelegramUploadDestination.chatIdField], _chatId);
    expect(values.values, isNot(contains(_botToken)));
  });

  test('disconnecting does not fall back to the .env seed', () async {
    final CredentialStore store = InMemoryCredentialStore();
    final TelegramUploadDestination telegram = destination(
      store: store,
      seed: TelegramConfig(botToken: 'deployment-token', chatId: '1'),
    );
    expect(await telegram.isConnected(), isTrue, reason: 'seeded from .env');

    await telegram.disconnect();
    expect(await telegram.isConnected(), isFalse);

    final TelegramUploadDestination restarted = destination(
      store: store,
      seed: TelegramConfig(botToken: 'deployment-token', chatId: '1'),
    );
    expect(
      await restarted.isConnected(),
      isFalse,
      reason: 'an explicit disconnect must survive a restart',
    );
  });

  test('a Local Bot API Server lifts the size cap it reports', () async {
    final CredentialStore store = InMemoryCredentialStore();
    final TelegramUploadDestination telegram = destination(store: store);
    await telegram.connect(<String, String>{
      TelegramUploadDestination.botTokenField: _botToken,
      TelegramUploadDestination.chatIdField: _chatId,
      TelegramUploadDestination.baseUrlField: 'http://localhost:8081',
    });

    expect(telegram.capabilities.maxFileSizeBytes, isNull);
    expect(requests.first.host, 'localhost');
  });

  test(
    'a base URL that is not http(s) is refused before any request',
    () async {
      final CredentialStore store = InMemoryCredentialStore();
      final TelegramUploadDestination telegram = destination(store: store);
      await expectLater(
        telegram.connect(<String, String>{
          TelegramUploadDestination.botTokenField: _botToken,
          TelegramUploadDestination.chatIdField: _chatId,
          TelegramUploadDestination.baseUrlField: 'ftp://example.invalid',
        }),
        throwsA(isA<UploadError>()),
      );
      expect(requests, isEmpty);
    },
  );

  test('a failure never echoes the bot token', () async {
    final CredentialStore store = InMemoryCredentialStore();
    final TelegramUploadDestination telegram = TelegramUploadDestination(
      config: TelegramConfig.unconfigured(),
      credentialStore: store,
      client: MockClient((http.Request request) async {
        throw StateError('boom talking to ${request.url}');
      }),
    );

    await expectLater(
      telegram.connect(<String, String>{
        TelegramUploadDestination.botTokenField: _botToken,
        TelegramUploadDestination.chatIdField: _chatId,
      }),
      throwsA(
        isA<UploadError>().having(
          (UploadError e) => e.message,
          'message',
          isNot(contains(_botToken)),
        ),
      ),
    );
  });
}
