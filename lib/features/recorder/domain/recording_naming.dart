import '../../../core/formatting/formatters.dart';

/// Naming rules for a recording file.
///
/// The name is chosen once at finalization and may be edited in the ready
/// screen; editing renames the file on disk and never re-finalizes it, so the
/// recording stays valid after a failed upload (design `1i`).
abstract final class RecordingNaming {
  static const String extension = 'mp4';
  static const int maxLength = 120;

  static String defaultName(DateTime at) =>
      'recording-${formatFileTimestamp(at)}';

  /// Reduces user input to something safe to write on both platforms.
  ///
  /// Returns null when nothing usable remains, so the caller keeps the
  /// previous name rather than writing an empty file name.
  static String? sanitize(String input) {
    final String collapsed = input
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'^\.+'), '')
        .replaceAll(RegExp(r'\.+$'), '')
        .trim();
    if (collapsed.isEmpty) {
      return null;
    }
    return collapsed.length <= maxLength
        ? collapsed
        : collapsed.substring(0, maxLength).trim();
  }

  static String fileName(String name) => '$name.$extension';
}
