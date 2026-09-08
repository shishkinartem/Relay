import 'app_settings.dart';

/// One deterministic step of the persisted-settings schema.
///
/// A migration transforms the raw document; it must not depend on the current
/// [AppSettings] shape, so an old step keeps working after the model moves on.
abstract interface class SettingsMigration {
  /// Version this step upgrades *from*. It always produces `fromVersion + 1`.
  int get fromVersion;

  Map<String, Object?> apply(Map<String, Object?> json);
}

/// Outcome of running [SettingsMigrator.migrate].
sealed class SettingsMigrationResult {
  const SettingsMigrationResult();
}

/// The document is usable at [SettingsMigrator.targetVersion].
///
/// [fromVersion] equals [toVersion] when nothing had to run.
final class SettingsMigrated extends SettingsMigrationResult {
  const SettingsMigrated({
    required this.document,
    required this.fromVersion,
    required this.toVersion,
  });

  final Map<String, Object?> document;
  final int fromVersion;
  final int toVersion;

  bool get didMigrate => fromVersion != toVersion;
}

/// The document was written by a newer build.
///
/// Downgrading must not rewrite it: the caller falls back to defaults and
/// preserves the file so the newer build still finds its settings.
final class SettingsDocumentTooNew extends SettingsMigrationResult {
  const SettingsDocumentTooNew({
    required this.documentVersion,
    required this.supportedVersion,
  });

  final int documentVersion;
  final int supportedVersion;
}

/// No migration is registered for [missingFromVersion], so the walk cannot
/// reach the target. A typed failure — never a silent skip.
final class SettingsMigrationMissing extends SettingsMigrationResult {
  const SettingsMigrationMissing({
    required this.documentVersion,
    required this.missingFromVersion,
    required this.targetVersion,
  });

  final int documentVersion;
  final int missingFromVersion;
  final int targetVersion;
}

/// Walks a stored settings document up to [targetVersion].
class SettingsMigrator {
  SettingsMigrator(
    List<SettingsMigration> migrations, {
    this.targetVersion = AppSettings.currentSchemaVersion,
  }) : _migrations = <int, SettingsMigration>{
         for (final SettingsMigration migration in migrations)
           migration.fromVersion: migration,
       };

  /// The migrations this build ships.
  SettingsMigrator.standard()
    : this(const <SettingsMigration>[
        _V0ToV1(),
        _V1ToV2(),
        _V2ToV3(),
        _V3ToV4(),
        _V4ToV5(),
      ]);

  final int targetVersion;
  final Map<int, SettingsMigration> _migrations;

  /// Version of a stored document. Pre-versioning documents are version 0.
  static int versionOf(Map<String, Object?> json) {
    final Object? value = json[AppSettings.keySchemaVersion];
    return value is int && value >= 0 ? value : 0;
  }

  SettingsMigrationResult migrate(Map<String, Object?> json) {
    final int startVersion = versionOf(json);
    if (startVersion > targetVersion) {
      return SettingsDocumentTooNew(
        documentVersion: startVersion,
        supportedVersion: targetVersion,
      );
    }

    Map<String, Object?> document = json;
    for (int version = startVersion; version < targetVersion; version++) {
      final SettingsMigration? migration = _migrations[version];
      if (migration == null) {
        return SettingsMigrationMissing(
          documentVersion: startVersion,
          missingFromVersion: version,
          targetVersion: targetVersion,
        );
      }
      document = migration.apply(document);
      document[AppSettings.keySchemaVersion] = version + 1;
    }

    return SettingsMigrated(
      document: document,
      fromVersion: startVersion,
      toVersion: targetVersion,
    );
  }
}

/// Pre-versioning documents used today's key names, so recovery is a filtered
/// copy: known keys survive, anything else is dropped rather than carried into
/// the versioned schema.
class _V0ToV1 implements SettingsMigration {
  const _V0ToV1();

  /// Frozen at version 1. Never re-point this at the current model: a later
  /// schema that renames or drops a key still needs the v0 value to arrive
  /// here so the next step can transform it.
  static const List<String> _recoverableKeys = <String>[
    'uploadDestinationId',
    'localRecordingsDirectory',
    'quality',
    'frameRate',
    'microphoneEnabled',
    'systemAudioEnabled',
    'cameraEnabled',
    'showCursor',
    'preferredSourceType',
  ];

