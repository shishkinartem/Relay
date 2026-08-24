import Cocoa
import FlutterMacOS
import recorder_macos

@main
class AppDelegate: FlutterAppDelegate {
  /// Closing the panel quits the application — except while the recorder is
  /// the reason the panel is off screen.
  ///
  /// Recording hides the main window on purpose (§6). Answering `true`
  /// unconditionally makes AppKit terminate the process the moment Start is
  /// pressed, which looks exactly like a crash and strands the `.part` file.
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return RecorderWindowPolicy.terminatesOnLastWindowClosed
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
