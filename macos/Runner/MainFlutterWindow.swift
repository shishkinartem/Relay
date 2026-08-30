import Cocoa
import FlutterMacOS

/// The main panel window.
///
/// A utility panel that opens at 420 x 560 and may be widened to 960
/// (`TECHNICAL_SPEC.md` §33.6). 420 is the width every screen is drawn at and
/// stays the minimum; past 960 the content is a column of controls in an ocean.
/// The system title bar is made transparent and its title hidden so the
/// application's own header row sits in that space: the real traffic lights stay
/// functional, and the header is not duplicated by a drawn one.
class MainFlutterWindow: NSWindow {
  static let panelWidth: CGFloat = 420
  static let panelHeight: CGFloat = 560
  static let panelMinHeight: CGFloat = 460
  static let panelMaxWidth: CGFloat = 960

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    contentViewController = flutterViewController

    styleMask.insert(.fullSizeContentView)
    titlebarAppearsTransparent = true
    titleVisibility = .hidden
    isMovableByWindowBackground = true
    backgroundColor = NSColor(
      calibratedRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF3 / 255, alpha: 1)

    setContentSize(
      NSSize(
        width: MainFlutterWindow.panelWidth, height: MainFlutterWindow.panelHeight))
    contentMinSize = NSSize(
      width: MainFlutterWindow.panelWidth, height: MainFlutterWindow.panelMinHeight)
    contentMaxSize = NSSize(
      width: MainFlutterWindow.panelMaxWidth, height: CGFloat.greatestFiniteMagnitude)
    // Zoom is enabled again now that width is a range rather than a constant;
    // the window can grow to a size that is actually different.
    center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