  @override
  int get fromVersion => 0;

  @override
  Map<String, Object?> apply(Map<String, Object?> json) {
    final Map<String, Object?> migrated = <String, Object?>{};
    for (final String key in _recoverableKeys) {
      if (json.containsKey(key)) {
        migrated[key] = json[key];
      }
    }
    return migrated;
  }
}

/// Google Drive was removed as a destination.
///
/// A document that still names it would resolve to whatever destination
/// happens to be registered first, so the stored value is rewritten rather than
/// left to a fallback: the setting says what the next Send will actually do
/// (`docs/adr/2026-08-23-telegram-only-destination.md`).
class _V1ToV2 implements SettingsMigration {
  const _V1ToV2();

  /// Frozen at version 2, like every other step: these are the names as they
  /// were, not as the model spells them today.
  static const String _removedDestinationId = 'google_drive';
  static const String _replacementDestinationId = 'telegram';

  @override
  int get fromVersion => 1;

  @override
  Map<String, Object?> apply(Map<String, Object?> json) {
    final Map<String, Object?> migrated = Map<String, Object?>.of(json);
    if (migrated[AppSettings.keyUploadDestinationId] == _removedDestinationId) {
      migrated[AppSettings.keyUploadDestinationId] = _replacementDestinationId;
    }
    return migrated;
  }
}

/// Input-device choices and the launch screen's disclosure state arrived
/// (§33.2).
///
/// Nothing stored has to change: both keys are new, and both readers default
/// them to "no choice made" and "closed", which is the behaviour every existing
/// document already had. The step exists anyway because the migrator walks
/// version by version and a gap in the walk is a typed failure, not a skip —
/// a v2 document with no v2→v3 step would be reported as unmigratable and the
/// user would silently get defaults for everything, not just the new keys.
class _V2ToV3 implements SettingsMigration {
  const _V2ToV3();

  @override
  int get fromVersion => 2;

  @override
  Map<String, Object?> apply(Map<String, Object?> json) =>
      Map<String, Object?>.of(json);
}

/// The native-resolution preset arrived and became the default for a fresh
/// install (§10).
///
/// **Nothing stored changes, deliberately.** `quality` is written on every save
/// (`AppSettings.toJson`), so a document holding `hd720` is indistinguishable
/// from one that never had the setting touched — there is no way to tell a
/// deliberate 720p from yesterday's default. Promoting it would multiply that
/// user's files several-fold without being asked, and §16's 50 MB Telegram
/// ceiling makes that a consequence rather than a detail. A user who wants
/// native picks it; the launch screen is one tap away.
///
/// The step exists anyway because the migrator walks version by version and a
/// gap in the walk is a typed failure, not a skip: a v3 document with no v3→v4
/// step would be reported as unmigratable and the user would silently lose
/// *every* setting, not just this one. [_V2ToV3] is the same no-op for the same
/// reason.
class _V3ToV4 implements SettingsMigration {
  const _V3ToV4();

  @override
  int get fromVersion => 3;

  @override
  Map<String, Object?> apply(Map<String, Object?> json) =>
      Map<String, Object?>.of(json);
}

/// "Keep a copy on this computer" arrived
/// (`docs/adr/2026-09-08-keeping-the-local-copy-after-sending.md`).
///
/// Nothing stored has to change: the key is new and its reader defaults it to
/// `false`, which is what every existing document already meant — a send was a
/// move. The step exists for the reason [_V2ToV3] and [_V3ToV4] do: the
/// migrator walks version by version and a gap is a typed failure, so a v4
/// document with no v4→v5 step would be reported unmigratable and the user
/// would silently get defaults for *everything*, not just the new key.
class _V4ToV5 implements SettingsMigration {
  const _V4ToV5();

  @override
  int get fromVersion => 4;

  @override
  Map<String, Object?> apply(Map<String, Object?> json) =>
      Map<String, Object?>.of(json);
}
