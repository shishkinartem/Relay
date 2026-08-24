import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/core/settings/app_settings.dart';
import 'package:relay/core/settings/settings_repository.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('relay_settings_test');
    file = File('${directory.path}/settings.json');
  });

  tearDown(() {
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  });

  List<String> siblingNames() => directory
      .listSync()
      .map((FileSystemEntity entity) => entity.uri.pathSegments.last)
      .toList(growable: false);

  group('FileSettingsRepository', () {
    test('returns defaults when no document exists', () async {
      final FileSettingsRepository repository = FileSettingsRepository(file);
      addTearDown(repository.dispose);

      expect(await repository.load(), const AppSettings());
      expect(file.existsSync(), isFalse);
    });

    test('save writes atomically and leaves no temporary file', () async {
      final FileSettingsRepository repository = FileSettingsRepository(file);
      addTearDown(repository.dispose);

      await repository.save(const AppSettings(frameRate: 60));

      expect(file.existsSync(), isTrue);
      expect(
        File('${file.path}${FileSettingsRepository.tempSuffix}').existsSync(),
        isFalse,
      );
      expect(siblingNames(), <String>['settings.json']);
    });

    test('a failed write leaves the previous document intact', () async {
      final FileSettingsRepository repository = FileSettingsRepository(file);
      addTearDown(repository.dispose);
      await repository.save(const AppSettings(frameRate: 60));
      final String previous = file.readAsStringSync();

      // A directory in the temporary file's place fails the write the way a
      // full disk or a permission error would.
      Directory('${file.path}${FileSettingsRepository.tempSuffix}')
          .createSync();

      await expectLater(
        repository.save(const AppSettings(cameraEnabled: true)),
        throwsA(isA<FileSystemException>()),
      );
      expect(file.readAsStringSync(), previous);
      expect(await repository.load(), const AppSettings(frameRate: 60));
    });

    test('a failed rename removes the temporary file', () async {
      final FileSettingsRepository repository = FileSettingsRepository(file);
      addTearDown(repository.dispose);

      // A directory at the destination path fails the rename after the
      // temporary file has been written.
      Directory(file.path).createSync();

      await expectLater(
        repository.save(const AppSettings(frameRate: 60)),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        siblingNames().where(
          (String name) => name.endsWith(FileSettingsRepository.tempSuffix),
        ),
        isEmpty,
      );
    });

    test('creates the parent directory on first save', () async {
      final File nested = File('${directory.path}/nested/deeper/settings.json');
      final FileSettingsRepository repository = FileSettingsRepository(nested);
      addTearDown(repository.dispose);

      await repository.save(const AppSettings());

      expect(nested.existsSync(), isTrue);
    });

    test('round-trips through a fresh instance', () async {
      const AppSettings settings = AppSettings(
        uploadDestinationId: 'telegram',
        localRecordingsDirectory: '/tmp/relay-recordings',
        quality: RecordingQuality.fullHd1080,
        frameRate: 60,
        microphoneEnabled: false,
        systemAudioEnabled: false,
        cameraEnabled: true,
        showCursor: false,
        preferredSourceType: CaptureSourceType.window,
      );

      final FileSettingsRepository writer = FileSettingsRepository(file);
      addTearDown(writer.dispose);
      await writer.save(settings);

      final FileSettingsRepository reader = FileSettingsRepository(file);
      addTearDown(reader.dispose);

      expect(await reader.load(), settings);
    });

    test('emits every saved value on changes', () async {
      final FileSettingsRepository repository = FileSettingsRepository(file);
      addTearDown(repository.dispose);
      final List<AppSettings> seen = <AppSettings>[];
      final StreamSubscription<AppSettings> subscription = repository.changes
          .listen(seen.add);
      addTearDown(subscription.cancel);

      await repository.save(const AppSettings(frameRate: 60));
      await repository.save(const AppSettings(cameraEnabled: true));
      // The controller delivers asynchronously; drain the queue before
      // asserting rather than racing the last delivery.
      await pumpEventQueue();

      expect(seen, <AppSettings>[
        const AppSettings(frameRate: 60),
        const AppSettings(cameraEnabled: true),
      ]);
    });

    test('concurrent saves serialize and the last one wins', () async {
      final FileSettingsRepository repository = FileSettingsRepository(file);
      addTearDown(repository.dispose);

      await Future.wait<void>(<Future<void>>[
        repository.save(const AppSettings(frameRate: 60)),
        repository.save(const AppSettings(frameRate: 30, cameraEnabled: true)),
      ]);

      expect(
        File('${file.path}${FileSettingsRepository.tempSuffix}').existsSync(),
        isFalse,
      );
      expect(
        await repository.load(),
        const AppSettings(frameRate: 30, cameraEnabled: true),
      );
    });

    test(
      'a corrupt document is preserved aside and defaults are returned',
      () async {
        file.writeAsStringSync('{ this is not json');
        final FileSettingsRepository repository = FileSettingsRepository(file);
        addTearDown(repository.dispose);

        expect(await repository.load(), const AppSettings());
        expect(file.existsSync(), isFalse);

        final List<String> preserved = siblingNames()
            .where(
              (String name) => name.startsWith(
                'settings.json${FileSettingsRepository.corruptSuffix}',
              ),
            )
            .toList(growable: false);
        expect(preserved, hasLength(1));
        expect(
          File('${directory.path}/${preserved.single}').readAsStringSync(),
          '{ this is not json',
        );
      },
    );

    test('a json document that is not an object is preserved aside', () async {
      file.writeAsStringSync('[1, 2, 3]');
      final FileSettingsRepository repository = FileSettingsRepository(file);
      addTearDown(repository.dispose);

      expect(await repository.load(), const AppSettings());
      expect(
        siblingNames().single.startsWith(
          'settings.json${FileSettingsRepository.corruptSuffix}',
        ),
        isTrue,
      );
    });

    test('a future document survives a read-only launch', () async {
      final String document = jsonEncode(<String, Object?>{
        AppSettings.keySchemaVersion: AppSettings.currentSchemaVersion + 1,
        AppSettings.keyFrameRate: 120,
      });
      file.writeAsStringSync(document);
      final FileSettingsRepository repository = FileSettingsRepository(file);
      addTearDown(repository.dispose);

      expect(await repository.load(), const AppSettings());
      expect(file.readAsStringSync(), document);
    });

    test(
      'a future document is preserved rather than overwritten by a save',
      () async {
        final String document = jsonEncode(<String, Object?>{
          AppSettings.keySchemaVersion: AppSettings.currentSchemaVersion + 1,
          AppSettings.keyFrameRate: 120,
        });
        file.writeAsStringSync(document);
        final FileSettingsRepository repository = FileSettingsRepository(file);
        addTearDown(repository.dispose);

        await repository.load();
        await repository.save(const AppSettings(cameraEnabled: true));

        expect(await repository.load(), const AppSettings(cameraEnabled: true));
        final String preserved = siblingNames().firstWhere(
          (String name) => name.startsWith(
            'settings.json${FileSettingsRepository.unsupportedSuffix}',
          ),
        );
        expect(
          File('${directory.path}/$preserved').readAsStringSync(),
          document,
        );
      },
    );

    test(
      'the preserve marker does not outlive the save it belongs to',
      () async {
        final String document = jsonEncode(<String, Object?>{
          AppSettings.keySchemaVersion: AppSettings.currentSchemaVersion + 1,
          AppSettings.keyFrameRate: 120,
        });
        file.writeAsStringSync(document);
        final FileSettingsRepository repository = FileSettingsRepository(file);
        addTearDown(repository.dispose);

        await repository.load();
        // The future document disappears before the first write has anything to
        // preserve; the second write must not treat this build's own document
        // as the unsupported one.
        file.deleteSync();

        await repository.save(const AppSettings(frameRate: 60));
        await repository.save(const AppSettings(cameraEnabled: true));

        expect(siblingNames(), <String>['settings.json']);
        expect(await repository.load(), const AppSettings(cameraEnabled: true));
      },
    );

    test(
      'a save aborts when the future document cannot be preserved',
      () async {
        final String document = jsonEncode(<String, Object?>{
          AppSettings.keySchemaVersion: AppSettings.currentSchemaVersion + 1,
          AppSettings.keyFrameRate: 120,
        });
        file.writeAsStringSync(document);
        final FileSettingsRepository repository = FileSettingsRepository(
          _UnrenamableFile(file),
        );
        addTearDown(repository.dispose);

        await repository.load();

        await expectLater(
          repository.save(const AppSettings(cameraEnabled: true)),
          throwsA(isA<FileSystemException>()),
        );
        expect(file.readAsStringSync(), document);
        expect(
          File('${file.path}${FileSettingsRepository.tempSuffix}').existsSync(),
          isFalse,
        );
      },
    );

    test('dispose lets an in-flight save finish', () async {
      final FileSettingsRepository repository = FileSettingsRepository(file);
      final Future<void> save = repository.save(
        const AppSettings(frameRate: 60),
      );

      await repository.dispose();

      await expectLater(save, completes);

      final FileSettingsRepository reader = FileSettingsRepository(file);
      addTearDown(reader.dispose);
      expect(await reader.load(), const AppSettings(frameRate: 60));
    });

    test(
      'a save queued after dispose still writes and does not throw',
      () async {
        final FileSettingsRepository repository = FileSettingsRepository(file);
        await repository.dispose();

        await expectLater(
          repository.save(const AppSettings(cameraEnabled: true)),
          completes,
        );

        final FileSettingsRepository reader = FileSettingsRepository(file);
        addTearDown(reader.dispose);
        expect(await reader.load(), const AppSettings(cameraEnabled: true));
      },
    );
  });

  group('InMemorySettingsRepository', () {
    test('round-trips and emits on save', () async {
      final InMemorySettingsRepository repository =
          InMemorySettingsRepository();
      addTearDown(repository.dispose);
      final List<AppSettings> seen = <AppSettings>[];
      final StreamSubscription<AppSettings> subscription = repository.changes
          .listen(seen.add);
      addTearDown(subscription.cancel);

      expect(await repository.load(), const AppSettings());

      await repository.save(const AppSettings(cameraEnabled: true));

      expect(await repository.load(), const AppSettings(cameraEnabled: true));
      expect(repository.current, const AppSettings(cameraEnabled: true));
      expect(seen, <AppSettings>[const AppSettings(cameraEnabled: true)]);
    });
  });
}

/// A real file that refuses to be renamed, which is how a preserve step fails
/// while the temporary write around it still succeeds.
class _UnrenamableFile implements File {
  _UnrenamableFile(this._delegate);

  final File _delegate;

  @override
  String get path => _delegate.path;

  @override
  Directory get parent => _delegate.parent;

  @override
  bool existsSync() => _delegate.existsSync();

  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      _delegate.readAsString(encoding: encoding);

  @override
  Future<File> rename(String newPath) =>
      throw const FileSystemException('rename refused');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
