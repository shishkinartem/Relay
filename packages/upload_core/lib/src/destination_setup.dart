import 'package:meta/meta.dart';

/// How a destination is connected (§15).
enum DestinationSetupKind {
  /// The user supplies values — a bot token, a chat id — and the destination
  /// verifies them.
  credentials,

  /// The destination runs an interactive flow itself, e.g. an OAuth sign-in in
  /// the system browser. [DestinationSetup.fields] may still carry the
  /// deployment values that flow needs.
  interactive,
}

/// One value the user supplies to connect a destination.
@immutable
class DestinationField {
  const DestinationField({
    required this.key,
    required this.label,
    this.hint,
    this.secret = false,
    this.optional = false,
    this.helpUrl,
    this.helpLabel,
  });

  /// Identifies the value in the map passed to [UploadDestination.connect].
  final String key;

  final String label;

  /// One line under the field: where the value comes from.
  final String? hint;

  /// Never read back out of storage, never logged, never put in a diagnostic
  /// (§26, §27). The form shows it as empty with the stored value implied.
  final bool secret;

  final bool optional;

  /// Where this particular value comes from, when that is a place rather than a
  /// sentence — the console that issues it, the server that has to exist first.
  final Uri? helpUrl;

  /// What the link to [helpUrl] says. Ignored when [helpUrl] is null.
  final String? helpLabel;
}

/// What a destination needs before it can accept a recording, and how to say so
/// to the user.
///
/// Presentation renders from this, so a new destination brings its own
/// instructions and fields instead of adding a branch to the settings screen
/// (`docs/architecture/uploads.md`).
@immutable
class DestinationSetup {
  const DestinationSetup({
    required this.kind,
    required this.actionLabel,
    required this.steps,
    this.fields = const <DestinationField>[],
    this.helpUrl,
    this.helpLabel = 'Open the documentation',
  });

  /// Nothing to configure: the destination is always ready.
  const DestinationSetup.none()
    : kind = DestinationSetupKind.credentials,
      actionLabel = '',
      steps = const <String>[],
      fields = const <DestinationField>[],
      helpUrl = null,
      helpLabel = '';

  final DestinationSetupKind kind;

  /// The button that performs the connection — `Connect`, `Sign in`.
  final String actionLabel;

  /// Ordered, plain-language instructions for obtaining the values above.
  final List<String> steps;

  final List<DestinationField> fields;

  /// Where the steps are documented in full, or the page they start on.
  final Uri? helpUrl;

  /// What the link to [helpUrl] says. "Open the Google Cloud console" is worth
  /// more than "Open the documentation" when that is where the work happens.
  final String helpLabel;

  bool get isRequired => steps.isNotEmpty || fields.isNotEmpty;
}
