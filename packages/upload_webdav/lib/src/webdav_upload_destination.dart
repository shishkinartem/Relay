import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:upload_core/upload_core.dart';

import 'webdav_config.dart';

/// WebDAV destination (§17).
///
/// One `PUT` per attempt. WebDAV has no standard way to resume a partial
/// upload — `Content-Range` on `PUT` is an extension no provider is obliged to
/// implement — so an interrupted transfer restarts, and [capabilities] says so
/// rather than reporting a resume that does not exist.
class WebDavUploadDestination extends RetryingUploadDestination {
  WebDavUploadDestination({
    CredentialStore? credentialStore,
    http.Client? client,
    super.retryPolicy,
    this.stallTimeout = const Duration(minutes: 5),
  }) : _credentials = credentialStore,
       _client = client ?? http.Client(),
       _ownsClient = client == null;

  static const String destinationId = 'webdav';

  /// Credential keys. The password is a secret and lives only in OS-backed
  /// storage; the address, user and folder sit beside it so one store holds the
  /// whole connection (§27).
  static const String baseUrlKey = 'relay.webdav.base_url';
  static const String usernameKey = 'relay.webdav.username';
  static const String passwordKey = 'relay.webdav.password';
  static const String folderKey = 'relay.webdav.folder';

  /// Field keys in [DestinationSetup].
  static const String baseUrlField = 'baseUrl';
  static const String usernameField = 'username';
  static const String passwordField = 'password';
  static const String folderField = 'folder';

  static const String _redacted = '<redacted>';

  /// Where Koofr issues app passwords — the one page the setup steps send the
  /// user to.
  static final Uri _koofrHelp = Uri.https(
    'koofr.eu',
    '/help/koofr_with_webdav/how-do-i-connect-a-service-to-koofr-through-webdav/',
  );

  /// A minimal `PROPFIND` body.
  ///
  /// It asks for `resourcetype` rather than for nothing: an empty `<prop/>` is
  /// accepted by some servers and answered with `400 Bad Request` by others,
  /// and a credential check has no business being the fussy part of a
  /// connection. This is the shape every WebDAV client sends.
  static const String _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop>'
      '</d:propfind>';

  final CredentialStore? _credentials;

  /// How long the transfer may make no progress at all before it is given up
  /// on. Re-armed by every body chunk that moves, so a slow but healthy upload
  /// is never cut short; it fires when the connection or the server stalls,
  /// which `dart:io` does not bound on its own.
  final Duration stallTimeout;

  final http.Client _client;
  final bool _ownsClient;

  WebDavConfig _config = WebDavConfig.unconfigured();
  bool _restored = false;

  /// The endpoint and credentials in force.
  WebDavConfig get config => _config;

  @override
  String get id => destinationId;

  @override
  String get displayName => 'WebDAV';

  @override
  UploadCapabilities get capabilities => UploadCapabilities(
    supportsResume: false,
    supportsCancellation: true,
    supportsProgress: true,
    requiresAuthentication: true,
    transportSummary: 'Single upload · no size limit · $_transportEndpoint',
  );

  String get _transportEndpoint =>
      _config.isConfigured ? _config.endpointLabel : 'your own server';

