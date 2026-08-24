import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/settings/app_settings.dart';
import 'package:relay/core/settings/settings_migrations.dart';

class _RecordingMigration implements SettingsMigration {
  _RecordingMigration(this.fromVersion, [this.applied]);

  @override
  final int fromVersion;

  final List<int>? applied;

  @override
  Map<String, Object?> apply(Map<String, Object?> json) {
    applied?.add(fromVersion);
    return Map<String, Object?>.of(json)..['visited$fromVersion'] = true;
  }
}

void main() {
  group('SettingsMigrator.versionOf', () {
    test('treats an unversioned document as version 0', () {
      expect(SettingsMigrator.versionOf(const <String, Object?>{}), 0);
    });

    test('treats a non-integer version as version 0', () {
      expect(
        SettingsMigrator.versionOf(<String, Object?>{
          AppSettings.keySchemaVersion: '3',
        }),
        0,
      );
    });
  });

  group('v0 to v1', () {
    test('carries recoverable fields over and stamps the version', () {
      final SettingsMigrationResult result = SettingsMigrator.standard()
          .migrate(<String, Object?>{
            AppSettings.keyUploadDestinationId: 'telegram',
            AppSettings.keyFrameRate: 60,
            AppSettings.keyCameraEnabled: true,
            'legacyDebugFlag': 'on',
          });

      expect(result, isA<SettingsMigrated>());
      final SettingsMigrated migrated = result as SettingsMigrated;
      expect(migrated.fromVersion, 0);
      expect(migrated.toVersion, AppSettings.currentSchemaVersion);
      expect(migrated.didMigrate, isTrue);
      expect(
        migrated.document[AppSettings.keySchemaVersion],
        AppSettings.currentSchemaVersion,
      );
      expect(migrated.document.containsKey('legacyDebugFlag'), isFalse);

      final AppSettings settings = AppSettings.fromJson(migrated.document);
      expect(settings.uploadDestinationId, 'telegram');
      expect(settings.frameRate, 60);
      expect(settings.cameraEnabled, isTrue);
      expect(settings.showCursor, isTrue);
    });

    test('an already current document is returned untouched', () {
      final Map<String, Object?> current = const AppSettings(frameRate: 60)
          .toJson();

      final SettingsMigrationResult result = SettingsMigrator.standard()
          .migrate(current);

      expect(result, isA<SettingsMigrated>());
      final SettingsMigrated migrated = result as SettingsMigrated;
      expect(migrated.didMigrate, isFalse);
      expect(migrated.document, current);
    });
  });

  group('v1 to v2', () {
    test('a settings file still naming Google Drive is moved to Telegram', () {
      final SettingsMigrationResult result = SettingsMigrator.standard()
          .migrate(<String, Object?>{
            AppSettings.keySchemaVersion: 1,
            AppSettings.keyUploadDestinationId: 'google_drive',
            AppSettings.keyFrameRate: 60,
          });

      final SettingsMigrated migrated = result as SettingsMigrated;
      // Leaving it would resolve through the registry's fallback instead, and
      // the setting would name a destination that cannot be selected.
      expect(
        AppSettings.fromJson(migrated.document).uploadDestinationId,
        'telegram',
      );
      expect(AppSettings.fromJson(migrated.document).frameRate, 60);
    });

    test('a destination that still exists is left alone', () {
      final SettingsMigrationResult result = SettingsMigrator.standard()
          .migrate(<String, Object?>{
            AppSettings.keySchemaVersion: 1,
            AppSettings.keyUploadDestinationId: 'telegram',
          });

      final SettingsMigrated migrated = result as SettingsMigrated;
      expect(
        AppSettings.fromJson(migrated.document).uploadDestinationId,
        'telegram',
      );
    });

    test('the walk reaches v2 from an unversioned document', () {
      final SettingsMigrationResult result = SettingsMigrator.standard()
          .migrate(<String, Object?>{
            AppSettings.keyUploadDestinationId: 'google_drive',
          });

      final SettingsMigrated migrated = result as SettingsMigrated;
      expect(migrated.fromVersion, 0);
      expect(migrated.toVersion, 2);
      expect(
        AppSettings.fromJson(migrated.document).uploadDestinationId,
        'telegram',
      );
    });
  });

  test('a document from a future version is reported, not destroyed', () {
    final Map<String, Object?> future = <String, Object?>{
      AppSettings.keySchemaVersion: AppSettings.currentSchemaVersion + 4,
      AppSettings.keyUploadDestinationId: 'destination_from_the_future',
      'unknownFutureField': <String, Object?>{'nested': 1},
    };
    final Map<String, Object?> snapshot = Map<String, Object?>.of(future);

    final SettingsMigrationResult result = SettingsMigrator.standard().migrate(
      future,
    );

    expect(result, isA<SettingsDocumentTooNew>());
    final SettingsDocumentTooNew tooNew = result as SettingsDocumentTooNew;
    expect(tooNew.documentVersion, AppSettings.currentSchemaVersion + 4);
    expect(tooNew.supportedVersion, AppSettings.currentSchemaVersion);
    expect(future, snapshot, reason: 'the caller must be able to preserve it');
  });

  test('a missing intermediate migration is a typed failure', () {
    final SettingsMigrator migrator = SettingsMigrator(<SettingsMigration>[
      _RecordingMigration(0),
      _RecordingMigration(2),
    ], targetVersion: 3);

    final SettingsMigrationResult result = migrator.migrate(
      const <String, Object?>{},
    );

    expect(result, isA<SettingsMigrationMissing>());
    final SettingsMigrationMissing missing = result as SettingsMigrationMissing;
    expect(missing.missingFromVersion, 1);
    expect(missing.documentVersion, 0);
    expect(missing.targetVersion, 3);
  });

  test('registered migrations run in ascending order', () {
    final List<int> applied = <int>[];
    final SettingsMigrator migrator = SettingsMigrator(<SettingsMigration>[
      _RecordingMigration(1, applied),
      _RecordingMigration(0, applied),
    ], targetVersion: 2);

    final SettingsMigrationResult result = migrator.migrate(
      const <String, Object?>{},
    );

    final SettingsMigrated migrated = result as SettingsMigrated;
    expect(applied, <int>[0, 1]);
    expect(migrated.document['visited0'], isTrue);
    expect(migrated.document['visited1'], isTrue);
    expect(migrated.document[AppSettings.keySchemaVersion], 2);
  });
}
