import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:upload_core/upload_core.dart';

import 'telegram_config.dart';

/// Telegram Bot API destination (§16).
///
/// One `sendVideo` multipart request per attempt. The Bot API cannot resume a
/// partial transfer, so a retry restarts the request from byte zero.
class TelegramUploadDestination extends RetryingUploadDestination {
  TelegramUploadDestination({
    required TelegramConfig config,
    CredentialStore? credentialStore,
    http.Client? client,
    super.retryPolicy,
    this.stallTimeout = const Duration(minutes: 5),
  }) : _config = config,
       _seed = config,
       _credentials = credentialStore,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const String destinationId = 'telegram';

  /// Credential keys. The token is a secret and lives only in OS-backed
  /// storage; the chat id and the endpoint sit beside it so one store holds the
  /// whole connection (§16, §27).
  static const String botTokenKey = 'relay.telegram.bot_token';
  static const String chatIdKey = 'relay.telegram.chat_id';
  static const String baseUrlKey = 'relay.telegram.base_url';

  /// Field keys in [DestinationSetup].
  static const String botTokenField = 'botToken';
  static const String chatIdField = 'chatId';
  static const String baseUrlField = 'baseUrl';

  /// The section of the Bot API reference that explains what a local server
  /// changes — the 2000 MB ceiling among it.
  static final Uri _localServerDocs = Uri.parse(
    'https://core.telegram.org/bots/api#using-a-local-bot-api-server',
  );

  static const String _redacted = '<redacted>';

  static final RegExp _tokenInUrl = RegExp(r'bot\d+:[A-Za-z0-9_\-]+');

  /// What the deployment supplied, used until the user connects an account of
  /// their own. `.env` is a development convenience, never a store (§16).
  final TelegramConfig _seed;
  final CredentialStore? _credentials;

  TelegramConfig _config;
  bool _restored = false;
  String? _chatLabel;

  /// The endpoint and credentials in force.
  TelegramConfig get config => _config;

  /// How long the transfer may make no progress at all before it is given up
  /// on. Re-armed by every body chunk that moves, so a slow but healthy upload
  /// is never cut short; it fires when the connection or the server stalls,
  /// which `dart:io` does not bound on its own.
  final Duration stallTimeout;

  final http.Client _client;
  final bool _ownsClient;

  @override
  String get id => destinationId;

  @override
  String get displayName => 'Telegram';

  @override
  UploadCapabilities get capabilities => UploadCapabilities(
    maxFileSizeBytes: config.maxUploadBytes,
    supportsResume: false,
    supportsCancellation: true,
    supportsProgress: true,
    requiresAuthentication: false,
    transportSummary: _transportSummary,
  );

  /// Describes the transport, not the endpoint name — the endpoint is already
  /// the account line, and design `1o` uses this row for what the destination
  /// can and cannot do.
  String get _transportSummary {
    final int? limit = config.maxUploadBytes;
    return limit == null
        ? 'Single upload · no size limit · ${config.endpointLabel}'
        : 'Single upload · ${limit ~/ (1024 * 1024)} MB limit';
  }

  @override
  Future<String?> describeAccount() async {
    await restore();
    if (!config.isConfigured) {
      return null;
    }
    return '${config.endpointLabel} · ${_chatLabel ?? 'chat ${config.chatId}'}';
  }

  @override
  DestinationSetup get setup => DestinationSetup(
    kind: DestinationSetupKind.credentials,
    actionLabel: 'Connect',
    steps: const <String>[
      'In Telegram, open @BotFather and send /newbot. Follow the prompts and '
          'copy the HTTP API token it gives you.',
      'Send any message to your new bot, or add it to the group or channel you '
          'want recordings in and post one message there.',
      'Open https://api.telegram.org/bot<your token>/getUpdates in a browser '
          'and copy the numeric "chat":{"id":…} from the message you just sent. '
          'A channel id starts with -100.',
      'Paste both below. Relay checks them with Telegram before it stores '
          'them, and keeps the token in the system keychain.',
      'The hosted Bot API accepts at most 50 MB per video — roughly three '
          'minutes at 1080p. To send longer recordings, run Telegram\'s own '
          'Bot API server on this machine and put its address in the third '
          'field; the ceiling becomes 2000 MB. It is free, and the steps are '
          'in README.md. Finish steps 1-4 before you do that: switching a bot '
          'to a local server logs it out of the hosted API for 10 minutes, and '
          'step 3 reads the chat id through the hosted API.',
    ],
    fields: <DestinationField>[
      const DestinationField(
        key: botTokenField,
        label: 'Bot token',
        hint: 'From @BotFather, e.g. 123456789:AA…',
        secret: true,
      ),
      const DestinationField(
        key: chatIdField,
        label: 'Chat id',
        hint: 'The numeric id of the chat, group or channel to send to',
      ),
      DestinationField(
        key: baseUrlField,
        label: 'Bot API base URL',
        hint:
            'Optional. Leave empty for api.telegram.org and its 50 MB cap; set '
            'it to your own server, e.g. http://127.0.0.1:8081, for 2000 MB.',
        optional: true,
        helpUrl: _localServerDocs,
        helpLabel: 'What a local Bot API server is',
      ),
    ],
    helpUrl: Uri.https('t.me', '/BotFather'),
    helpLabel: 'Open @BotFather',
  );