  @override
  DestinationSetup get setup => DestinationSetup(
    kind: DestinationSetupKind.credentials,
    actionLabel: 'Connect',
    steps: <String>[
      'WebDAV is a protocol, not a service: this works with Koofr, any '
          'Nextcloud or ownCloud, and others. None of them needs a developer '
          'account, an API key or a console — only an app password from your '
          'own account settings.',
      'The suggested provider is Koofr: sign up at koofr.eu for a free 10 GB '
          'account, which is about eleven hours of 720p recording.',
      'In Koofr, open Preferences > Password > app-specific passwords, create '
          'one for Relay and copy it. It is not your account password, and it '
          'can be revoked on its own.',
      'Fill the address, your account email and that app password in below. '
          'Relay checks them against the server and creates the folder before '
          'storing anything, so a wrong address or a rejected password is '
          'reported here rather than after a recording.',
    ],
    fields: <DestinationField>[
      DestinationField(
        key: baseUrlField,
        label: 'WebDAV address',
        hint:
            'Koofr: ${WebDavConfig.koofrBaseUrl} · Nextcloud: '
            'https://<your host>/remote.php/dav/files/<user>',
        helpUrl: _koofrHelp,
        helpLabel: 'Where Koofr keeps this',
      ),
      const DestinationField(
        key: usernameField,
        label: 'User name',
        hint: 'The email you signed up with, for Koofr',
      ),
      const DestinationField(
        key: passwordField,
        label: 'App password',
        hint: 'The generated one, not your account password',
        secret: true,
      ),
      const DestinationField(
        key: folderField,
        label: 'Folder',
        hint:
            'Created if it does not exist. Leave empty for '
            '${WebDavConfig.defaultFolder}.',
        optional: true,
      ),
    ],
    helpUrl: _koofrHelp,
    helpLabel: 'Koofr WebDAV instructions',
  );

  @override
  Future<bool> isConnected() async {
    await restore();
    return config.isConfigured;
  }

  @override
  Future<String?> describeAccount() async {
    await restore();
    if (!config.isConfigured) {
      return null;
    }
    final String folder = config.folder.isEmpty ? '/' : '/${config.folder}';
    return '${config.endpointLabel} · ${config.username} · $folder';
  }

  @override
  Future<Map<String, String>> storedSetupValues() async {
    await restore();
    return <String, String>{
      if (config.hasUsableBaseUrl) baseUrlField: config.baseUrl.toString(),
      usernameField: config.username,
      folderField: config.folder,
    };
  }

  /// Verifies the credentials against the server, then stores them.
  ///
  /// Verification comes first on purpose: a wrong address, a rejected password
  /// or a folder the account may not write to is reported here, not at the end
  /// of a recording (§14).
  @override
  Future<void> connect(Map<String, String> values) async {
    await restore();
    final String rawBaseUrl = (values[baseUrlField] ?? '').trim();
    final String username = (values[usernameField] ?? '').trim();
    // The password field is a secret: the form shows it empty even when one is
    // stored, so an empty value means "keep the one you have".
    final String typedPassword = (values[passwordField] ?? '').trim();
    final String password = typedPassword.isEmpty
        ? config.password
        : typedPassword;

    if (rawBaseUrl.isEmpty) {
      throw UploadError(
        UploadErrorKind.notConfigured,
        'A WebDAV address is required. For Koofr it is '
        '${WebDavConfig.koofrBaseUrl}.',
      );
    }
    if (username.isEmpty) {
      throw const UploadError(
        UploadErrorKind.notConfigured,
        'A user name is required — for Koofr, the email you signed up with.',
      );
    }
    if (password.isEmpty) {
      throw const UploadError(
        UploadErrorKind.notConfigured,
        'An app password is required. Create one in your account settings; '
        'the account password itself will usually be refused.',
      );
    }

    final WebDavConfig candidate = WebDavConfig(
      baseUrl: Uri.tryParse(rawBaseUrl),
      username: username,
      password: password,
      folder: values[folderField],
    );
    if (!candidate.hasUsableBaseUrl) {
      throw const UploadError(
        UploadErrorKind.notConfigured,
        'The WebDAV address must be an http(s) URL.',
      );
    }

    await _verify(candidate);

    final CredentialStore? store = _credentials;
    if (store != null) {
      await store.write(baseUrlKey, candidate.baseUrl.toString());
      await store.write(usernameKey, candidate.username);
      await store.write(passwordKey, candidate.password);
      await store.write(folderKey, candidate.folder);
    }
    _config = candidate;
    _restored = true;
  }

