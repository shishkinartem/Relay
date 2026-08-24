/// Destination-agnostic upload contracts.
///
/// Feature code depends on this package; it never imports Telegram or Google
/// APIs directly (§14).
library;

export 'src/credential_store.dart';
export 'src/destination_setup.dart';
export 'src/retry_policy.dart';
export 'src/retrying_upload_destination.dart';
export 'src/transfer.dart';
export 'src/upload_capabilities.dart';
export 'src/upload_destination.dart';
export 'src/upload_error.dart';
export 'src/upload_event.dart';
export 'src/upload_file.dart';
