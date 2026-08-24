import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../logging/app_logger.dart';
import 'app_settings.dart';
import 'settings_migrations.dart';

/// Persistence boundary for [AppSettings].
abstract interface class SettingsRepository {
  /// Never throws. An unusable document yields defaults and is preserved.
  Future<AppSettings> load();

  Future<void> save(AppSettings settings);

  /// Emits after every successful [save].
  Stream<AppSettings> get changes;
}

/// A versioned JSON document in a caller-supplied file.
///
/// The directory is resolved by the caller (path_provider at startup), which
/// keeps this class free of platform lookups and testable against a temp file.
class FileSettingsRepository implements SettingsRepository {
  FileSettingsRepository(
    this.file, {
    SettingsMigrator? migrator,
    Logger? logger,
  }) : _migrator = migrator ?? SettingsMigrator.standard(),
       // ignore: prefer_initializing_formals -- optional nullable injection.
       _logger = logger;

  static const String tempSuffix = '.tmp';
  static const String corruptSuffix = '.corrupt';
  static const String unsupportedSuffix = '.unsupported';

  final File file;
  final SettingsMigrator _migrator;
  final Logger? _logger;
  final StreamController<AppSettings> _changes =
      StreamController<AppSettings>.broadcast();

  /// Set when the stored document was valid but unusable by this build. The
  /// next write moves it aside instead of clobbering recoverable settings.
  bool _preserveBeforeWrite = false;

  Future<void> _writes = Future<void>.value();

  @override
  Stream<AppSettings> get changes => _changes.stream;

  @override
  Future<AppSettings> load() async {
    _preserveBeforeWrite = false;
    if (!file.existsSync()) {
      return const AppSettings();
    }

    final Map<String, Object?>? document = await _readDocument();
    if (document == null) {
      return const AppSettings();
    }

    final SettingsMigrationResult result = _migrator.migrate(document);
    switch (result) {
      case SettingsMigrated(document: final Map<String, Object?> migrated):
        if (result.didMigrate) {
          _logger?.info(
            'settings.migrated',
            fields: <String, Object?>{
              'from': result.fromVersion,
              'to': result.toVersion,
            },
          );
        }
        return AppSettings.fromJson(migrated);
      case SettingsDocumentTooNew(:final int documentVersion):
        _preserveBeforeWrite = true;
        _logger?.warn(
          'settings.document_too_new',
          fields: <String, Object?>{
            'documentVersion': documentVersion,
            'supportedVersion': result.supportedVersion,
          },
        );
        return const AppSettings();
      case SettingsMigrationMissing(:final int missingFromVersion):
        _preserveBeforeWrite = true;
        _logger?.warn(
          'settings.migration_missing',
          fields: <String, Object?>{
            'documentVersion': result.documentVersion,
            'missingFromVersion': missingFromVersion,
          },
        );
        return const AppSettings();
    }
  }

  @override
  Future<void> save(AppSettings settings) {
    final Future<void> write = _writes.then((void _) => _write(settings));
    _writes = write.then((void _) {}, onError: (Object _, StackTrace _) {});
    return write;
  }

  /// Drains the queued writes, then closes [changes]. Safe to call more than
  /// once. A save in flight at shutdown completes normally instead of failing
  /// on a closed controller.
  Future<void> dispose() async {
    await _writes;
    await _changes.close();
  }

  Future<Map<String, Object?>?> _readDocument() async {
    Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on Object catch (error) {
      await _preserveUnreadable(error);
      return null;
    }
    if (decoded is! Map<String, Object?>) {
      await _preserveUnreadable(null);
      return null;
    }
    return decoded;
  }

  /// [load] never throws, so a document that cannot even be moved aside is
  /// left in place rather than failing the launch.
  Future<void> _preserveUnreadable(Object? error) async {
    try {
      await _preserveAside(corruptSuffix, 'settings.unreadable', error);
    } on Object {
      return;
    }
  }

  Future<void> _write(AppSettings settings) async {
    final Directory parent = file.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
    if (_preserveBeforeWrite) {
      if (file.existsSync()) {
        // Propagates when the document cannot be moved aside: overwriting it
        // here would destroy settings this build cannot read but a newer one
        // can. The flag stays set so a later save retries the preservation.
        await _preserveAside(unsupportedSuffix, 'settings.preserved', null);
      }
      _preserveBeforeWrite = false;
    }

    final File temp = File('${file.path}$tempSuffix');
    try {
      await temp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(settings.toJson()),
        flush: true,
      );
      await temp.rename(file.path);
    } on Object {
      if (temp.existsSync()) {
        await temp.delete();
      }
      rethrow;
    }
    if (!_changes.isClosed) {
      _changes.add(settings);
    }
  }

  /// Moves the stored document out of the way, keeping it recoverable by hand.
  ///
  /// Throws when the move fails, so a caller that would otherwise overwrite
  /// the document can abort instead.
  Future<void> _preserveAside(
    String suffix,
    String event,
    Object? error,
  ) async {
    final String target =
        '${file.path}$suffix-${DateTime.now().millisecondsSinceEpoch}';
    try {
      await file.rename(target);
    } on Object catch (renameError) {
      _logger?.error('settings.preserve_failed', error: renameError);
      rethrow;
    }
    _logger?.warn(
      event,
      fields: <String, Object?>{'preservedAs': target},
      error: error,
    );
  }
}

/// Non-persistent repository for tests and widget tests.
class InMemorySettingsRepository implements SettingsRepository {
  InMemorySettingsRepository([this._settings = const AppSettings()]);

  AppSettings _settings;
  final StreamController<AppSettings> _changes =
      StreamController<AppSettings>.broadcast();

  AppSettings get current => _settings;

  @override
  Stream<AppSettings> get changes => _changes.stream;

  @override
  Future<AppSettings> load() async => _settings;

  @override
  Future<void> save(AppSettings settings) async {
    _settings = settings;
    _changes.add(settings);
  }

  Future<void> dispose() => _changes.close();
}
