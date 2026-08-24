import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:upload_core/upload_core.dart';
import 'package:upload_webdav/upload_webdav.dart';

const String _password = 'koofr-app-password-do-not-use';
const String _username = 'recorder@example.com';

const RetryPolicy _fastPolicy = RetryPolicy(
  maxAttempts: 3,
  initialDelay: Duration(milliseconds: 1),
  maxDelay: Duration(milliseconds: 5),
);

/// One request the fake server saw.
class _Seen {
  _Seen(this.method, this.url, this.headers, this.bodyBytes, this.body);

  final String method;
  final Uri url;
  final Map<String, String> headers;
  final int bodyBytes;

  /// Decoded request body, for the small XML ones.
  final String body;
}

void main() {
  late Directory tempDir;
  late List<_Seen> seen;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('relay_webdav_');
    seen = <_Seen>[];
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  UploadFile writeRecording({
    int sizeBytes = 256 * 1024,
    String name = 'relay-2026-08-23-1015.mp4',
  }) {
    final File file = File('${tempDir.path}${Platform.pathSeparator}$name');
    final Uint8List bytes = Uint8List(sizeBytes);
    for (int i = 0; i < sizeBytes; i++) {
      bytes[i] = i % 251;
    }
    file.writeAsBytesSync(bytes);
    return UploadFile(path: file.path, sizeBytes: sizeBytes, displayName: name);
  }

  /// A server that answers WebDAV correctly unless a test says otherwise.
  http.Client server({
    int propfind = 207,
    int mkcol = 201,
    List<int> put = const <int>[201],
    Map<String, String> putHeaders = const <String, String>{},
    String errorBody = '',
  }) {
    final List<int> putStatuses = List<int>.of(put);
    return MockClient.streaming((
      http.BaseRequest request,
      http.ByteStream body,
    ) async {
      final Uint8List bytes = await body.toBytes();
      seen.add(
        _Seen(
          request.method,
          request.url,
          request.headers,
          bytes.length,
          // Only the small XML bodies are text; a PUT carries a video, and
          // decoding that as UTF-8 throws.
          request.method == 'PUT' || bytes.isEmpty
              ? ''
              : utf8.decode(bytes, allowMalformed: true),
        ),
      );
      final int status = switch (request.method) {
        'PROPFIND' => propfind,
        'MKCOL' => mkcol,
        _ => putStatuses.isEmpty ? 201 : putStatuses.removeAt(0),
      };
      final bool failed = status >= 400;
      return http.StreamedResponse(
        Stream<List<int>>.value(
          failed ? utf8.encode(errorBody) : const <int>[],
        ),
        status,
        headers: request.method == 'PUT'
            ? putHeaders
            : const <String, String>{},
      );
    });
  }

  WebDavUploadDestination destination({
    required CredentialStore store,
    http.Client? client,
    RetryPolicy policy = _fastPolicy,
  }) => WebDavUploadDestination(
    credentialStore: store,
    client: client ?? server(),
    retryPolicy: policy,
  );

  Future<WebDavUploadDestination> connected({
    required CredentialStore store,
    http.Client? client,
    RetryPolicy policy = _fastPolicy,
    String? folder,
  }) async {
    final WebDavUploadDestination webdav = destination(
      store: store,
      client: client,
      policy: policy,
    );
    await webdav.connect(<String, String>{
      WebDavUploadDestination.baseUrlField: 'https://app.koofr.net/dav/Koofr',
      WebDavUploadDestination.usernameField: _username,
      WebDavUploadDestination.passwordField: _password,
      WebDavUploadDestination.folderField: ?folder,
    });
    seen.clear();
    return webdav;
  }

  group('setup', () {
    test('asks for an address, a user and an app password', () {
      final DestinationSetup setup = destination(
        store: InMemoryCredentialStore(),
      ).setup;
      expect(setup.kind, DestinationSetupKind.credentials);
      expect(
        setup.fields.map((DestinationField f) => f.key),
        containsAll(<String>[
          WebDavUploadDestination.baseUrlField,
          WebDavUploadDestination.usernameField,
          WebDavUploadDestination.passwordField,
        ]),
      );
      final DestinationField password = setup.fields.firstWhere(
        (DestinationField f) => f.key == WebDavUploadDestination.passwordField,
      );
      expect(
        password.secret,
        isTrue,
        reason: 'an app password is a credential',
      );
      expect(
        setup.steps.join(' '),
        contains('app password'),
        reason: 'the account password is refused by these providers',
      );
    });

    test('reports no size limit of its own', () {
      expect(
        destination(store: InMemoryCredentialStore())
            .capabilities
            .maxFileSizeBytes,
        isNull,
      );
      expect(
        destination(store: InMemoryCredentialStore())
            .capabilities
            .supportsResume,
        isFalse,
        reason: 'WebDAV has no standard way to resume a partial PUT',
      );
    });
  });

  group('connect', () {
    test(
      'checks the credentials and creates the folder before storing',
      () async {
        final CredentialStore store = InMemoryCredentialStore();
        final WebDavUploadDestination webdav = destination(store: store);
        expect(await webdav.isConnected(), isFalse);

        await webdav.connect(<String, String>{
          WebDavUploadDestination.baseUrlField:
              'https://app.koofr.net/dav/Koofr',
          WebDavUploadDestination.usernameField: _username,
          WebDavUploadDestination.passwordField: _password,
        });

        expect(seen.map((_Seen r) => r.method), <String>[
          'PROPFIND',
          'MKCOL',
        ], reason: 'the account is proven writable before anything is stored');
        expect(seen.last.url.path, endsWith('/dav/Koofr/Relay'));
        expect(await webdav.isConnected(), isTrue);
        expect(
          await store.read(WebDavUploadDestination.passwordKey),
          _password,
        );
        expect(await webdav.describeAccount(), contains('app.koofr.net'));
      },
    );

    test('a folder that already exists is not an error', () async {
      final CredentialStore store = InMemoryCredentialStore();
      final WebDavUploadDestination webdav = destination(
        store: store,
        // 405 Method Not Allowed is what a server says about an existing
        // collection, which is the normal case after the first connect.
        client: server(mkcol: 405),
      );

      await webdav.connect(<String, String>{
        WebDavUploadDestination.baseUrlField: 'https://app.koofr.net/dav/Koofr',
        WebDavUploadDestination.usernameField: _username,
        WebDavUploadDestination.passwordField: _password,
      });

      expect(await webdav.isConnected(), isTrue);
    });

    test('the probe asks for a property rather than for nothing', () async {
      final CredentialStore store = InMemoryCredentialStore();
      final WebDavUploadDestination webdav = destination(store: store);
      await webdav.connect(<String, String>{
        WebDavUploadDestination.baseUrlField: 'https://app.koofr.net/dav/Koofr',
        WebDavUploadDestination.usernameField: _username,
        WebDavUploadDestination.passwordField: _password,
      });

      final _Seen probe = seen.first;
      expect(probe.method, 'PROPFIND');
      expect(probe.headers['depth'], '0');
      // An empty <prop/> is accepted by some servers and answered with 400 by
      // others, which is how this destination first failed against a real one.
      expect(probe.body, isNot(contains('<d:prop/>')));
      expect(probe.body, contains('resourcetype'));
    });

    test('a server that dislikes the probe can still be connected', () async {
      final CredentialStore store = InMemoryCredentialStore();
      final WebDavUploadDestination webdav = destination(
        store: store,
        // The probe is a courtesy; creating the folder is the real test, and a
        // server is entitled to refuse a PROPFIND for reasons that say nothing
        // about the account.
        client: server(propfind: 400, mkcol: 201),
      );

      await webdav.connect(<String, String>{
        WebDavUploadDestination.baseUrlField: 'https://app.koofr.net/dav/Koofr',
        WebDavUploadDestination.usernameField: _username,
        WebDavUploadDestination.passwordField: _password,
      });

      expect(await webdav.isConnected(), isTrue);
      expect(seen.map((_Seen r) => r.method), <String>['PROPFIND', 'MKCOL']);
    });

    test('a refusal names the step and quotes the server', () async {
      final CredentialStore store = InMemoryCredentialStore();
      final WebDavUploadDestination webdav = destination(
        store: store,
        client: server(
          mkcol: 400,
          errorBody: '<d:error xmlns:d="DAV:">\n  bad destination\n</d:error>',
        ),
      );

      await expectLater(
        webdav.connect(<String, String>{
          WebDavUploadDestination.baseUrlField:
              'https://app.koofr.net/dav/Koofr',
          WebDavUploadDestination.usernameField: _username,
          WebDavUploadDestination.passwordField: _password,
        }),
        throwsA(
          isA<UploadError>()
              .having(
                (UploadError e) => e.message,
                'message',
                contains('creating the folder'),
              )
              .having(
                (UploadError e) => e.details,
                'details',
                contains('bad destination'),
              ),
        ),
      );
    });

    test('a rejected password is reported and nothing is stored', () async {
      final CredentialStore store = InMemoryCredentialStore();
      final WebDavUploadDestination webdav = destination(
        store: store,
        // Definitive, unlike other probe failures: it is about the account.
        client: server(propfind: 401),
      );

      await expectLater(
        webdav.connect(<String, String>{
          WebDavUploadDestination.baseUrlField:
              'https://app.koofr.net/dav/Koofr',
          WebDavUploadDestination.usernameField: _username,
          WebDavUploadDestination.passwordField: _password,
        }),
        throwsA(
          isA<UploadError>()
              .having(
                (UploadError e) => e.kind,
                'kind',
                UploadErrorKind.authentication,
              )
              .having(
                (UploadError e) => e.message,
                'message',
                contains('app password'),
              ),
        ),
      );
      expect(await store.read(WebDavUploadDestination.passwordKey), isNull);
    });

    test('a wrong address is reported as such', () async {
      final CredentialStore store = InMemoryCredentialStore();
      final WebDavUploadDestination webdav = destination(
        store: store,
        client: server(propfind: 404),
      );

      await expectLater(
        webdav.connect(<String, String>{
          WebDavUploadDestination.baseUrlField: 'https://app.koofr.net/dav',
          WebDavUploadDestination.usernameField: _username,
          WebDavUploadDestination.passwordField: _password,
        }),
        throwsA(
          isA<UploadError>().having(
            (UploadError e) => e.message,
            'message',
            contains('/dav/Koofr'),
          ),
        ),
      );
    });

    test('a non-http address never reaches the network', () async {
      final CredentialStore store = InMemoryCredentialStore();
      final WebDavUploadDestination webdav = destination(store: store);

      await expectLater(
        webdav.connect(<String, String>{
          WebDavUploadDestination.baseUrlField: 'ftp://example.invalid/dav',
          WebDavUploadDestination.usernameField: _username,
          WebDavUploadDestination.passwordField: _password,
        }),
        throwsA(isA<UploadError>()),
      );
      expect(seen, isEmpty);
    });

    test('an empty password field keeps the stored one', () async {
      final CredentialStore store = InMemoryCredentialStore();
      final WebDavUploadDestination webdav = await connected(store: store);

      await webdav.connect(<String, String>{
        WebDavUploadDestination.baseUrlField: 'https://app.koofr.net/dav/Koofr',
        WebDavUploadDestination.usernameField: _username,
        WebDavUploadDestination.passwordField: '',
        WebDavUploadDestination.folderField: 'Screencasts',
      });

      expect(webdav.config.password, _password);
      expect(webdav.config.folder, 'Screencasts');
    });

    test('the stored values offered back never include the password', () async {
      final CredentialStore store = InMemoryCredentialStore();
      final WebDavUploadDestination webdav = await connected(store: store);

      final Map<String, String> values = await webdav.storedSetupValues();
      expect(values[WebDavUploadDestination.usernameField], _username);
      expect(values.values, isNot(contains(_password)));
    });

    test(
      'credentials survive a restart, and a disconnect survives it too',
      () async {
        final CredentialStore store = InMemoryCredentialStore();
        await connected(store: store);

        final WebDavUploadDestination restarted = destination(store: store);
        expect(await restarted.isConnected(), isTrue);
        expect(restarted.config.username, _username);

        await restarted.disconnect();
        expect(await destination(store: store).isConnected(), isFalse);
      },
    );
  });

  group('upload', () {
    test('PUTs the recording and reports progress then success', () async {
      final CredentialStore store = InMemoryCredentialStore();
      final WebDavUploadDestination webdav = await connected(store: store);
      final UploadFile file = writeRecording();

      final List<UploadEvent> events = await webdav
          .upload(file, const UploadContext(uploadId: 'u1'))
          .toList();

      expect(seen.single.method, 'PUT');
      expect(seen.single.url.path, endsWith('/Relay/${file.displayName}'));
      expect(seen.single.bodyBytes, file.sizeBytes);
      expect(
        seen.single.headers['authorization'],
        'Basic ${base64Encode(utf8.encode('$_username:$_password'))}',
      );

      expect(events.first, isA<UploadStarted>());
      expect(events.whereType<UploadProgress>(), isNotEmpty);
      expect(events.last, isA<UploadSucceeded>());
      final UploadSucceeded done = events.last as UploadSucceeded;
      expect(done.result.destinationId, WebDavUploadDestination.destinationId);
      expect(done.result.remoteName, file.displayName);
      expect(done.result.bytesUploaded, file.sizeBytes);
    });

    test(
      'an unconfigured destination fails pre-flight without sending',
      () async {
        final CredentialStore store = InMemoryCredentialStore();
        final WebDavUploadDestination webdav = destination(store: store);
        final UploadFile file = writeRecording();

        final List<UploadEvent> events = await webdav
            .upload(file, const UploadContext(uploadId: 'u1'))
            .toList();

        expect(seen, isEmpty);
        final UploadFailed failed = events.single as UploadFailed;
        expect(failed.error.kind, UploadErrorKind.notConfigured);
      },
    );

    test(
      'a missing local file is reported without touching the network',
      () async {
        final CredentialStore store = InMemoryCredentialStore();
        final WebDavUploadDestination webdav = await connected(store: store);
        final UploadFile phantom = UploadFile(
          path: '${tempDir.path}${Platform.pathSeparator}gone.mp4',
          sizeBytes: 1024,
          displayName: 'gone.mp4',
        );

        final List<UploadEvent> events = await webdav
            .upload(phantom, const UploadContext(uploadId: 'u1'))
            .toList();

        expect(seen, isEmpty);
        expect(
          (events.single as UploadFailed).error.kind,
          UploadErrorKind.localFileUnavailable,
        );
      },
    );

    test('a 5xx is retried and can still succeed', () async {
      final CredentialStore store = InMemoryCredentialStore();
      final WebDavUploadDestination webdav = await connected(
        store: store,
        client: server(put: <int>[503, 201]),
      );
      final UploadFile file = writeRecording();

      final List<UploadEvent> events = await webdav
          .upload(file, const UploadContext(uploadId: 'u1'))
          .toList();

      expect(events.whereType<UploadRetrying>(), hasLength(1));
      expect(events.last, isA<UploadSucceeded>());
      expect(seen.where((_Seen r) => r.method == 'PUT'), hasLength(2));
    });

    test('a full account is a terminal failure, not a retry loop', () async {
      final CredentialStore store = InMemoryCredentialStore();
      final WebDavUploadDestination webdav = await connected(
        store: store,
        client: server(put: <int>[507]),
      );
      final UploadFile file = writeRecording();

      final List<UploadEvent> events = await webdav
          .upload(file, const UploadContext(uploadId: 'u1'))
          .toList();

      expect(events.whereType<UploadRetrying>(), isEmpty);
      final UploadFailed failed = events.last as UploadFailed;
      expect(failed.error.kind, UploadErrorKind.destinationRejected);
      expect(failed.error.message, contains('space'));
    });

    test(
      'cancelling stops the transfer and ends in exactly one event',
      () async {
        final CredentialStore store = InMemoryCredentialStore();
        final WebDavUploadDestination webdav = await connected(store: store);
        final UploadFile file = writeRecording(sizeBytes: 4 * 1024 * 1024);

        final List<UploadEvent> events = <UploadEvent>[];
        final Completer<void> done = Completer<void>();
        webdav.upload(file, const UploadContext(uploadId: 'u1')).listen((
          UploadEvent event,
        ) {
          events.add(event);
          if (event is UploadProgress && !done.isCompleted) {
            unawaited(webdav.cancel('u1'));
          }
        }, onDone: done.complete);
        await done.future;

        expect(events.last, isA<UploadCancelled>());
        expect(
          events.where(
            (UploadEvent e) =>
                e is UploadSucceeded ||
                e is UploadFailed ||
                e is UploadCancelled,
          ),
          hasLength(1),
          reason: 'the contract is exactly one terminal event',
        );
      },
    );
  });

  group('secret hygiene', () {
    test('the app password never reaches an event, an error or a toString', () async {
      // Seeded rather than connected: the client below refuses everything, so
      // the destination has to come up from stored credentials the way it does
      // after a restart.
      final CredentialStore store = InMemoryCredentialStore();
      await store.write(
        WebDavUploadDestination.baseUrlKey,
        'https://app.koofr.net/dav/Koofr',
      );
      await store.write(WebDavUploadDestination.usernameKey, _username);
      await store.write(WebDavUploadDestination.passwordKey, _password);
      await store.write(WebDavUploadDestination.folderKey, 'Relay');
      final WebDavUploadDestination webdav = destination(
        store: store,
        policy: RetryPolicy.none,
        client: MockClient.streaming((
          http.BaseRequest request,
          http.ByteStream body,
        ) async {
          await body.toBytes();
          throw StateError('boom with ${request.headers['authorization']}');
        }),
      );
      final UploadFile file = writeRecording();

      final List<UploadEvent> events = await webdav
          .upload(file, const UploadContext(uploadId: 'u1'))
          .toList();

      final String rendered = <String>[
        events.map((UploadEvent e) => e.toString()).join(' '),
        (events.last as UploadFailed).error.message,
        (events.last as UploadFailed).error.details ?? '',
        webdav.config.toString(),
        webdav.setup.steps.join(' '),
      ].join(' ');
      expect(rendered, isNot(contains(_password)));
      expect(
        rendered,
        isNot(contains(base64Encode(utf8.encode('$_username:$_password')))),
      );
    });
  });
}
