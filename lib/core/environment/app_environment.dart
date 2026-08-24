import 'dart:convert';
import 'dart:io';

/// Development configuration read from a `.env` document (§27).
///
/// `.env` is git-ignored and usually absent; an empty environment is the normal
/// case, not an error. Nothing here is a security boundary — a bot token in a
/// distributed binary is not secret (§16), and OAuth tokens belong in OS secure
/// storage, never in this file.
class AppEnvironment {
  const AppEnvironment(this._values, {this.sourcePath});

  const AppEnvironment.empty()
    : _values = const <String, String>{},
      sourcePath = null;

  /// Reads [file] when it exists, otherwise yields an empty environment.
  factory AppEnvironment.fromFile(File file) => file.existsSync()
      ? AppEnvironment.parse(file.readAsStringSync(), sourcePath: file.path)
      : const AppEnvironment.empty();

  /// Reads the first of [candidates] that exists, most specific first.
  ///
  /// There is more than one candidate because a bare `.env` is resolved
  /// against the *process working directory*: the project root under
  /// `flutter run`, and `/` for a bundle the Finder launched. A build
  /// pre-seeded through this file therefore worked in development and silently
  /// ignored the file everywhere else — the one place a pre-seeded build is
  /// for. [AppDirectories.environmentFiles] builds the list.
  factory AppEnvironment.fromFiles(Iterable<File> candidates) {
    for (final File file in candidates) {
      if (file.existsSync()) {
        return AppEnvironment.parse(
          file.readAsStringSync(),
          sourcePath: file.path,
        );
      }
    }
    return const AppEnvironment.empty();
  }

  /// Parses `KEY=VALUE` lines. Blank lines and `#` comment lines are skipped, a
  /// leading `export ` is dropped, surrounding single or double quotes are
  /// stripped, and `=` inside a value is preserved. Later duplicates win.
  factory AppEnvironment.parse(String document, {String? sourcePath}) {
    final Map<String, String> values = <String, String>{};
    for (final String rawLine in const LineSplitter().convert(document)) {
      final String line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) {
        continue;
      }
      final String assignment = line.startsWith(_exportPrefix)
          ? line.substring(_exportPrefix.length).trimLeft()
          : line;
      final int separator = assignment.indexOf('=');
      if (separator <= 0) {
        continue;
      }
      final String key = assignment.substring(0, separator).trim();
      if (key.isEmpty) {
        continue;
      }
      values[key] = _unquote(assignment.substring(separator + 1).trim());
    }
    return AppEnvironment(values, sourcePath: sourcePath);
  }

  static const String keyTelegramBotToken = 'TELEGRAM_BOT_TOKEN';
  static const String keyTelegramChatId = 'TELEGRAM_CHAT_ID';
  static const String keyTelegramBotApiBaseUrl = 'TELEGRAM_BOT_API_BASE_URL';

  static const String _exportPrefix = 'export ';

  final Map<String, String> _values;

  /// The document this was read from, or null for an empty environment. A
  /// path, never a value: it is safe to log and it is the only way to tell
  /// "no file" from "a file that set nothing" (§26).
  final String? sourcePath;

  /// Key names only, sorted. Values never leave this object (§26, §27).
  List<String> get keys => _values.keys.toList(growable: false)..sort();

  static String _unquote(String value) {
    if (value.length < 2) {
      return value;
    }
    final String first = value[0];
    if ((first == '"' || first == "'") && value.endsWith(first)) {
      return value.substring(1, value.length - 1);
    }
    return value;
  }

  String? get telegramBotToken => value(keyTelegramBotToken);

  String? get telegramChatId => value(keyTelegramChatId);

  /// Null means the official hosted endpoint; set it to reach a Local Bot API
  /// Server without the 50 MB cap (§16).
  String? get telegramBotApiBaseUrl => value(keyTelegramBotApiBaseUrl);

  bool get hasTelegramCredentials =>
      telegramBotToken != null && telegramChatId != null;

  /// The value for [key], or null when absent or blank.
  String? value(String key) {
    final String? raw = _values[key];
    return raw == null || raw.isEmpty ? null : raw;
  }

  /// Key names only — values never appear in diagnostics (§26).
  @override
  String toString() =>
      'AppEnvironment(source: ${sourcePath ?? '<none>'}, '
      'keys: ${keys.join(', ')})';
}
