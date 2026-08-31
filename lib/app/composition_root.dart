import 'dart:io';

import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:upload_core/upload_core.dart';
import 'package:upload_telegram/upload_telegram.dart';
import 'package:upload_webdav/upload_webdav.dart';

import '../core/environment/app_environment.dart';
import '../core/logging/app_logger.dart';
import '../core/logging/file_log_sink.dart';
import '../core/platform/app_directories.dart';
import '../core/settings/settings_repository.dart';
import '../features/recorder/application/overlay_presenter.dart';
import '../features/recorder/application/recorder_view_model.dart';
import '../features/recorder/domain/local_recording_store.dart';
import '../features/settings/application/settings_controller.dart';
import '../upload/application/upload_coordinator.dart';
import '../upload/application/upload_destination_registry.dart';
import '../upload/infrastructure/secure_credential_store.dart';

/// Builds the object graph.
///
/// The only place that knows which platform implementation is registered,
/// which destinations ship, and where files live. Everything below reads its
/// collaborators through interfaces.
class CompositionRoot {
  CompositionRoot._({
    required this.logger,
    required this.logFile,
    required this.environment,
    required this.settings,
    required this.destinations,
    required this.recorder,
    required this.uploads,
    required FileLogSink? fileSink,
    // ignore: prefer_initializing_formals -- private field, named parameter.
  }) : _fileSink = fileSink;

  final FileLogSink? _fileSink;

  final Logger logger;

  /// Where the diagnostics this build writes can be found on disk.
  ///
  /// Exposed so the application can tell a user which file to send. There is
  /// no designed screen for that yet — see the design gap noted in
  /// `docs/development/design-system.md`.
  final File logFile;

  final AppEnvironment environment;
  final SettingsGateway settings;
  final DestinationRegistry destinations;
  final RecorderViewModel recorder;
  final Uploads uploads;

  static Future<CompositionRoot> create() async {
    // Directories first, because the file sink needs a path and a shipped
    // build with no file sink emits nothing at all: ConsoleLogSink is gated
    // behind kDebugMode. Nothing needs a logger before this line.
    final AppDirectories directories = await AppDirectories.resolve();

    // In-memory retention is the logger's own bounded ring buffer, read by
    // exportRedactedDiagnostics; a collecting sink here would duplicate it
    // with no way to read or clear what it keeps. The file sink is the
    // separate thing the ring buffer cannot be — it survives the process, so a
    // crash still leaves something to read.
    final FileLogSink? fileSink = await FileLogSink.open(directories.logFile);
    final AppLogger logger = AppLogger(
      sinks: <LogSink>[const ConsoleLogSink(), ?fileSink],
    );
    if (fileSink == null) {
      logger.warn(
        'log_file_unavailable',
        fields: <String, Object?>{'path': directories.logFile.path},
      );
    }
    final AppEnvironment environment = AppEnvironment.fromFiles(
      directories.environmentFiles,
    );
    // The path and the key names, never a value (§26). Without this line a
    // `.env` that was looked for in the wrong place and one that was found and
    // empty are indistinguishable from the outside.
    logger.info(
      'environment_loaded',
      fields: <String, Object?>{
        'source': environment.sourcePath ?? 'none',
        'keys': environment.keys.join(','),
      },
    );

    final SettingsGateway settingsController = SettingsController(
      repository: FileSettingsRepository(
        directories.settingsFile,
        logger: logger,
      ),
      logger: logger,
    );
    await settingsController.load();

    final String recordingsPath =
        settingsController.settings.localRecordingsDirectory ??
        directories.defaultRecordings.path;

    final CredentialStore credentials = SecureCredentialStore(logger: logger);

    final UploadDestinationRegistry destinations = UploadDestinationRegistry(
      <UploadDestination>[
        TelegramUploadDestination(
          // `.env` seeds a deployment's own bot; anything connected in Settings
          // is stored in the OS keychain and takes precedence (§16, §27).
          config: TelegramConfig(
            botToken: environment.telegramBotToken ?? '',
            chatId: environment.telegramChatId ?? '',
            baseUrl: environment.telegramBotApiBaseUrl == null
                ? TelegramConfig.hostedBaseUrl
                : Uri.parse(environment.telegramBotApiBaseUrl!),
          ),
          credentialStore: credentials,
        ),
        // WebDAV is where a recording goes when it is too big for a chat: no
        // size limit of its own, and no developer registration to reach it —
        // an app password from the provider's own settings is the whole setup
        // (§17, `docs/adr/2026-08-23-webdav-second-destination.md`).
        WebDavUploadDestination(credentialStore: credentials),
      ],
    );

    final Uploads uploads = UploadCoordinator(
      registry: destinations,
      logger: logger,
    );

    final RecorderPlatform platform = RecorderPlatform.instance;
    logger.info(
      'platform_registered',
      fields: <String, Object?>{'platform': platform.runtimeType.toString()},
    );

    final RecorderViewModel recorder = RecorderViewModel(
      recorder: platform.recorder,
      permissions: platform.permissions,
      overlays: OverlayPresenter(overlays: platform.overlays),
      store: LocalRecordingStore(
        directory: Directory(recordingsPath),
        logger: logger,
      ),
      settings: settingsController,
      uploads: uploads,
      destinations: destinations,
      logger: logger,
    );
    // Deliberately not awaited here. Talking to the platform means talking to
    // ScreenCaptureKit, which blocks while macOS shows its permission prompt —
    // awaiting it before the first frame is what turns a missing permission
    // into a black window.

    return CompositionRoot._(
      logger: logger,
      logFile: directories.logFile,
      fileSink: fileSink,
      environment: environment,
      settings: settingsController,
      destinations: destinations,
      recorder: recorder,
      uploads: uploads,
    );
  }

  /// Releases the graph in the reverse of the order it was built.
  ///
  /// The recorder goes first and on its own await: it is the only member
  /// holding operating-system capture, and a quit during a recording must
  /// release the camera and the microphone before anything else is torn down.
  /// Everything after it releases sockets and timers, so those run together
  /// and a failure in one does not strand the rest.
  ///
  /// Idempotent, and it never throws: this runs while the application is going
  /// away, and there is nowhere left to report to.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;

    // Both halves: `dispose()` starts the teardown and `shutdown` is when the
    // platform has finished it. Only the first was awaited before, so a quit
    // during a recording could return `AppExitResponse.exit` while the native
    // abort was still closing the camera and finalizing the `.part` (§19.1).
    await _quietly('recorder', () async {
      recorder.dispose();
      await recorder.shutdown;
    });
    await Future.wait<void>(<Future<void>>[
      _quietly('uploads', uploads.dispose),
      for (final UploadDestination destination in destinations.all)
        _quietly(
          'destination_${destination.id}',
          () async => destination.dispose(),
        ),
    ]);
    // Last, so everything above still had somewhere to report to.
    final FileLogSink? fileSink = _fileSink;
    if (fileSink != null) {
      await fileSink.close();
    }
  }

  bool _disposed = false;

  Future<void> _quietly(String what, Future<void> Function() step) async {
    try {
      await step();
    } on Object catch (e) {
      logger.warn(
        'dispose_failed',
        fields: <String, Object?>{
          'component': what,
          'error': e.runtimeType.toString(),
        },
      );
    }
  }
}