  @override
  Future<bool> isConnected() async {
    await restore();
    return config.isConfigured;
  }

  @override
  Future<Map<String, String>> storedSetupValues() async {
    await restore();
    return <String, String>{
      chatIdField: config.chatId,
      if (!config.isHostedApi) baseUrlField: config.baseUrl.toString(),
    };
  }

  /// Verifies the credentials with Telegram, then stores them.
  ///
  /// Verification comes first on purpose: a mistyped token or a chat the bot
  /// cannot post to is reported here, not at the end of a recording (§14).
  @override
  Future<void> connect(Map<String, String> values) async {
    await restore();
    // The token field is a secret: the form shows it empty even when one is
    // stored, so an empty value means "keep the one you have".
    final String token = (values[botTokenField] ?? '').trim().isEmpty
        ? config.botToken
        : values[botTokenField]!.trim();
    final String chatId = (values[chatIdField] ?? '').trim();
    final String rawBaseUrl = (values[baseUrlField] ?? '').trim();

    if (token.isEmpty) {
      throw const UploadError(
        UploadErrorKind.notConfigured,
        'A bot token is required. Create one with @BotFather in Telegram.',
      );
    }
    if (chatId.isEmpty) {
      throw const UploadError(
        UploadErrorKind.notConfigured,
        'A chat id is required. It is the numeric id of the chat the bot '
        'should send recordings to.',
      );
    }
    Uri? baseUrl;
    if (rawBaseUrl.isNotEmpty) {
      baseUrl = Uri.tryParse(rawBaseUrl);
      final String scheme = baseUrl?.scheme.toLowerCase() ?? '';
      if (baseUrl == null ||
          (scheme != 'http' && scheme != 'https') ||
          baseUrl.host.isEmpty) {
        throw const UploadError(
          UploadErrorKind.notConfigured,
          'The Bot API base URL must be an http(s) address, for example '
          'http://localhost:8081.',
        );
      }
    }

    final TelegramConfig candidate = TelegramConfig(
      botToken: token,
      chatId: chatId,
      baseUrl: baseUrl,
    );
    final String label = await _verify(candidate);

    final CredentialStore? store = _credentials;
    if (store != null) {
      await store.write(botTokenKey, token);
      await store.write(chatIdKey, chatId);
      if (baseUrl == null) {
        await store.delete(baseUrlKey);
      } else {
        await store.write(baseUrlKey, baseUrl.toString());
      }
    }
    _config = candidate;
    _chatLabel = label;
    _restored = true;
  }

  @override
  Future<void> disconnect() async {
    final CredentialStore? store = _credentials;
    if (store != null) {
      // Written empty rather than deleted: the presence of the key is what
      // makes the store authoritative over whatever `.env` seeded, so deleting
      // it would silently reconnect the deployment's own bot.
      await store.write(botTokenKey, '');
      await store.write(chatIdKey, '');
      await store.delete(baseUrlKey);
    }
    _config = TelegramConfig.unconfigured();
    _chatLabel = null;
    _restored = true;
  }

  /// Loads stored credentials over the deployment's seed. Idempotent.
  Future<void> restore() async {
    if (_restored) {
      return;
    }
    _restored = true;
    final CredentialStore? store = _credentials;
    if (store == null) {
      return;
    }
    final String? token = await store.read(botTokenKey);
    if (token == null) {
      // Nothing has ever been connected in the app; `.env` still applies.
      _config = _seed;
      return;
    }
    final String? storedBaseUrl = await store.read(baseUrlKey);
    _config = TelegramConfig(
      botToken: token,
      chatId: await store.read(chatIdKey) ?? '',
      baseUrl: storedBaseUrl == null ? null : Uri.tryParse(storedBaseUrl),
    );
  }

