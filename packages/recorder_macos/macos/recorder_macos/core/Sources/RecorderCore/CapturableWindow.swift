import Foundation

/// One window's attributes, as far as "may the user pick this to record?" is
/// concerned (§4.1).
///
/// A plain value rather than an `SCWindow`, so the rule below can be executed
/// by `swift test`: `ScreenCaptureKit` types cannot be constructed in a test,
/// and a rule that decides what fifteen entries of a picker contain is exactly
/// the kind of thing that should not first need a windowing session to check.
public struct CapturableWindowAttributes: Equatable, Sendable {
  public init(
    title: String,
    applicationName: String,
    width: CGFloat,
    height: CGFloat,
    layer: Int,
    isOnScreen: Bool,
    belongsToThisApplication: Bool,
    isExplicitlyExcluded: Bool = false
  ) {
    self.title = title
    self.applicationName = applicationName
    self.width = width
    self.height = height
    self.layer = layer
    self.isOnScreen = isOnScreen
    self.belongsToThisApplication = belongsToThisApplication
    self.isExplicitlyExcluded = isExplicitlyExcluded
  }

  public let title: String
  public let applicationName: String
  public let width: CGFloat
  public let height: CGFloat

  /// The Core Graphics window level. `0` is the level ordinary application
  /// windows live at; everything above it is system furniture.
  public let layer: Int

  public let isOnScreen: Bool

  /// Our own panels and the main window — never offered as a capture target.
  public let belongsToThisApplication: Bool

  /// In the caller's exclusion set: the always-on-top surfaces this session has
  /// already put on screen.
  public let isExplicitlyExcluded: Bool
}

/// Which windows the source picker is allowed to show.
///
/// This is the macOS half of one cross-platform rule. Windows applies the
/// alt-tab rule in `IsCapturableWindow` — visible, titled, non-cloaked,
/// non-tool, top-level — and this is the same rule expressed in the terms
/// `SCShareableContent` reports. Two pickers that disagree about what a window
/// is would be two products.
///
/// The rule it replaced accepted a window when *either* its title or its owning
/// application's name was non-empty, which is true of nearly everything the
/// window server knows about: wallpaper layers, menu-bar status items, the Dock,
/// spotlight, notification banners and every offscreen helper panel an
/// application keeps around. The picker filled up with entries that name an
/// application but do not correspond to anything the user can point at.
public enum CapturableWindowRule {
  /// Windows narrower or shorter than this are helper surfaces, not documents.
  ///
  /// Deliberately generous: the level and title rules below do the work, and a
  /// threshold large enough to matter on its own would start dropping real
  /// utility windows.
  public static let minimumEdge: CGFloat = 96

  /// The Core Graphics level ordinary application windows occupy.
  public static let normalWindowLayer = 0

  public static func isCapturable(_ window: CapturableWindowAttributes) -> Bool {
    if window.belongsToThisApplication || window.isExplicitlyExcluded {
      return false
    }
    guard window.isOnScreen else { return false }
    // Above the normal level sits everything that is not a document: the menu
    // bar and its status items, the Dock, notification banners, tooltips, and
    // other applications' always-on-top panels. Below it sits the desktop.
    guard window.layer == normalWindowLayer else { return false }
    // The alt-tab rule. An untitled window is either a helper surface or a
    // shadow of one, and it cannot be labelled in the picker either way: the
    // entry would read as the application name and nothing else, repeated once
    // per hidden window that application happens to own.
    guard !window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return false }
    guard !window.applicationName.isEmpty else { return false }
    return window.width >= minimumEdge && window.height >= minimumEdge
  }
}
