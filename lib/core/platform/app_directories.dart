import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Resolves the per-platform directories the application writes to.
///
/// This is composition-root code: platform selection belongs in wiring, not in
/// features (`docs/architecture/platform-abstraction.md` → *Platform checks*).
class AppDirectories {
  const AppDirectories({
    required this.settingsFile,
    required this.logFile,
    required this.defaultRecordings,
    required this.environmentFiles,
  });

  final File settingsFile;

  /// Where the shipped build writes its diagnostics (§26).
  ///
  /// Beside `settings.json` rather than in the recordings folder: it is
  /// application state, not something the user put there, and the recordings
  /// directory is one they can move.
  final File logFile;

  final Directory defaultRecordings;

  /// Where a `.env` may be, most specific first (§27).
  final List<File> environmentFiles;

  /// Names a `.env` outright, for a deployment that keeps it somewhere else.
  static const String environmentFileVariable = 'RELAY_ENV_FILE';

  static const String _folderName = 'Relay';

  static Future<AppDirectories> resolve() async {
    final Directory support = await getApplicationSupportDirectory();
    return AppDirectories(
      settingsFile: File(
        '${support.path}${Platform.pathSeparator}settings.json',
      ),
      logFile: File('${support.path}${Platform.pathSeparator}relay.log'),
      defaultRecordings: await _resolveRecordingsDirectory(),
      environmentFiles: environmentCandidates(support),
    );
  }

  /// The ordered places a `.env` is looked for.
  ///
  /// It used to be one bare relative path, which resolves against the process
  /// working directory: the project root under `flutter run`, and `/` for a
  /// bundle the Finder launched. So the file worked in development and was
  /// silently ignored in an installed build — the only place a pre-seeded
  /// build is actually for.
  ///
  /// No `Platform.isMacOS` anywhere: the macOS `Contents/Resources` candidate
  /// is simply a directory that does not exist on Windows, which is what the
  /// existence check is already for.
  static List<File> environmentCandidates(Directory support) {
    final String sep = Platform.pathSeparator;
    final String? named = Platform.environment[environmentFileVariable];
    final Directory executable = File(Platform.resolvedExecutable).parent;
    return <File>[
      // An explicit path wins over everything, and is the supported way to
      // point a build at a file it does not ship.
      if (named != null && named.isNotEmpty) File(named),
      // `flutter run` and `dart test` from the repository root.
      File('${Directory.current.path}$sep.env'),
      // Beside the executable: the whole Windows bundle is one directory.
      File('${executable.path}$sep.env'),
      // macOS keeps resources one level up from the executable.
      File('${executable.parent.path}${sep}Resources$sep.env'),
      // Droppable next to settings.json without touching a signed bundle.
      File('${support.path}$sep.env'),
    ];
  }

  static Future<Directory> _resolveRecordingsDirectory() async {
    final String? home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) {
      final String sep = Platform.pathSeparator;
      for (final String media in <String>['Movies', 'Videos']) {
        final Directory candidate = Directory('$home$sep$media');
        if (candidate.existsSync()) {
          return Directory('${candidate.path}$sep$_folderName');
        }
      }
    }
    final Directory documents = await getApplicationDocumentsDirectory();
    return Directory('${documents.path}${Platform.pathSeparator}$_folderName');
  }
}