  /// Asks Telegram who the bot is and whether it can see the chat.
  ///
  /// Returns a human label for the chat, so Settings can show `Team standup`
  /// rather than `-1001234567890`.
  Future<String> _verify(TelegramConfig candidate) async {
    final Map<String, Object?> me = await _call(candidate, 'getMe');
    final Object? username = me['username'];
    final Map<String, Object?> chat = await _call(
      candidate,
      'getChat',
      query: <String, String>{'chat_id': candidate.chatId},
    );
    final Object? title =
        chat['title'] ?? chat['username'] ?? chat['first_name'];
    final String chatLabel = title is String && title.isNotEmpty
        ? title
        : 'chat ${candidate.chatId}';
    return username is String && username.isNotEmpty
        ? '@$username · $chatLabel'
        : chatLabel;
  }

  Future<Map<String, Object?>> _call(
    TelegramConfig candidate,
    String method, {
    Map<String, String>? query,
  }) async {
    final Uri endpoint = _endpoint(candidate, method, query: query);
    final http.Response response;
    try {
      response = await _client
          .get(endpoint)
          .timeout(const Duration(seconds: 20));
    } on Object catch (error) {
      throw UploadError.network(
        _redactFor(candidate, 'Could not reach the Telegram Bot API: $error'),
      );
    }

    final Object? decoded = response.body.isEmpty
        ? null
        : jsonDecode(response.body);
    final Map<String, Object?> body = decoded is Map<String, Object?>
        ? decoded
        : const <String, Object?>{};
    final Object? result = body['result'];
    if (response.statusCode == 200 && body['ok'] == true && result is Map) {
      return result.cast<String, Object?>();
    }

    final Object? description = body['description'];
    final String detail = description is String && description.isNotEmpty
        ? description
        : 'Telegram refused the request (${response.statusCode}).';
    throw UploadError(
      response.statusCode == 401 || response.statusCode == 404
          ? UploadErrorKind.authentication
          : UploadErrorKind.notConfigured,
      method == 'getMe'
          ? 'Telegram did not accept that bot token: $detail'
          : 'Telegram did not accept that chat id: $detail Send the bot a '
                'message first — a bot cannot open a conversation itself.',
    );
  }

  Uri _endpoint(
    TelegramConfig candidate,
    String method, {
    Map<String, String>? query,
  }) {
    final Uri base = candidate.baseUrl;
    return base.replace(
      pathSegments: <String>[
        ...base.pathSegments.where((String segment) => segment.isNotEmpty),
        'bot${candidate.botToken}',
        method,
      ],
      queryParameters: query,
    );
  }

  /// [_redact] works against the *stored* token; a candidate being verified is
  /// not stored yet, so its token needs removing too (§27).
  String _redactFor(TelegramConfig candidate, String text) {
    final String token = candidate.botToken;
    final String stripped = token.isEmpty
        ? text
        : text
              .replaceAll(token, _redacted)
              .replaceAll(Uri.encodeComponent(token), _redacted);
    return _redact(stripped).replaceAll(_tokenInUrl, 'bot$_redacted');
  }

  @override
  Future<UploadValidationResult> validate(UploadFile file) async {
    await restore();
    if (!config.isConfigured) {
      return const UploadValidationResult.rejected(
        UploadError(
          UploadErrorKind.notConfigured,
          'Telegram is not configured. Add a bot token and a chat id in '
          'Settings before sending.',
        ),
      );
    }
    final UploadError? endpoint = _baseUrlError();
    if (endpoint != null) {
      return UploadValidationResult.rejected(endpoint);
    }
    final int? limit = config.maxUploadBytes;
    if (limit != null && file.sizeBytes > limit) {
      return UploadValidationResult.rejected(
        UploadError(
          UploadErrorKind.fileTooLarge,
          'This recording is ${_formatBytes(file.sizeBytes)}; the '
          '${config.endpointLabel} accepts at most ${_formatBytes(limit)}. '
          'Use a Local Bot API Server or record a shorter clip.',
        ),
      );
    }
    return const UploadValidationResult.ok();
  }

  /// Releases the HTTP client, but only when this destination created it.
  @override
  void dispose() {
    if (_ownsClient) {
      _client.close();
    }
  }

  @override
  UploadError unexpectedFailure(Object error) => _unexpected(error);

