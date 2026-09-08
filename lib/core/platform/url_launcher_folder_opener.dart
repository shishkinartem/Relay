import 'package:url_launcher/url_launcher.dart';

import 'folder_opener.dart';

/// Opens the folder through `url_launcher`, which reaches the platform's file
/// manager without this package naming an operating system.
///
/// It opens the *containing folder*; it cannot select the file inside it.
/// Revealing with a selection needs `NSWorkspace.activateFileViewerSelecting`
/// and `SHOpenFolderAndSelectItems` — a new `relay/recorder` method on both
/// platforms and a row in `docs/architecture/platform-channel-contract.md`.
/// That was not built, which is why the button says `Open folder` rather than
/// promising a reveal it cannot perform.
class UrlLauncherFolderOpener implements FolderOpener {
  const UrlLauncherFolderOpener();

  @override
  Future<bool> open(String directoryPath) async {
    try {
      // `Uri.directory` applies the running platform's separator convention
      // itself, so no OS name is needed here.
      return await launchUrl(
        Uri.directory(directoryPath),
        mode: LaunchMode.externalApplication,
      );
    } on Object {
      // A platform with no implementation registered throws rather than
      // answering false. Either way the caption naming the folder stays true.
      return false;
    }
  }
}
