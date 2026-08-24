import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The layering rules, enforced rather than described.
///
/// A convention that lives only in a document is a convention until the first
/// person in a hurry. These are the rules `CLAUDE.md` states, checked against
/// the source on every run, so breaking one is a failing test rather than a
/// code review someone might not do.
///
/// Adding a rule here is cheap. Weakening one should not be: every exception
/// below is named, and a new name has to be argued for in the diff that adds
/// it.
void main() {
  final Directory root = _repositoryRoot();

  /// Every Dart file the application and its packages are built from.
  List<File> sources(String relative) {
    final Directory directory = Directory('${root.path}/$relative');
    if (!directory.existsSync()) {
      return const <File>[];
    }
    return directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .toList(growable: false);
  }

  String relative(File file) =>
      file.path.substring(root.path.length + 1).replaceAll(r'\', '/');

  /// The file with its comments removed.
  ///
  /// Rules are about what the code does, and this project explains itself at
  /// length: the first version of the operating-system rule failed on a
  /// comment that said an OS check must not appear.
  String code(File file) => file
      .readAsStringSync()
      .split('\n')
      .where((String line) => !line.trimLeft().startsWith('//'))
      .join('\n');

  final List<File> lib = sources('lib');

  group('platform knowledge stays in the composition root', () {
    test('no operating-system checks anywhere in lib/', () {
      final List<String> offenders = <String>[
        for (final File file in lib)
          if (RegExp(r'Platform\.(isMacOS|isWindows|isLinux|operatingSystem)')
              .hasMatch(code(file)))
            relative(file),
      ];
      expect(
        offenders,
        isEmpty,
        reason:
            'capability-driven APIs, never an OS name. A platform difference '
            'belongs behind the recorder contract or in core/platform.',
      );
    });

    test('no plugin package is imported outside the composition root', () {
      // These exist so that everything above them can be written once. An
      // import anywhere else is a feature that has learnt which platform, or
      // which destination, it is running against.
      const Set<String> plugins = <String>{
        'recorder_macos',
        'recorder_windows',
        'upload_telegram',
        'upload_webdav',
      };
      const String compositionRoot = 'lib/app/composition_root.dart';

      final List<String> offenders = <String>[
        for (final File file in lib)
          if (relative(file) != compositionRoot)
            for (final String plugin in plugins)
              if (code(file).contains('package:$plugin/'))
                '${relative(file)} imports $plugin',
      ];
      expect(offenders, isEmpty);
    });

    test('the filesystem is reached from named places only', () {
      // dart:io in a feature is a feature that can no longer be tested without
      // a disk, and a Linux port that has to be found by grep.
      const Set<String> allowed = <String>{
        'lib/core/platform/app_directories.dart',
        // The sink that makes a shipped build diagnosable. It has to reach a
        // real file: an in-memory diagnostics buffer is exactly the thing that
        // does not survive the crash you wanted it for. Kept to one file with
        // no logic beyond bounded appending and rotation.
        'lib/core/logging/file_log_sink.dart',
        'lib/core/environment/app_environment.dart',
        'lib/features/recorder/domain/local_recording_store.dart',
        'lib/core/settings/settings_repository.dart',
        'lib/app/composition_root.dart',
      };
      final List<String> offenders = <String>[
        for (final File file in lib)
          if (!allowed.contains(relative(file)) &&
              RegExp(r'''import 'dart:io';''').hasMatch(code(file)))
            relative(file),
      ];
      expect(offenders, isEmpty);
    });
  });

  group('layers only point downwards', () {
    test('the design system knows nothing about features', () {
      final List<String> offenders = <String>[
        for (final File file in sources('lib/design_system'))
          if (code(file).contains('features/')) relative(file),
      ];
      expect(
        offenders,
        isEmpty,
        reason:
            'a shared component that imports a feature is not shared, and the '
            'next feature cannot use it',
      );
    });

    test('domain code carries no Flutter widgets', () {
      final List<String> offenders = <String>[
        for (final File file in lib)
          if (relative(file).contains('/domain/') &&
              RegExp(
                r'''import 'package:flutter/(material|cupertino|widgets)\.dart';''',
              ).hasMatch(code(file)))
            relative(file),
      ];
      expect(offenders, isEmpty);
    });
  });

  group('collaborators are interfaces', () {
    /// Types that are values, not collaborators: nothing is *called* on them
    /// that a substitute would want to change. They are held by the
    /// application layer as data.
    ///
    /// A name is added here only when it is genuinely a value. Anything that
    /// performs work — talks to the platform, the disk, the network, the
    /// clock — belongs behind an interface instead.
    const Set<String> values = <String>{
      // The §19 transition function. `const`-constructible, pure, no state and
      // no collaborators of its own: substituting it would mean substituting
      // the specification.
      'SessionMachine',
      // Immutable snapshots and settings documents.
      'AppSettings',
      'SessionState',
      'RecordingOverlayState',
      'PermissionReport',
      'RecorderCapabilities',
      'DisplayGeometry',
      'CaptureSource',
      'RecordingFile',
      'AppEnvironment',
      'LogRedactor',
      'Size',
    };

    /// name -> is it abstract, for every class this project declares.
    final Map<String, bool> declarations = <String, bool>{};
    for (final File file in <File>[
      ...lib,
      for (final Directory package in Directory(
        '${root.path}/packages',
      ).listSync().whereType<Directory>())
        ...sources('packages/${package.path.split('/').last}/lib'),
    ]) {
      for (final RegExpMatch match in RegExp(
        r'^(abstract\s+(?:interface\s+|base\s+|final\s+)?)?(?:mixin\s+)?class\s+(\w+)',
        multiLine: true,
      ).allMatches(code(file))) {
        final String name = match.group(2)!;
        final bool isAbstract = match.group(1) != null;
        declarations[name] = (declarations[name] ?? false) || isAbstract;
      }
    }

    test('the project declares the classes this rule reasons about', () {
      // A guard on the guard: if the declaration scan ever stops matching, the
      // rule below would pass by finding nothing.
      expect(declarations, contains('RecorderViewModel'));
      expect(declarations['RecorderViewModel'], isFalse);
      expect(declarations['Recorder'], isTrue, reason: 'declared abstract');
      expect(declarations['SessionOverlays'], isTrue);
      expect(declarations['RecordingStore'], isTrue);
      expect(declarations['Uploads'], isTrue);
      expect(declarations['DestinationRegistry'], isTrue);
      expect(declarations['SettingsGateway'], isTrue);
      expect(declarations['Logger'], isTrue);
    });

    test('every collaborator the application layer holds is substitutable', () {
      final List<String> offenders = <String>[];
      for (final File file in lib) {
        final String path = relative(file);
        if (!path.contains('/application/')) {
          continue;
        }
        for (final RegExpMatch field in RegExp(
          r'^\s+final\s+([A-Z]\w*)\??\s+_?\w+\s*;',
          multiLine: true,
        ).allMatches(code(file))) {
          final String type = field.group(1)!;
          if (values.contains(type) || !declarations.containsKey(type)) {
            continue;
          }
          if (declarations[type] != true) {
            offenders.add('$path holds a concrete $type');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'an application-layer class must be able to run against a '
            'substitute. Give the collaborator an interface, or — if it is '
            'genuinely a value — name it in the allowlist above and say why.',
      );
    });
  });

  group('the import graph stays acyclic', () {
    /// `docs/development/code-quality.md` asks for acyclic dependencies, and
    /// nothing was checking. Dart compiles an import cycle without complaint
    /// and `flutter analyze` does not report one, so a cycle is only ever
    /// discovered by the person who cannot work out where to start reading.
    ///
    /// `prefer_relative_imports` is on, so every edge inside `lib/` is a
    /// relative URI and the graph can be resolved from the paths alone.
    test('no file in lib/ can reach itself through imports', () {
      final Map<String, List<String>> imports = <String, List<String>>{};
      for (final File file in lib) {
        final String from = relative(file);
        final Uri base = Uri.file(from);
        imports[from] = <String>[
          for (final RegExpMatch match in RegExp(
            "^\\s*import\\s+'([^':]+\\.dart)'",
            multiLine: true,
          ).allMatches(code(file)))
            base.resolve(match.group(1)!).path,
        ];
      }

      // Iterative depth-first search, colouring each node white/grey/black. A
      // grey node reached a second time is a back edge, which is a cycle; the
      // stack at that moment is the cycle, and naming it is the whole value of
      // the failure message.
      final Map<String, int> colour = <String, int>{};
      final List<String> path = <String>[];
      final List<String> cycles = <String>[];

      void visit(String node) {
        if (colour[node] == 2) {
          return;
        }
        if (colour[node] == 1) {
          final int start = path.indexOf(node);
          cycles.add('${path.sublist(start).join(' → ')} → $node');
          return;
        }
        colour[node] = 1;
        path.add(node);
        for (final String next in imports[node] ?? const <String>[]) {
          visit(next);
        }
        path.removeLast();
        colour[node] = 2;
      }

      for (final String node in imports.keys) {
        visit(node);
      }

      expect(
        cycles,
        isEmpty,
        reason:
            'an import cycle has no place to start reading and no place to '
            'cut a seam. Move the shared thing down a layer, or invert the '
            'dependency behind an interface.',
      );
    });

    test('the graph this rule reasons about is not empty', () {
      // A guard on the guard: a regex that stops matching would make the rule
      // above pass by finding no edges at all.
      final int edges = lib
          .map(
            (File f) => RegExp(
              "^\\s*import\\s+'([^':]+\\.dart)'",
              multiLine: true,
            ).allMatches(code(f)).length,
          )
          .fold<int>(0, (int a, int b) => a + b);
      expect(edges, greaterThan(100));
    });
  });
}

/// The repository root, found from the test's own working directory so the
/// suite runs the same way from an IDE and from `flutter test`.
Directory _repositoryRoot() {
  Directory directory = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${directory.path}/pubspec.yaml').existsSync() &&
        Directory('${directory.path}/lib').existsSync()) {
      return directory;
    }
    directory = directory.parent;
  }
  throw StateError(
    'The repository root could not be found from ${Directory.current}',
  );
}