  /// One `sendVideo` call: the Bot API has no resume, so every attempt sends
  /// the whole file from byte zero.
  @override
  Future<AttemptOutcome> attempt({
    required UploadFile file,
    required UploadContext context,
    required File source,
    required UploadJob job,
    required void Function(UploadEvent event) emit,
  }) async {
    int sent = 0;
    final TransferDeadline deadline = TransferDeadline(stallTimeout);

    final http.MultipartRequest request =
        http.MultipartRequest('POST', _sendVideoEndpoint())
          ..fields['chat_id'] = config.chatId
          ..fields['supports_streaming'] = 'true';
    final String? caption = context.caption;
    if (caption != null && caption.isNotEmpty) {
      request.fields['caption'] = caption;
    }
    request.files.add(
      http.MultipartFile(
        'video',
        countingStream(source.openRead(), job, (int bytes) {
          sent = bytes;
          deadline.touch();
          emit(
            UploadProgress(
              context.uploadId,
              bytesSent: bytes,
              totalBytes: file.sizeBytes,
            ),
          );
        }),
        file.sizeBytes,
        filename: file.displayName,
      ),
    );

    try {
      // Waiting for the response is cancellable — nothing has been confirmed
      // yet. Reading a response Telegram has already started sending is not:
      // dropping it would discard a confirmation (§18).
      final http.StreamedResponse response = await deadline.guard(
        _client.send(request),
        cancelledBy: job,
      );
      final String body = await deadline.guard(response.stream.bytesToString());
      return _mapResponse(
        response.statusCode,
        response.headers,
        body,
        file,
        sent,
      );
    } on UploadAborted {
      return AttemptOutcome.aborted(sent);
    } on TimeoutException {
      return AttemptOutcome.failed(
        const UploadError.network('Telegram did not respond in time.'),
        sent,
      );
    } on SocketException catch (error) {
      return AttemptOutcome.failed(
        UploadError.network(
          _redact('Could not reach Telegram: ${error.message}'),
        ),
        sent,
      );
    } on http.ClientException catch (error) {
      if (job.isCancelled) {
        return AttemptOutcome.aborted(sent);
      }
      return AttemptOutcome.failed(
        UploadError.network(
          _redact('Telegram request failed: ${error.message}'),
        ),
        sent,
      );
    } on FileSystemException catch (error) {
      // The recording can vanish between the existence check and this read, or
      // between two attempts. Retrying cannot bring it back.
      return AttemptOutcome.failed(
        UploadError(
          UploadErrorKind.localFileUnavailable,
          _redact(
            'The recording ${file.displayName} could not be read: '
            '${error.message}.',
          ),
        ),
        sent,
      );
    } on IOException catch (error) {
      // TlsException and HandshakeException reach us raw: the http client maps
      // only SocketException and HttpException to ClientException.
      return AttemptOutcome.failed(
        UploadError.network(_redact('Could not reach Telegram: $error')),
        sent,
      );
    } on Object catch (error) {
      if (job.isCancelled) {
        return AttemptOutcome.aborted(sent);
      }
      return AttemptOutcome.failed(_unexpected(error), sent);
    } finally {
      deadline.dispose();
    }
  }

  AttemptOutcome _mapResponse(
    int statusCode,
    Map<String, String> headers,
    String body,
    UploadFile file,
    int sent,
  ) {
    final Map<String, Object?>? payload = _decodeJson(body);
    final Object? rawDescription = payload?['description'];
    final String? description =
        rawDescription is String && rawDescription.isNotEmpty
        ? rawDescription
        : null;

    if (statusCode == 200 && payload != null && payload['ok'] == true) {
      final RemoteUploadResult? result = _parseResult(payload, file, sent);
      if (result != null) {
        return AttemptOutcome.success(result, sent);
      }
      return AttemptOutcome.failed(
        const UploadError(
          UploadErrorKind.destinationRejected,
          'Telegram accepted the request but returned no message.',
        ),
        sent,
      );
    }

    if (statusCode == 401 || statusCode == 403 || statusCode == 404) {
      return AttemptOutcome.failed(
        UploadError.authentication(
          _redact(
            description ??
                'Telegram rejected the bot credentials ($statusCode). Check the '
                    'bot token and the chat id.',
          ),
        ),
        sent,
      );
    }

    if (statusCode == 413) {
      return AttemptOutcome.failed(
        UploadError.fileTooLarge(
          _redact(
            description ??
                'Telegram refused ${file.displayName}: it is larger than this '
                    'endpoint accepts.',
          ),
        ),
        sent,
      );
    }

    if (statusCode == 429) {
      return AttemptOutcome.failed(
        UploadError(
          UploadErrorKind.rateLimited,
          _redact(description ?? 'Telegram is rate limiting this bot.'),
          retryAfter: _retryAfter(payload, headers),
          isRetryable: true,
        ),
        sent,
      );
    }

    if (statusCode >= 500) {
      return AttemptOutcome.failed(
        UploadError.network(
          _redact(
            description ?? 'Telegram returned a server error ($statusCode).',
          ),
        ),
        sent,
      );
    }

    return AttemptOutcome.failed(
      UploadError(
        UploadErrorKind.destinationRejected,
        _redact(description ?? 'Telegram rejected the upload ($statusCode).'),
      ),
      sent,
    );
  }

