import Cocoa
import FlutterMacOS

/// The main panel window.
///
/// A fixed-width 420 x 560 utility panel, per the design's own constraint that
/// the panel never grows past 420 x 560. The system title bar is made
/// transparent and its title hidden so the application's own header row sits in
/// that space: the real traffic lights stay functional, and the header is not
/// duplicated by a drawn one.
class MainFlutterWindow: NSWindow {
  static let panelWidth: CGFloat = 420
  static let panelHeight: CGFloat = 560
  static let panelMinHeight: CGFloat = 460

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
      width: MainFlutterWindow.panelWidth, height: CGFloat.greatestFiniteMagnitude)
    // Zoom would fight a fixed-width panel.
    standardWindowButton(.zoomButton)?.isEnabled = false
    center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
