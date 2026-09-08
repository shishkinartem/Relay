/// Opens a directory in the platform's own file manager.
///
/// An interface, for two reasons. The application layer holds it, and
/// `test/architecture_test.dart` requires every collaborator an `/application/`
/// class holds to be substitutable. And a widget test has to be able to press
/// `Open folder` without a Finder window appearing on the machine running the
/// suite.
abstract interface class FolderOpener {
  /// True when the platform accepted the request.
  ///
  /// False is not a failure the user has to act on: the folder is named on
  /// screen either way, so the worst case is that they open it themselves.
  Future<bool> open(String directoryPath);
}
