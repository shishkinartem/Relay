import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:relay/core/environment/app_environment.dart';
import 'package:relay/core/platform/app_directories.dart';

/// A `.env` used to be read as the bare relative path `.env`, which resolves
/// against the *process working directory*. Under `flutter run` that is the
/// repository root and the file is found; for a bundle the Finder launched it
/// is `/`, and the file is silently ignored — in the only situation a
/// pre-seeded build exists for. These tests pin the search order that replaced
/// it, and the "first one that exists wins" rule that goes with it.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('relay_env_');
  });

  tearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  File write(String name, String contents) {
    final File file = File('${root.path}${Platform.pathSeparator}$name')
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);
    return file;
  }

  group('candidate list', () {
    test('looks beside the executable and in application support, not only in '
        'the working directory', () {
      final List<File> candidates = AppDirectories.environmentCandidates(root);
      final List<String> paths = candidates
          .map((File f) => f.path)
          .toList(growable: false);

      expect(paths, isNotEmpty);
      expect(
        paths.first,
        startsWith(Directory.current.path),
        reason: 'the working directory stays first, for flutter run',
      );
      expect(
        paths.any(
          (String p) =>
              p.startsWith(File(Platform.resolvedExecutable).parent.path),
        ),
        isTrue,
        reason: 'an installed build has no useful working directory',
      );
      expect(
        paths.any((String p) => p.startsWith(root.path)),
        isTrue,
        reason: 'a deployment must be able to drop one beside settings.json',
      );
      expect(
        paths.every((String p) => p.endsWith('.env')),
        isTrue,
        reason: 'every candidate names the document itself',
      );
    });

    test('an explicit RELAY_ENV_FILE would outrank all of them', () {
      // The variable is read from the real process environment, which a test
      // cannot set. What is asserted here is the contract the code documents:
      // the override is consulted, and it is consulted first.
      expect(AppDirectories.environmentFileVariable, 'RELAY_ENV_FILE');
      final List<File> candidates = AppDirectories.environmentCandidates(root);
      final String? named =
          Platform.environment[AppDirectories.environmentFileVariable];
      if (named != null && named.isNotEmpty) {
        expect(candidates.first.path, named);
      }
    });
  });

  group('reading', () {
    test('takes the first candidate that exists and says which it was', () {
      final File second = write('second.env', 'TELEGRAM_CHAT_ID=222\n');
      final File third = write('third.env', 'TELEGRAM_CHAT_ID=333\n');

      final AppEnvironment env = AppEnvironment.fromFiles(<File>[
        File('${root.path}${Platform.pathSeparator}missing.env'),
        second,
        third,
      ]);

      expect(env.telegramChatId, '222');
      expect(
        env.sourcePath,
        second.path,
        reason: 'a build must be able to report where its seed came from',
      );
    });

    test('no candidate at all is the normal case, not a failure', () {
      final AppEnvironment env = AppEnvironment.fromFiles(<File>[
        File('${root.path}${Platform.pathSeparator}nope.env'),
      ]);

      expect(env.sourcePath, isNull);
      expect(env.keys, isEmpty);
      expect(env.hasTelegramCredentials, isFalse);
    });
  });
}
