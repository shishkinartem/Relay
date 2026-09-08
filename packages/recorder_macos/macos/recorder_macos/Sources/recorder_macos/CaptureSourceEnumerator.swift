import AppKit
import CoreImage
import RecorderCore
import ScreenCaptureKit

/// One capture target as the picker sees it.
struct EnumeratedSource {
  let id: String
  let type: String
  let title: String
  let subtitle: String
  let pixelWidth: Int
  let pixelHeight: Int
  let isCurrentDisplay: Bool
  var thumbnail: Data?
}

/// Enumerates displays and windows through `SCShareableContent` (§4.1).
///
/// Displays first, then windows — the ordering is part of the channel
/// contract. Thumbnails come from one snapshot per refresh, never a live
/// stream.
final class CaptureSourceEnumerator {
  private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
  private var cachedContent: SCShareableContent?

  /// The last enumeration's shareable content, reused so `prepare` resolves a
  /// source id without a second, slower system call.
  private(set) var lastContent: SCShareableContent?

  func shareableContent() async throws -> SCShareableContent {
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      lastContent = content
      cachedContent = content
      return content
    } catch {
      // Not every failure here is a refusal. Reporting one as `permissionDenied`
      // put a user whose Mac had a transient ScreenCaptureKit fault on a
      // blocking screen accusing them of refusing a permission they had
      // granted, so only the code macOS documents as "the user chose not to
      // authorize capture" is treated that way.
      if (error as NSError).isScreenCaptureUserDeclined {
        // This call is what raised the system prompt, so the application has
        // asked — even though nothing in `RecorderPermissions` did the asking.
        RecorderPermissions.noteScreenRecordingAsked()
        throw RecorderError(
          .permissionDenied,
          "Screen recording permission is required to list capture sources.",
          details: error.localizedDescription)
      }
      throw RecorderError(
        .sourceUnavailable,
        "The list of capture sources could not be read.",
        details: error.localizedDescription)
    }
  }

  func enumerate(refreshThumbnails: Bool, excludedWindowIDs: Set<CGWindowID>)
    async throws -> [EnumeratedSource]
  {
    let content = try await shareableContent()
    let currentDisplayID = CaptureSourceEnumerator.currentDisplayID()
    var sources: [EnumeratedSource] = []

    for display in content.displays {
      // `SCDisplay.width/height` are POINTS — the ScreenCaptureKit header says
      // so. The channel key is `pixelWidth`, Windows sends physical pixels, and
      // the recorder sizes its canvas from this number, so sending points here
      // halved the resolution of every recording on every Retina Mac: a
      // 3024x1964 panel was captured as 1512x982 and "1080p" produced 982
      // lines. Text is what shows it first, because a 2:1 downsample of glyphs
      // hinted for the 2x grid is done before anything that understands them.
      let (pixelWidth, pixelHeight) =
        CaptureSourceEnumerator.backingPixels(of: display)
      var source = EnumeratedSource(
        id: "display:\(display.displayID)",
        type: "display",
        title: CaptureSourceEnumerator.displayName(for: display.displayID),
        subtitle: "\(pixelWidth) × \(pixelHeight)",
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        isCurrentDisplay: display.displayID == currentDisplayID,
        thumbnail: nil)
      if refreshThumbnails {
        source.thumbnail = await displayThumbnail(
          display: display,
          excluding: content.windows.filter {
            excludedWindowIDs.contains($0.windowID)
          })
      }
      sources.append(source)
    }

    let ownPID = ProcessInfo.processInfo.processIdentifier
    // `CapturableWindowRule` is the rule itself, in RecorderCore, under test,
    // and deliberately the same rule Windows applies in `IsCapturableWindow`.
    // Everything here is the mapping into it.
    let windows = content.windows.filter { window in
      CapturableWindowRule.isCapturable(
        window.capturableAttributes(
          ownProcessIdentifier: ownPID, excludedWindowIDs: excludedWindowIDs))
    }
    .sorted { lhs, rhs in
      let l = lhs.owningApplication?.applicationName ?? ""
      let r = rhs.owningApplication?.applicationName ?? ""
      return l == r ? (lhs.title ?? "") < (rhs.title ?? "") : l < r
    }

    for window in windows {
      var source = EnumeratedSource(
        id: "window:\(window.windowID)",
        type: "window",
        title: window.owningApplication?.applicationName ?? "Window",
        subtitle: window.title ?? "",
        // `SCWindow.frame` is in points too, so a window on a Retina display
        // needs the same correction the displays above get.
        pixelWidth: Int(
          (window.frame.width * CaptureSourceEnumerator.scaleOf(window)).rounded()),
        pixelHeight: Int(
          (window.frame.height * CaptureSourceEnumerator.scaleOf(window)).rounded()),
        isCurrentDisplay: false,
        thumbnail: nil)
      if refreshThumbnails {
        source.thumbnail = await windowThumbnail(window: window)
      }
      sources.append(source)
    }

    return sources
  }

  /// Resolves a source id back to a content filter for `prepare`.
  func filter(
    forSourceId sourceId: String,
    excludedWindowIDs: Set<CGWindowID>,
    content: SCShareableContent
  ) throws -> (SCContentFilter, CGSize) {
    let parts = sourceId.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, let rawID = UInt32(parts[1]) else {
      throw RecorderError(.sourceUnavailable, "The selected source id is malformed.")
    }
    if parts[0] == "display" {
      guard let display = content.displays.first(where: { $0.displayID == rawID })
      else {
        throw RecorderError(
          .sourceUnavailable, "That display is no longer connected.")
      }
      let excluded = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
      return (
        SCContentFilter(display: display, excludingWindows: excluded),
        CGSize(width: display.width, height: display.height)
      )
    }
    guard let window = content.windows.first(where: { $0.windowID == rawID }) else {
      throw RecorderError(.sourceClosed, "That window is no longer open.")
    }
    return (
      SCContentFilter(desktopIndependentWindow: window),
      CGSize(width: window.frame.width, height: window.frame.height)
    )
  }

  /// `SCScreenshotManager` is the modern path but needs macOS 14; on 13 the
  /// Core Graphics window-list capture produces the same still. Both are
  /// one-shot snapshots — the picker never opens a live stream (§4.1).
  private func displayThumbnail(display: SCDisplay, excluding: [SCWindow]) async
    -> Data?
  {
    let width = 480
    let height = max(1, Int(480.0 * Double(display.height) / Double(display.width)))
    if #available(macOS 14.0, *) {
      let filter = SCContentFilter(display: display, excludingWindows: excluding)
      if let data = try? await snapshot(filter: filter, width: width, height: height)
      {
        return data
      }
    }
    guard let image = CGDisplayCreateImage(display.displayID) else { return nil }
    return png(from: image, width: width, height: height)
  }

  private func windowThumbnail(window: SCWindow) async -> Data? {
    let width = 320
    let height = max(
      1, Int(320.0 * window.frame.height / max(window.frame.width, 1)))
    if #available(macOS 14.0, *) {
      let filter = SCContentFilter(desktopIndependentWindow: window)
      if let data = try? await snapshot(filter: filter, width: width, height: height)
      {
        return data
      }
    }
    guard
      let image = CGWindowListCreateImage(
        .null, .optionIncludingWindow, window.windowID,
        [.boundsIgnoreFraming, .nominalResolution])
    else { return nil }
    return png(from: image, width: width, height: height)
  }

  @available(macOS 14.0, *)
  private func snapshot(filter: SCContentFilter, width: Int, height: Int) async throws
    -> Data?
  {
    let configuration = SCStreamConfiguration()
    configuration.width = max(1, width)
    configuration.height = max(1, height)
    configuration.showsCursor = false
    configuration.capturesAudio = false
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: configuration)
    return png(from: image, width: width, height: height)
  }

  private func png(from image: CGImage, width: Int, height: Int) -> Data? {
    let scaled = CIImage(cgImage: image)
    let sx = Double(width) / Double(image.width)
    let sy = Double(height) / Double(image.height)
    let transformed = scaled.transformed(
      by: CGAffineTransform(scaleX: sx, y: sy))
    guard
      let rendered = ciContext.createCGImage(transformed, from: transformed.extent)
    else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: rendered)
    return bitmap.representation(using: .png, properties: [:])
  }

  /// A display's real backing-store size, in pixels.
  ///
  /// `SCDisplay` only ever reports points, so the pixel count has to come from
  /// the display mode. `CGDisplayModeGetPixelWidth/Height` are the authority —
  /// they report the framebuffer, which on a scaled Retina mode is neither the
  /// point size nor the mode's own nominal size. A display whose mode cannot be
  /// read falls back to points, which is the number this used to send and is
  /// never worse than refusing to enumerate it.
  ///
  /// The properties, not `CGDisplayModeGetPixelWidth/Height`: the C functions
  /// are renamed by API notes and are an error to call from Swift against a
  /// recent SDK. `swift test` does not catch that — this file is in the
  /// plugin's own sources, outside the `RecorderCore` package the Swift suite
  /// compiles — so only the macOS application build does.
  static func backingPixels(of display: SCDisplay) -> (Int, Int) {
    guard let mode = CGDisplayCopyDisplayMode(display.displayID) else {
      return (display.width, display.height)
    }
    let width = mode.pixelWidth
    let height = mode.pixelHeight
    guard width > 0, height > 0 else {
      return (display.width, display.height)
    }
    return (width, height)
  }

  /// The backing scale of the display a window is on, for the same correction.
  ///
  /// A window carries no scale of its own and can sit on any display, so the
  /// frame decides which one to ask.
  ///
  /// **Entirely in Core Graphics, deliberately.** `SCWindow.frame` is a CG rect
  /// — global space, origin top-left — while `NSScreen.frame` is Cocoa, origin
  /// bottom-left. Intersecting the two only appears to work because a
  /// single-display desktop makes the two spaces coincide; on displays stacked
  /// vertically the test misses every screen, falls back to the main one, and
  /// reports a window's size off by that display's scale factor. The scale is
  /// therefore derived from the display's own mode — pixels over points — which
  /// is the same source `backingPixels(of:)` uses.
  ///
  /// It also keeps AppKit out of this call. `enumerate` runs off the main
  /// thread, and `NSScreen` there is undefined behaviour.
  static func scaleOf(_ window: SCWindow) -> CGFloat {
    var displayID = CGDirectDisplayID(0)
    var count: UInt32 = 0
    guard
      CGGetDisplaysWithRect(window.frame, 1, &displayID, &count) == .success,
      count > 0,
      let mode = CGDisplayCopyDisplayMode(displayID)
    else {
      return 1
    }
    let points = CGDisplayBounds(displayID).width
    guard points > 0 else { return 1 }
    return CGFloat(mode.pixelWidth) / points
  }

  /// The display holding the main application window (§5).
  ///
  /// Panels are skipped so this agrees with `OverlayWindowController`, which
  /// resolves placement against the same definition. An overlay panel is not
  /// the main window, and once one is on screen it would otherwise be able to
  /// answer a question that is only ever about the main window.
  static func currentDisplayID() -> CGDirectDisplayID {
    let window = NSApplication.shared.windows.first {
      !($0 is NSPanel) && $0.isVisible
    }
    let screen = window?.screen ?? NSScreen.main
    let number = screen?.deviceDescription[
      NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    return CGDirectDisplayID(number?.uint32Value ?? CGMainDisplayID())
  }

  static func displayName(for displayID: CGDirectDisplayID) -> String {
    for screen in NSScreen.screens {
      let number = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      if number?.uint32Value == displayID {
        return screen.localizedName
      }
    }
    return "Display"
  }

  /// Geometry of the current display, in logical points, for overlay placement.
  static func currentDisplayGeometry() -> [String: Any] {
    let window = NSApplication.shared.windows.first {
      !($0 is NSPanel) && $0.isVisible
    }
    let screen = window?.screen ?? NSScreen.main
    guard let screen else {
      return [
        "id": "", "logicalWidth": 0.0, "logicalHeight": 0.0,
        "pixelWidth": 0, "pixelHeight": 0, "scaleFactor": 1.0,
      ]
    }
    let frame = screen.frame
    let scale = screen.backingScaleFactor
    let number = screen.deviceDescription[
      NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    return [
      "id": String(number?.uint32Value ?? CGMainDisplayID()),
      "logicalWidth": Double(frame.width),
      "logicalHeight": Double(frame.height),
      "pixelWidth": Int(frame.width * scale),
      "pixelHeight": Int(frame.height * scale),
      "scaleFactor": Double(scale),
    ]
  }
}

extension NSError {
  /// `SCStreamError.userDeclined` (-3801) — the only ScreenCaptureKit code
  /// documented as the user refusing capture. Matched by domain and code rather
  /// than by casting, because `SCShareableContent` reports it as a plain
  /// `NSError` in the `SCStreamErrorDomain`.
  var isScreenCaptureUserDeclined: Bool {
    domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && code == -3801
  }
}

extension SCWindow {
  /// This window, as the picker's rule sees it (§4.1).
  ///
  /// `windowLayer` is the value the rule leans on hardest: a menu-bar status
  /// item, a notification banner and another application's floating palette are
  /// all titled, on screen and large enough, and only their level says they are
  /// not documents.
  func capturableAttributes(
    ownProcessIdentifier: pid_t,
    excludedWindowIDs: Set<CGWindowID>
  ) -> CapturableWindowAttributes {
    CapturableWindowAttributes(
      title: title ?? "",
      applicationName: owningApplication?.applicationName ?? "",
      width: frame.width,
      height: frame.height,
      layer: windowLayer,
      isOnScreen: isOnScreen,
      // A window with no owning application cannot be attributed to this
      // process, but it is not a capture target either — the rule drops it on
      // the empty application name.
      belongsToThisApplication: owningApplication?.processID == ownProcessIdentifier,
      isExplicitlyExcluded: excludedWindowIDs.contains(windowID))
  }
}