  RemoteUploadResult? _parseResult(
    Map<String, Object?> payload,
    UploadFile file,
    int sent,
  ) {
    final Object? result = payload['result'];
    if (result is! Map<String, Object?>) {
      return null;
    }

    String? fileId;
    final Object? video = result['video'];
    if (video is Map<String, Object?>) {
      final Object? id = video['file_id'];
      if (id is String && id.isNotEmpty) {
        fileId = id;
      }
    }

    final String? messageId = switch (result['message_id']) {
      final int value => '$value',
      final num value => '${value.toInt()}',
      final String value when value.isNotEmpty => value,
      _ => null,
    };

    final String? remoteFileId = fileId ?? messageId;
    if (remoteFileId == null) {
      return null;
    }

    return RemoteUploadResult(
      destinationId: destinationId,
      remoteFileId: remoteFileId,
      remoteName: file.displayName,
      bytesUploaded: sent,
    );
  }

  Duration? _retryAfter(
    Map<String, Object?>? payload,
    Map<String, String> headers,
  ) {
    final Object? parameters = payload?['parameters'];
    if (parameters is Map<String, Object?>) {
      final Object? value = parameters['retry_after'];
      if (value is num) {
        return Duration(seconds: value.round());
      }
      if (value is String) {
        final int? parsed = int.tryParse(value.trim());
        if (parsed != null) {
          return Duration(seconds: parsed);
        }
      }
    }
    for (final MapEntry<String, String> entry in headers.entries) {
      if (entry.key.toLowerCase() == 'retry-after') {
        final int? parsed = int.tryParse(entry.value.trim());
        if (parsed != null) {
          return Duration(seconds: parsed);
        }
      }
    }
    return null;
  }

  Map<String, Object?>? _decodeJson(String body) {
    if (body.isEmpty) {
      return null;
    }
    try {
      final Object? decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// §16 makes the API base URL deployer-supplied, so a malformed value is
  /// expected input rather than a programming error: it has to fail pre-flight
  /// instead of throwing out of the HTTP client. The message never echoes the
  /// URL — a mistyped base URL can carry the token.
  UploadError? _baseUrlError() {
    final Uri base = config.baseUrl;
    final String scheme = base.scheme.toLowerCase();
    if ((scheme != 'http' && scheme != 'https') || base.host.isEmpty) {
      return const UploadError(
        UploadErrorKind.notConfigured,
        'The Telegram API address is not a usable http(s) URL. Check the '
        'Bot API base URL setting before sending.',
      );
    }
    return null;
  }

  Uri _sendVideoEndpoint() {
    final Uri base = config.baseUrl;
    return base.replace(
      pathSegments: <String>[
        ...base.pathSegments.where((String segment) => segment.isNotEmpty),
        'bot${config.botToken}',
        'sendVideo',
      ],
    );
  }

  /// The bot token must never leave this class — not in an error, not in a log
  /// line, not in an exception derived from the request URL (§27).
  String _redact(String text) {
    String result = text;
    final String token = config.botToken;
    if (token.isNotEmpty) {
      result = result
          .replaceAll(token, _redacted)
          .replaceAll(Uri.encodeComponent(token), _redacted);
    }
    return result.replaceAll(_tokenInUrl, 'bot$_redacted');
  }

  /// Last line of defence for an exception this class did not anticipate: it is
  /// reported as a typed failure, and its text is redacted because anything
  /// derived from the request URL carries the bot token (§26, §27).
  UploadError _unexpected(Object error) => UploadError(
    UploadErrorKind.unknown,
    _redact('Telegram upload failed unexpectedly: $error'),
  );

  static String _formatBytes(int bytes) {
    const int mb = 1024 * 1024;
    const int kb = 1024;
    if (bytes >= mb) {
      return '${(bytes / mb).toStringAsFixed(1)} MB';
    }
    if (bytes >= kb) {
      return '${(bytes / kb).toStringAsFixed(1)} KB';
    }
    return '$bytes bytes';
  }
}
