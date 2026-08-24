import 'destination_setup.dart';
import 'upload_capabilities.dart';
import 'upload_error.dart';
import 'upload_event.dart';
import 'upload_file.dart';

/// Outcome of the pre-flight check (§14).
class UploadValidationResult {
  const UploadValidationResult.ok() : error = null;

  const UploadValidationResult.rejected(UploadError this.error);

  final UploadError? error;

  bool get isValid => error == null;
}

/// A replaceable upload target (§14).
///
/// Adding S3 or OneDrive means adding an implementation and registering it —
/// never touching the recorder (`docs/architecture/uploads.md`).
abstract interface class UploadDestination {
  /// Stable identifier, persisted in settings.
  String get id;

  String get displayName;

  UploadCapabilities get capabilities;

  /// A short account/endpoint line for the settings and destination screens,
  /// or null when the destination is unconfigured.
  Future<String?> describeAccount();

  /// What this destination needs before it can accept a recording, and the
  /// instructions for supplying it (§15). Static: it describes the destination,
  /// not the current state.
  DestinationSetup get setup;

  /// Whether the destination can accept a recording right now.
  ///
  /// Cheap and offline where possible: it decides what Settings renders, not
  /// whether an upload may start — [validate] is still the pre-flight.
  Future<bool> isConnected();

  /// Applies [values] and runs whatever interactive flow the destination needs.
  ///
  /// Verifies before it stores, so a typo is reported here rather than at the
  /// end of a recording. Throws [UploadError] when the credentials are refused;
  /// the message is shown to the user.
  Future<void> connect(Map<String, String> values);

  /// Forgets the stored credentials. Idempotent.
  Future<void> disconnect();

  /// Values to prefill the connect form with.
  ///
  /// A [DestinationField.secret] value is never returned: it is written once
  /// and never read back out for display (§27).
  Future<Map<String, String>> storedSetupValues();

  /// Cheap pre-flight. Must not start a transfer, and must fail fast on a file
  /// the destination cannot accept.
  Future<UploadValidationResult> validate(UploadFile file);

  /// Performs the upload, reporting progress. The stream completes after
  /// exactly one terminal event: [UploadSucceeded], [UploadFailed] or
  /// [UploadCancelled].
  Stream<UploadEvent> upload(UploadFile file, UploadContext context);

  /// Cancels an in-flight upload. Idempotent, and safe to call after the
  /// upload already finished.
  Future<void> cancel(String uploadId);

  /// Releases whatever the destination holds open — sockets, timers, clients.
  ///
  /// Declared here so the registry can release every destination it owns
  /// without knowing what any of them are. Both shipping implementations had
  /// this method before the contract did, which meant nothing could reach it.
  /// Idempotent.
  void dispose();
}
