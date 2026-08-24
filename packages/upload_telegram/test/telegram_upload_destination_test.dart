import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:upload_core/upload_core.dart';
import 'package:upload_telegram/upload_telegram.dart';

const String _botToken = '7654321:AAF-relay-test-token_do-not-use';
const String _chatId = '-1001234567890';
const String _fileId = 'BAACAgQAAxkBAAIRelayTestVideoFileId';

const RetryPolicy _fastPolicy = RetryPolicy(
  maxAttempts: 3,
  initialDelay: Duration(milliseconds: 1),
  maxDelay: Duration(milliseconds: 5),
);

const Map<String, String> _jsonHeaders = <String, String>{
  'content-type': 'application/json',
};

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('relay_telegram_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  UploadFile writeRecording({
    int sizeBytes = 512 * 1024,
    String name = 'relay-2026-08-22-101500.mp4',
  }) {
    final File file = File('${tempDir.path}${Platform.pathSeparator}$name');
    final Uint8List bytes = Uint8List(sizeBytes);
    for (int i = 0; i < sizeBytes; i++) {
      bytes[i] = i % 251;
    }
    file.writeAsBytesSync(bytes);
    return UploadFile(path: file.path, sizeBytes: sizeBytes, displayName: name);
  }

  UploadFile phantomRecording({
    required int sizeBytes,
    String name = 'big.mp4',
  }) => UploadFile(
    path: '${tempDir.path}${Platform.pathSeparator}$name',
    sizeBytes: sizeBytes,
    displayName: name,
  );

  String successBody() => jsonEncode(<String, Object?>{
    'ok': true,
    'result': <String, Object?>{
      'message_id': 4242,
      'video': <String, Object?>{'file_id': _fileId, 'duration': 12},
    },
  });

  TelegramUploadDestination hostedDestination(
    MockClient client, {
    RetryPolicy policy = RetryPolicy.none,
  }) => TelegramUploadDestination(
    config: TelegramConfig.hosted(botToken: _botToken, chatId: _chatId),
    client: client,
    retryPolicy: policy,
  );

  MockClient neverCalled() =>
      MockClient((http.Request request) async => fail('No request expected.'));

  group('validate', () {
    test('rejects a file over the hosted cap and names both sizes', () async {
      final TelegramUploadDestination destination = hostedDestination(
        neverCalled(),
      );

      final UploadValidationResult result = await destination.validate(
        phantomRecording(sizeBytes: 60 * 1024 * 1024),
      );

      expect(result.isValid, isFalse);
      expect(result.error?.kind, UploadErrorKind.fileTooLarge);
      expect(result.error?.message, contains('60.0 MB'));
      expect(result.error?.message, contains('50.0 MB'));
    });

    test('accepts the same file against a Local Bot API Server', () async {
      final TelegramUploadDestination destination = TelegramUploadDestination(
        config: TelegramConfig(
          botToken: _botToken,
          chatId: _chatId,
          baseUrl: Uri.parse('http://127.0.0.1:8081/telegram'),
        ),
        client: neverCalled(),
      );

      final UploadValidationResult result = await destination.validate(
        phantomRecording(sizeBytes: 60 * 1024 * 1024),
      );

      expect(result.isValid, isTrue);
      expect(destination.capabilities.maxFileSizeBytes, isNull);
      expect(
        destination.capabilities.transportSummary,
        'Single upload · no size limit · Local Bot API Server',
      );
      expect(await destination.describeAccount(), contains(_chatId));
    });

    test('rejects everything while unconfigured', () async {
      final TelegramUploadDestination destination = TelegramUploadDestination(
        config: TelegramConfig.unconfigured(),
        client: neverCalled(),
      );

      final UploadValidationResult result = await destination.validate(
        phantomRecording(sizeBytes: 1024),
      );

      expect(result.error?.kind, UploadErrorKind.notConfigured);
      expect(await destination.describeAccount(), isNull);

      final List<UploadEvent> events = await destination
          .upload(
            phantomRecording(sizeBytes: 1024),
            const UploadContext(uploadId: 'u-unconfigured'),
          )
          .toList();

      // The destination pre-flights itself — `upload()` has to be safe to call
      // directly — but it does not announce it. `UploadValidating` is the
      // coordinator's event, emitted once for every destination, and this one
      // used to emit a second copy of its own.
      expect(events.whereType<UploadValidating>(), isEmpty);
      expect(events, hasLength(1));
      expect(events.last, isA<UploadFailed>());
      expect(
        (events.last as UploadFailed).error.kind,
        UploadErrorKind.notConfigured,
      );
    });

    test('capabilities describe an unresumable, cancellable transport', () {
      final TelegramUploadDestination destination = hostedDestination(
        neverCalled(),
      );

      expect(destination.id, 'telegram');
      expect(destination.displayName, 'Telegram');
      expect(
        destination.capabilities.maxFileSizeBytes,
        TelegramConfig.hostedMaxUploadBytes,
      );
      expect(destination.capabilities.supportsResume, isFalse);
      expect(destination.capabilities.supportsCancellation, isTrue);
      expect(destination.capabilities.supportsProgress, isTrue);
      expect(destination.capabilities.requiresAuthentication, isFalse);
      expect(
        destination.capabilities.transportSummary,
        'Single upload · 50 MB limit',
      );
    });
  });

  group('upload', () {
    test('emits started, real byte progress, then succeeded', () async {
      final UploadFile file = writeRecording();
      late http.Request captured;
      final TelegramUploadDestination destination = hostedDestination(
        MockClient((http.Request request) async {
          captured = request;
          return http.Response(successBody(), 200, headers: _jsonHeaders);
        }),
      );

      final List<UploadEvent> events = await destination
          .upload(
            file,
            const UploadContext(
              uploadId: 'u-success',
              caption: 'Relay recording',
            ),
          )
          .toList();

      expect(events.whereType<UploadValidating>(), isEmpty);
      expect(events.first, isA<UploadStarted>());
      expect((events.first as UploadStarted).totalBytes, file.sizeBytes);
      expect((events.first as UploadStarted).resumed, isFalse);

      final List<UploadProgress> progress = events
          .whereType<UploadProgress>()
          .toList();
      expect(progress.length, greaterThan(1));
      int previous = -1;
      for (final UploadProgress event in progress) {
        expect(event.bytesSent, greaterThan(previous));
        expect(event.totalBytes, file.sizeBytes);
        previous = event.bytesSent;
      }
      expect(progress.last.bytesSent, file.sizeBytes);
      expect(progress.last.fraction, 1.0);

      expect(
        events
            .where(
              (UploadEvent event) =>
                  event is UploadSucceeded ||
                  event is UploadFailed ||
                  event is UploadCancelled,
            )
            .length,
        1,
      );
      final UploadSucceeded succeeded = events.last as UploadSucceeded;
      expect(succeeded.result.destinationId, 'telegram');
      expect(succeeded.result.remoteFileId, _fileId);
      expect(succeeded.result.remoteName, file.displayName);
      expect(succeeded.result.bytesUploaded, file.sizeBytes);

      expect(captured.method, 'POST');
      expect(captured.url.path, '/bot$_botToken/sendVideo');
      final String body = latin1.decode(captured.bodyBytes);
      expect(body, contains('name="chat_id"'));
      expect(body, contains(_chatId));
      expect(body, contains('name="supports_streaming"'));
      expect(body, contains('name="caption"'));
      expect(body, contains('Relay recording'));
      expect(body, contains('filename="${file.displayName}"'));
      expect(captured.bodyBytes.length, greaterThan(file.sizeBytes));
    });

    test(
      'a Local Bot API Server base path is preserved in the endpoint',
      () async {
        final UploadFile file = writeRecording(sizeBytes: 64 * 1024);
        late Uri captured;
        final TelegramUploadDestination destination = TelegramUploadDestination(
          config: TelegramConfig(
            botToken: _botToken,
            chatId: _chatId,
            baseUrl: Uri.parse('http://127.0.0.1:8081/telegram'),
          ),
          client: MockClient((http.Request request) async {
            captured = request.url;
            return http.Response(successBody(), 200, headers: _jsonHeaders);
          }),
        );

        final List<UploadEvent> events = await destination
            .upload(file, const UploadContext(uploadId: 'u-local'))
            .toList();

        expect(events.last, isA<UploadSucceeded>());
        expect(captured.host, '127.0.0.1');
        expect(captured.port, 8081);
        expect(captured.path, '/telegram/bot$_botToken/sendVideo');
      },
    );

    test(
      'falls back to message_id when the response carries no video',
      () async {
        final UploadFile file = writeRecording(sizeBytes: 32 * 1024);
        final TelegramUploadDestination destination = hostedDestination(
          MockClient(
            (http.Request request) async => http.Response(
              jsonEncode(<String, Object?>{
                'ok': true,
                'result': <String, Object?>{'message_id': 4242},
              }),
              200,
              headers: _jsonHeaders,
            ),
          ),
        );

        final List<UploadEvent> events = await destination
            .upload(file, const UploadContext(uploadId: 'u-message-id'))
            .toList();

        expect((events.last as UploadSucceeded).result.remoteFileId, '4242');
      },
    );

    test('a missing local file fails before any request', () async {
      final TelegramUploadDestination destination = hostedDestination(
        neverCalled(),
      );

      final List<UploadEvent> events = await destination
          .upload(
            phantomRecording(sizeBytes: 1024, name: 'gone.mp4'),
            const UploadContext(uploadId: 'u-missing'),
          )
          .toList();

      expect(
        (events.last as UploadFailed).error.kind,
        UploadErrorKind.localFileUnavailable,
      );
    });

    test(
      'ok:false is surfaced as destinationRejected with the description',
      () async {
        final UploadFile file = writeRecording(sizeBytes: 32 * 1024);
        final TelegramUploadDestination destination = hostedDestination(
          MockClient(
            (http.Request request) async => http.Response(
              jsonEncode(<String, Object?>{
                'ok': false,
                'description': 'Bad Request: chat not found',
              }),
              200,
              headers: _jsonHeaders,
            ),
          ),
        );

        final List<UploadEvent> events = await destination
            .upload(file, const UploadContext(uploadId: 'u-rejected'))
            .toList();

        final UploadFailed failed = events.last as UploadFailed;
        expect(failed.error.kind, UploadErrorKind.destinationRejected);
        expect(failed.error.message, contains('chat not found'));
      },
    );
  });

  group('error mapping and retries', () {
    test('429 reports rateLimited with retry_after from the payload', () async {
      final UploadFile file = writeRecording(sizeBytes: 32 * 1024);
      int calls = 0;
      final TelegramUploadDestination destination = hostedDestination(
        MockClient((http.Request request) async {
          calls++;
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': false,
              'description': 'Too Many Requests: retry after 7',
              'parameters': <String, Object?>{'retry_after': 7},
            }),
            429,
            headers: <String, String>{..._jsonHeaders, 'retry-after': '11'},
          );
        }),
        policy: _fastPolicy,
      );

      final List<UploadEvent> events = await destination
          .upload(file, const UploadContext(uploadId: 'u-429'))
          .toList();

      final UploadFailed failed = events.last as UploadFailed;
      expect(failed.error.kind, UploadErrorKind.rateLimited);
      expect(failed.error.retryAfter, const Duration(seconds: 7));
      expect(calls, _fastPolicy.maxAttempts);
      expect(events.whereType<UploadRetrying>().length, 2);
    });

    test('429 falls back to the Retry-After header', () async {
      final UploadFile file = writeRecording(sizeBytes: 32 * 1024);
      final TelegramUploadDestination destination = hostedDestination(
        MockClient(
          (http.Request request) async => http.Response(
            jsonEncode(<String, Object?>{
              'ok': false,
              'description': 'Too Many Requests',
            }),
            429,
            headers: <String, String>{..._jsonHeaders, 'Retry-After': '3'},
          ),
        ),
      );

      final List<UploadEvent> events = await destination
          .upload(file, const UploadContext(uploadId: 'u-429-header'))
          .toList();

      final UploadFailed failed = events.last as UploadFailed;
      expect(failed.error.kind, UploadErrorKind.rateLimited);
      expect(failed.error.retryAfter, const Duration(seconds: 3));
    });

    test('401 is an authentication failure and is never retried', () async {
      final UploadFile file = writeRecording(sizeBytes: 32 * 1024);
      int calls = 0;
      final TelegramUploadDestination destination = hostedDestination(
        MockClient((http.Request request) async {
          calls++;
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': false,
              'description': 'Unauthorized: ${request.url} was rejected',
            }),
            401,
            headers: _jsonHeaders,
          );
        }),
        policy: _fastPolicy,
      );

      final List<UploadEvent> events = await destination
          .upload(file, const UploadContext(uploadId: 'u-401'))
          .toList();

      final UploadFailed failed = events.last as UploadFailed;
      expect(failed.error.kind, UploadErrorKind.authentication);
      expect(failed.error.isRetryable, isFalse);
      expect(calls, 1);
      expect(events.whereType<UploadRetrying>(), isEmpty);
      expect(failed.error.message, isNot(contains(_botToken)));
      expect(failed.error.message, contains('<redacted>'));
    });

    test(
      '500 is retried up to the policy cap, then fails as network',
      () async {
        final UploadFile file = writeRecording(sizeBytes: 64 * 1024);
        int calls = 0;
        final TelegramUploadDestination destination = hostedDestination(
          MockClient((http.Request request) async {
            calls++;
            return http.Response('<html>bad gateway</html>', 502);
          }),
          policy: _fastPolicy,
        );

        final List<UploadEvent> events = await destination
            .upload(file, const UploadContext(uploadId: 'u-500'))
            .toList();

        expect(calls, _fastPolicy.maxAttempts);
        final List<UploadRetrying> retries = events
            .whereType<UploadRetrying>()
            .toList();
        expect(retries.length, _fastPolicy.maxAttempts - 1);
        expect(retries.first.attempt, 2);
        expect(retries.first.cause.kind, UploadErrorKind.network);

        for (final UploadRetrying retry in retries) {
          final UploadEvent next = events[events.indexOf(retry) + 1];
          expect(next, isA<UploadProgress>());
          expect((next as UploadProgress).bytesSent, 0);
        }

        final UploadFailed failed = events.last as UploadFailed;
        expect(failed.error.kind, UploadErrorKind.network);
        expect(failed.error.isRetryable, isTrue);
      },
    );

    test('a transport exception maps to a retryable network error', () async {
      final UploadFile file = writeRecording(sizeBytes: 32 * 1024);
      final TelegramUploadDestination destination = hostedDestination(
        MockClient((http.Request request) async {
          throw const SocketException('Connection refused');
        }),
        policy: RetryPolicy.none,
      );

      final List<UploadEvent> events = await destination
          .upload(file, const UploadContext(uploadId: 'u-socket'))
          .toList();

      final UploadFailed failed = events.last as UploadFailed;
      expect(failed.error.kind, UploadErrorKind.network);
      expect(failed.error.isRetryable, isTrue);
    });
  });

  group('cancellation', () {
    test(
      'cancelling mid-upload yields UploadCancelled and no success',
      () async {
        final UploadFile file = writeRecording(sizeBytes: 1024 * 1024);
        final TelegramUploadDestination destination = hostedDestination(
          MockClient(
            (http.Request request) async =>
                http.Response(successBody(), 200, headers: _jsonHeaders),
          ),
        );

        final List<UploadEvent> events = <UploadEvent>[];
        final Completer<void> done = Completer<void>();
        bool requested = false;
        final StreamSubscription<UploadEvent> subscription = destination
            .upload(file, const UploadContext(uploadId: 'u-cancel'))
            .listen((UploadEvent event) {
              events.add(event);
              if (event is UploadProgress && !requested) {
                requested = true;
                unawaited(destination.cancel('u-cancel'));
              }
            }, onDone: done.complete);

        await done.future;
        await subscription.cancel();

        expect(requested, isTrue);
        expect(events.whereType<UploadSucceeded>(), isEmpty);
        expect(events.last, isA<UploadCancelled>());
        expect(events.whereType<UploadCancelled>().length, 1);

        await destination.cancel('u-cancel');
        await destination.cancel('never-started');
        expect(events.whereType<UploadCancelled>().length, 1);
      },
    );
  });

  group('terminal event contract', () {
    test(
      'a malformed base URL fails as notConfigured, not as a crash',
      () async {
        final UploadFile file = writeRecording(sizeBytes: 32 * 1024);
        final TelegramUploadDestination destination = TelegramUploadDestination(
          config: TelegramConfig(
            botToken: _botToken,
            chatId: _chatId,
            // A missing scheme is a one-character typo in the configured base URL.
            baseUrl: Uri.parse('localhost:8081'),
          ),
          client: MockClient(
            (http.Request request) async =>
                throw ArgumentError('No host specified in URI ${request.url}'),
          ),
        );

        expect(
          (await destination.validate(file)).error?.kind,
          UploadErrorKind.notConfigured,
        );

        final _UploadRun run = await _runUpload(destination, file, 'u-bad-url');

        expect(run.uncaught, isEmpty);
        expect(run.terminals.length, 1);
        final UploadFailed failed = run.terminals.single as UploadFailed;
        expect(failed.error.kind, UploadErrorKind.notConfigured);
        expect(_describe(failed), isNot(contains(_botToken)));
      },
    );

    test(
      'an ArgumentError naming the request URL becomes a redacted failure',
      () async {
        final UploadFile file = writeRecording(sizeBytes: 32 * 1024);
        final TelegramUploadDestination destination = hostedDestination(
          MockClient(
            (http.Request request) async =>
                throw ArgumentError('No host specified in URI ${request.url}'),
          ),
        );

        final _UploadRun run = await _runUpload(
          destination,
          file,
          'u-argument-error',
        );

        expect(run.uncaught, isEmpty);
        expect(run.terminals.length, 1);
        final UploadFailed failed = run.terminals.single as UploadFailed;
        expect(failed.error.kind, UploadErrorKind.unknown);
        expect(_describe(failed), isNot(contains(_botToken)));
        expect(failed.error.message, contains('<redacted>'));
      },
    );

    test('a TLS handshake failure ends in a typed network failure', () async {
      final UploadFile file = writeRecording(sizeBytes: 32 * 1024);
      final TelegramUploadDestination destination = hostedDestination(
        MockClient((http.Request request) async {
          throw const HandshakeException('CERTIFICATE_VERIFY_FAILED');
        }),
      );

      final _UploadRun run = await _runUpload(destination, file, 'u-tls');

      expect(run.uncaught, isEmpty);
      expect(run.terminals.length, 1);
      final UploadFailed failed = run.terminals.single as UploadFailed;
      expect(failed.error.kind, UploadErrorKind.network);
      expect(failed.error.isRetryable, isTrue);
      expect(_describe(failed), isNot(contains(_botToken)));
    });

    test('a recording that vanishes between attempts fails as localFileUnavailable', () async {
      final UploadFile file = writeRecording(sizeBytes: 32 * 1024);
      int calls = 0;
      final TelegramUploadDestination destination = hostedDestination(
        MockClient((http.Request request) async {
          calls++;
          File(file.path).deleteSync();
          return http.Response('busy', 503);
        }),
        policy: _fastPolicy,
      );

      final _UploadRun run = await _runUpload(destination, file, 'u-vanished');

      expect(calls, 1);
      expect(run.uncaught, isEmpty);
      expect(run.terminals.length, 1);
      final UploadFailed failed = run.terminals.single as UploadFailed;
      expect(failed.error.kind, UploadErrorKind.localFileUnavailable);
      expect(failed.error.isRetryable, isFalse);
    });

    test(
      'a server that never answers stalls out as a network failure',
      () async {
        final UploadFile file = writeRecording(sizeBytes: 32 * 1024);
        final TelegramUploadDestination destination = TelegramUploadDestination(
          config: TelegramConfig.hosted(botToken: _botToken, chatId: _chatId),
          client: MockClient(
            (http.Request request) => Completer<http.Response>().future,
          ),
          retryPolicy: RetryPolicy.none,
          stallTimeout: const Duration(milliseconds: 100),
        );

        final _UploadRun run = await _runUpload(destination, file, 'u-stalled');

        expect(run.uncaught, isEmpty);
        expect(run.terminals.length, 1);
        final UploadFailed failed = run.terminals.single as UploadFailed;
        expect(failed.error.kind, UploadErrorKind.network);
        expect(failed.error.message, contains('did not respond in time'));
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'cancelling while the response is outstanding still ends the stream',
      () async {
        final UploadFile file = writeRecording(sizeBytes: 32 * 1024);
        final Completer<void> bodyFlushed = Completer<void>();
        final TelegramUploadDestination destination = hostedDestination(
          MockClient.streaming((
            http.BaseRequest request,
            http.ByteStream bodyStream,
          ) async {
            await bodyStream.toBytes();
            bodyFlushed.complete();
            return Completer<http.StreamedResponse>().future;
          }),
        );

        final _UploadRun run = await _runUpload(
          destination,
          file,
          'u-cancel-wait',
          during: () async {
            await bodyFlushed.future;
            await destination.cancel('u-cancel-wait');
          },
        );

        expect(run.uncaught, isEmpty);
        expect(run.terminals.length, 1);
        expect(run.terminals.single, isA<UploadCancelled>());
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test(
      'a cancel that lands after Telegram confirmed reports success',
      () async {
        final UploadFile file = writeRecording(sizeBytes: 32 * 1024);
        final StreamController<List<int>> responseBody =
            StreamController<List<int>>();
        final Completer<void> responseStarted = Completer<void>();
        final TelegramUploadDestination destination = hostedDestination(
          MockClient.streaming((
            http.BaseRequest request,
            http.ByteStream bodyStream,
          ) async {
            await bodyStream.toBytes();
            responseStarted.complete();
            return http.StreamedResponse(
              responseBody.stream,
              200,
              headers: _jsonHeaders,
            );
          }),
        );

        final _UploadRun run = await _runUpload(
          destination,
          file,
          'u-late-cancel',
          during: () async {
            await responseStarted.future;
            // Let the attempt reach the response read before the cancel lands.
            await Future<void>.delayed(Duration.zero);
            await destination.cancel('u-late-cancel');
            responseBody.add(utf8.encode(successBody()));
            await responseBody.close();
          },
        );

        expect(run.uncaught, isEmpty);
        expect(run.terminals.length, 1);
        expect(
          (run.terminals.single as UploadSucceeded).result.remoteFileId,
          _fileId,
        );
        expect(run.events.whereType<UploadCancelled>(), isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 15)),
    );

    test('cancelling the subscription stops the transfer', () async {
      final UploadFile file = writeRecording(sizeBytes: 2 * 1024 * 1024);
      int requests = 0;
      final Completer<void> firstProgress = Completer<void>();
      final TelegramUploadDestination destination = hostedDestination(
        MockClient((http.Request request) async {
          requests++;
          return http.Response(successBody(), 200, headers: _jsonHeaders);
        }),
      );

      final StreamSubscription<UploadEvent> subscription = destination
          .upload(file, const UploadContext(uploadId: 'u-unsubscribe'))
          .listen((UploadEvent event) {
            if (event is UploadProgress && !firstProgress.isCompleted) {
              firstProgress.complete();
            }
          });

      await firstProgress.future;
      await subscription.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(requests, 0);
    });
  });

  group('token safety', () {
    test(
      'the bot token never reaches an event, an error or a toString',
      () async {
        final UploadFile file = writeRecording(sizeBytes: 64 * 1024);
        final TelegramConfig config = TelegramConfig.hosted(
          botToken: _botToken,
          chatId: _chatId,
        );
        final List<UploadEvent> events = <UploadEvent>[];

        final TelegramUploadDestination succeeding = TelegramUploadDestination(
          config: config,
          client: MockClient(
            (http.Request request) async =>
                http.Response(successBody(), 200, headers: _jsonHeaders),
          ),
        );
        events.addAll(
          await succeeding
              .upload(
                file,
                const UploadContext(uploadId: 'u-safe-1', caption: 'clip'),
              )
              .toList(),
        );

        final TelegramUploadDestination failing = TelegramUploadDestination(
          config: config,
          client: MockClient(
            (http.Request request) async => http.Response(
              jsonEncode(<String, Object?>{
                'ok': false,
                'description': 'Unauthorized for ${request.url}',
              }),
              401,
              headers: _jsonHeaders,
            ),
          ),
          retryPolicy: _fastPolicy,
        );
        events.addAll(
          await failing
              .upload(file, const UploadContext(uploadId: 'u-safe-2'))
              .toList(),
        );

        final TelegramUploadDestination serverError = TelegramUploadDestination(
          config: config,
          client: MockClient(
            (http.Request request) async =>
                http.Response('upstream ${request.url} exploded', 503),
          ),
          retryPolicy: _fastPolicy,
        );
        events.addAll(
          await serverError
              .upload(file, const UploadContext(uploadId: 'u-safe-3'))
              .toList(),
        );

        final StringBuffer haystack = StringBuffer()
          ..writeln(config.toString())
          ..writeln(await succeeding.describeAccount())
          ..writeln(succeeding.capabilities.transportSummary)
          ..writeln(succeeding.id)
          ..writeln(succeeding.displayName);
        for (final UploadEvent event in events) {
          haystack.writeln(_describe(event));
        }

        expect(events.whereType<UploadFailed>().length, 2);
        expect(haystack.toString(), isNot(contains(_botToken)));
        expect(haystack.toString(), contains('<redacted>'));
      },
    );
  });
}

class _UploadRun {
  _UploadRun(this.events, this.uncaught);

  final List<UploadEvent> events;
  final List<Object> uncaught;

  List<UploadEvent> get terminals => events
      .where(
        (UploadEvent event) =>
            event is UploadSucceeded ||
            event is UploadFailed ||
            event is UploadCancelled,
      )
      .toList();
}

/// Runs an upload inside a guarded zone, so an exception escaping the
/// destination's detached run future is observable here instead of reaching the
/// default zone handler unseen.
Future<_UploadRun> _runUpload(
  TelegramUploadDestination destination,
  UploadFile file,
  String uploadId, {
  Future<void> Function()? during,
}) async {
  final List<UploadEvent> events = <UploadEvent>[];
  final List<Object> uncaught = <Object>[];
  final Completer<void> done = Completer<void>();

  runZonedGuarded<void>(() {
    destination
        .upload(file, UploadContext(uploadId: uploadId))
        .listen(
          events.add,
          onError: uncaught.add,
          onDone: () {
            if (!done.isCompleted) {
              done.complete();
            }
          },
        );
    if (during != null) {
      unawaited(during());
    }
  }, (Object error, StackTrace stackTrace) => uncaught.add(error));

  await done.future;
  // An error escaping the detached run future lands after the stream closed.
  await Future<void>.delayed(const Duration(milliseconds: 20));
  return _UploadRun(events, uncaught);
}

String _describe(UploadEvent event) {
  final StringBuffer buffer = StringBuffer()
    ..write(event)
    ..write(event.uploadId);
  switch (event) {
    case UploadFailed():
      buffer
        ..write(event.error)
        ..write(event.error.message)
        ..write(event.error.details);
    case UploadRetrying():
      buffer
        ..write(event.cause)
        ..write(event.cause.message)
        ..write(event.cause.details);
    case UploadSucceeded():
      buffer
        ..write(event.result.remoteFileId)
        ..write(event.result.remoteName)
        ..write(event.result.remoteUrl);
    default:
      break;
  }
  return buffer.toString();
}
