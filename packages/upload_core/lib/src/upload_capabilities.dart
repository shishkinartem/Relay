import 'package:meta/meta.dart';

/// What a destination can do, as data rather than as `if (isTelegram)` (§28).
///
/// The settings and change-destination screens render straight from this, so a
/// Local Bot API Server URL removing the size cap removes the "50 MB max" tag
/// with no UI change (design `1m`, `1o`).
@immutable
class UploadCapabilities {
  const UploadCapabilities({
    this.maxFileSizeBytes,
    this.supportsResume = false,
    this.supportsCancellation = true,
    this.supportsProgress = true,
    this.requiresAuthentication = false,
    this.transportSummary = '',
  });

  /// Hard limit enforced by the destination, or null when it has none.
  final int? maxFileSizeBytes;

  final bool supportsResume;
  final bool supportsCancellation;
  final bool supportsProgress;
  final bool requiresAuthentication;

  /// One short line describing the transport, shown under the destination name.
  final String transportSummary;

  bool accepts(int sizeBytes) =>
      maxFileSizeBytes == null || sizeBytes <= maxFileSizeBytes!;
}