  @override
  Future<void> disconnect() async {
    final CredentialStore? store = _credentials;
    if (store != null) {
      for (final String key in <String>[
        baseUrlKey,
        usernameKey,
        passwordKey,
        folderKey,
      ]) {
        await store.delete(key);
      }
    }
    _config = WebDavConfig.unconfigured();
    _restored = true;
  }

  /// Loads stored credentials. Idempotent.
  Future<void> restore() async {
    if (_restored) {
      return;
    }
    _restored = true;
    final CredentialStore? store = _credentials;
    if (store == null) {
      return;
    }
    final String? password = await store.read(passwordKey);
    if (password == null || password.isEmpty) {
      return;
    }
    _config = WebDavConfig(
      baseUrl: Uri.tryParse(await store.read(baseUrlKey) ?? ''),
      username: await store.read(usernameKey) ?? '',
      password: password,
      folder: await store.read(folderKey),
    );
  }

  @override
  Future<UploadValidationResult> validate(UploadFile file) async {
    await restore();
    if (!config.isConfigured) {
      return const UploadValidationResult.rejected(
        UploadError(
          UploadErrorKind.notConfigured,
          'WebDAV is not connected. Add the address, user name and app '
          'password in Settings before sending.',
        ),
      );
    }
    if (!config.hasUsableBaseUrl) {
      return const UploadValidationResult.rejected(
        UploadError(
          UploadErrorKind.notConfigured,
          'The stored WebDAV address is not a usable http(s) URL.',
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

  /// One `PUT` of the whole file: WebDAV has no resume here, so every attempt
  /// writes from byte zero.
  @override
  Future<AttemptOutcome> attempt({
    required UploadFile file,
    required UploadContext context,
    required File source,
    required UploadJob job,
    required void Function(UploadEvent event) emit,
  }) async {
    final String uploadId = context.uploadId;
    int sent = 0;
    final TransferDeadline deadline = TransferDeadline(stallTimeout);
    final Uri target = config.fileUrl(file.displayName);

    final _StreamedBodyRequest request =
        _StreamedBodyRequest(
            'PUT',
            target,
            countingStream(source.openRead(), job, (int bytes) {
              sent = bytes;
              deadline.touch();
              emit(
                UploadProgress(
                  uploadId,
                  bytesSent: bytes,
                  totalBytes: file.sizeBytes,
                ),
              );
            }),
            file.sizeBytes,
          )
          ..headers['authorization'] = config.authorizationHeader
          ..headers['content-type'] = file.mimeType;

    try {
      // Waiting for the response is cancellable — nothing has been stored yet.
      // Reading a response the server has already started sending is not:
      // dropping it would discard a confirmation (§18).
      final http.StreamedResponse response = await deadline.guard(
        _client.send(request),
        cancelledBy: job,
      );
      final String body = await deadline.guard(response.stream.bytesToString());
      return _mapPutResponse(response, body, file, target, sent);
    } on UploadAborted {
      return AttemptOutcome.aborted(sent);
    } on TimeoutException {
      return AttemptOutcome.failed(
        UploadError.network(
          'The server stopped responding for ${stallTimeout.inMinutes} '
          'minutes.',
        ),
        sent,
      );
    } on Object catch (error) {
      return AttemptOutcome.failed(
        UploadError.network(_redact('Could not reach the server: $error')),
        sent,
      );
    } finally {
      deadline.dispose();
    }
  }

  AttemptOutcome _mapPutResponse(
    http.StreamedResponse response,
    String body,
    UploadFile file,
    Uri target,
    int sent,
  ) {
    final int status = response.statusCode;
    if (status == 200 || status == 201 || status == 204) {
      return AttemptOutcome.success(
        RemoteUploadResult(
          destinationId: destinationId,
          remoteFileId: target.path,
          remoteName: file.displayName,
          remoteUrl: target.toString(),
          bytesUploaded: file.sizeBytes,
        ),
        sent,
      );
    }
    return AttemptOutcome.failed(_mapStatus(status, response.headers), sent);
  }

  /// Asks the server who it thinks we are, then makes sure the folder exists.
  ///
  /// The `PROPFIND` is a courtesy: it gives a clean answer about the
  /// credentials, but a server is entitled to dislike it for reasons that have
  /// nothing to do with the account. Only a refusal it *can* speak to — wrong
  /// credentials, nothing at that address — ends the connection there. Anything
  /// else falls through to `MKCOL`, which is the test that actually matters,
  /// because it proves the account can be written to.
  Future<void> _verify(WebDavConfig candidate) async {
    final http.Response probe = await _send(
      candidate,
      'PROPFIND',
      candidate.baseUrl,
      headers: const <String, String>{
        'depth': '0',
        'content-type': 'application/xml; charset=utf-8',
      },
      body: _propfindBody,
    );
    if (_isCredentialRefusal(probe.statusCode) || probe.statusCode == 404) {
      throw _mapStatus(
        probe.statusCode,
        probe.headers,
        step: _checkingCredentials,
        body: probe.body,
      );
    }
    // 207 Multi-Status is the WebDAV answer; 200 is what a few servers send.
    final bool probed = probe.statusCode == 207 || probe.statusCode == 200;

    if (candidate.folder.isEmpty) {
      if (!probed) {
        throw _mapStatus(
          probe.statusCode,
          probe.headers,
          step: _checkingCredentials,
          body: probe.body,
        );
      }
      return;
    }

    final http.Response created = await _send(
      candidate,
      'MKCOL',
      candidate.collectionUrl,
    );
    // 405 is "it is already there", which is the common case after the first
    // connect; 301 means the server wants the collection form of the URL and
    // has one already.
    const Set<int> acceptable = <int>{200, 201, 204, 301, 405};
    if (!acceptable.contains(created.statusCode)) {
      throw _mapStatus(
        created.statusCode,
        created.headers,
        step: _creatingFolder,
        body: created.body,
      );
    }
  }

  static bool _isCredentialRefusal(int status) =>
      status == 401 || status == 403;

  static const String _checkingCredentials = 'checking the credentials';
  static const String _creatingFolder = 'creating the folder';

  Future<http.Response> _send(
    WebDavConfig candidate,
    String method,
    Uri url, {
    Map<String, String> headers = const <String, String>{},
    String? body,
  }) async {
    final http.Request request = http.Request(method, url)
      ..headers['authorization'] = candidate.authorizationHeader
      ..headers.addAll(headers);
    if (body != null) {
      request.body = body;
    }
    try {
      final http.StreamedResponse response = await _client
          .send(request)
          .timeout(const Duration(seconds: 30));
      final String text = await response.stream.bytesToString();
      return http.Response(
        text,
        response.statusCode,
        headers: response.headers,
      );
    } on UploadError {
      rethrow;
    } on Object catch (error) {
      throw UploadError.network(
        _redactFor(
          candidate,
          'Could not reach ${candidate.endpointLabel}: '
          '$error',
        ),
      );
    }
  }

  /// One place that turns a WebDAV status into a typed failure, so neither the
  /// application nor a screen ever inspects an HTTP code (§14).
  ///
  /// [step] names what was being attempted, and [body] carries whatever the
  /// server said about it. A bare "refused (400)" is not something a user can
  /// act on, and WebDAV servers are usually specific about what they disliked.
  UploadError _mapStatus(
    int status,
    Map<String, String> headers, {
    String? step,
    String? body,
  }) {
    final bool verifying = step != null;
    switch (status) {
      case 401:
      case 403:
        return UploadError(
          UploadErrorKind.authentication,
          'The server refused these credentials. Most providers require an '
          'app password created in your account settings — the account '
          'password itself is rejected.',
          details: _serverSaid(body),
        );
      case 404:
        return UploadError(
          UploadErrorKind.notConfigured,
          verifying
              ? 'The server has nothing at that address. Check the WebDAV URL: '
                    'for Koofr it ends in /dav/Koofr, for Nextcloud in '
                    '/remote.php/dav/files/<user>.'
              : 'The folder is no longer on the server. Reconnect in Settings '
                    'to create it again.',
        );
      case 400:
        return UploadError(
          UploadErrorKind.destinationRejected,
          'The server rejected the request while ${step ?? 'sending the '
                  'recording'} (400). Check the address: for Koofr it is exactly '
          'https://app.koofr.net/dav/Koofr, with no trailing slash and nothing '
          'after it.',
          details: _serverSaid(body),
        );
      case 409:
        return UploadError(
          UploadErrorKind.destinationRejected,
          'The parent folder does not exist on the server. Reconnect in '
          'Settings so Relay can create it.',
          details: _serverSaid(body),
        );
      case 413:
        return const UploadError.fileTooLarge(
          'The server refused the recording as too large.',
        );
      case 423:
        return const UploadError(
          UploadErrorKind.destinationRejected,
          'The file is locked on the server by another client.',
        );
      case 429:
        return UploadError(
          UploadErrorKind.rateLimited,
          'The server is rate limiting this account.',
          retryAfter: _retryAfter(headers),
          isRetryable: true,
        );
      case 507:
        return const UploadError(
          UploadErrorKind.destinationRejected,
          'The account is out of space.',
        );
      default:
        if (status >= 500) {
          return UploadError.network(
            'The server answered $status while ${step ?? 'sending the '
                    'recording'}. It may be a temporary fault.',
            details: _serverSaid(body),
          );
        }
        return UploadError(
          UploadErrorKind.destinationRejected,
          'The server refused the request ($status) while '
          '${step ?? 'sending the recording'}.',
          details: _serverSaid(body),
        );
    }
  }

  /// The server's own words, trimmed to something a panel can show.
  ///
  /// WebDAV errors arrive as XML or as a sentence; either is more use than the
  /// status code alone. Redacted like everything else that leaves this class.
  String? _serverSaid(String? body) {
    final String text = (body ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) {
      return null;
    }
    const int limit = 300;
    final String clipped = text.length > limit
        ? '${text.substring(0, limit)}...'
        : text;
    return 'The server said: $clipped';
  }

  static Duration? _retryAfter(Map<String, String> headers) {
    final String? raw = headers['retry-after'];
    final int? seconds = raw == null ? null : int.tryParse(raw.trim());
    return seconds == null ? null : Duration(seconds: seconds);
  }

  /// The app password must never leave this class — not in an error, not in a
  /// log line, not in an exception derived from a request (§27).
  String _redact(String text) => _redactFor(_config, text);

  String _redactFor(WebDavConfig candidate, String text) {
    final String password = candidate.password;
    if (password.isEmpty) {
      return text;
    }
    return text
        .replaceAll(password, _redacted)
        .replaceAll(Uri.encodeComponent(password), _redacted)
        .replaceAll(candidate.authorizationHeader, _redacted);
  }

  /// Last line of defence for an exception this class did not anticipate: it is
  /// reported as a typed failure, and its text is redacted (§26, §27).
  UploadError _unexpected(Object error) => UploadError(
    UploadErrorKind.unknown,
    _redact('The WebDAV upload failed unexpectedly: $error'),
  );
}

/// A request whose body is a stream of known length.
///
/// `package:http` ships multipart and in-memory bodies; a plain `PUT` of a
/// gigabyte needs neither — the file is read as it is sent, so memory does not
/// grow with the recording.
class _StreamedBodyRequest extends http.BaseRequest {
  _StreamedBodyRequest(super.method, super.url, this._body, int length) {
    contentLength = length;
  }

  final Stream<List<int>> _body;

  @override
  http.ByteStream finalize() {
    super.finalize();
    return http.ByteStream(_body);
  }
}
