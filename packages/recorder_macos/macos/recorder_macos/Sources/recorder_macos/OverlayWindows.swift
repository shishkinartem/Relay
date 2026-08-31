import AppKit
import CoreVideo
import FlutterMacOS
import Foundation
import OSLog
import RecorderCore

/// The overlay windows' own log.
///
/// `os.Logger` rather than `print`: these windows misbehave while a recording
/// is running, which is exactly when nobody is watching a console, and the
/// unified log keeps what happened until someone asks. Nothing here logs a
/// device name, a file path or anything else that is the user's (§secrets).
let overlayLog = Logger(subsystem: "com.relay.relay", category: "overlay")

/// The camera preview's frames, exposed to the preview engine as a texture.
///
/// The preview shows the same logical camera source the compositor draws into
/// the picture-in-picture; it is never screen-captured back out of the preview
/// window (§7).
final class CameraPreviewTexture: NSObject, FlutterTexture {
  private let provider: () -> CVPixelBuffer?

  init(provider: @escaping () -> CVPixelBuffer?) {
    self.provider = provider
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    guard let buffer = provider() else { return nil }
    return Unmanaged.passRetained(buffer)
  }
}

/// What the host knows about the camera and Dart does not (§33.5).
///
/// The shape its frames actually have, the pixels it produces, and the encoder
/// canvas those pixels are measured against. Dart resolves the tile from the
/// configured fallback shape and the preset's own width cap, because none of
/// these three are visible from that side.
struct CameraTileSource {
  var aspectRatio: Double = 16.0 / 9.0

  /// Nil before a camera is open: the cap then has nothing to compare against
  /// and the configured width stands.
  var pixelWidth: Int?

  /// Zero where there is no session, for the same reason.
  var canvasWidth: Double = 0
}

/// Creates, places and tears down the application's always-on-top windows.
///
/// Three of them: the control strip, the camera preview and the input menu a
/// chevron opens (§33.4). Every window created here is a separate top-level
/// panel — never a child of a captured window — is marked
/// `sharingType = .none`, and is reported from `excludedWindowIDs` so it also
/// reaches the capture filter's exclusion list. With a display source, that
/// exclusion is the only thing keeping these surfaces out of the file (§6), and
/// a menu that appears in a recording is the one unacceptable outcome.
///
/// **Every one of them appears after the session was prepared**, so none can be
/// in the filter that `prepare` built: a filter names windows that were on
/// screen when it was made. `onOverlayWindowsChanged` is how the second
/// mechanism catches up — the plugin re-points the running capture at a filter
/// that holds whichever panels are on screen now (`CaptureExclusionPolicy`).
///
/// **One size per show.** A panel hosting a `FlutterView` blocks the platform
/// thread on every resize until that engine's raster thread commits a frame at
/// the new size, so each distinct size a panel is driven through is a real
/// rendered frame. Sizes are therefore resolved once, in
/// `OverlayPlacementGeometry`, and applied once. This is not tidiness: driving
/// a panel through size A → B → A inside one main-loop turn is what crashed the
/// second recording of every session. See `docs/architecture/recording.md`.
///
/// The camera preview obeys the rule the same way the other two do, by being
/// sized for **every** shape it can hold rather than for the one it is showing:
/// its window takes the bounding size of all three presets and the tile is
/// drawn as a rectangle inside it. Sizing it to the tile made `Camera → Square
/// → Camera` — one press each way — a literal A → B → A, which is why it was
/// the last panel still alternating.
final class OverlayWindowController {
  private var stripEngine: FlutterEngine?
  private var stripChannel: FlutterMethodChannel?
  private var stripPanel: NSPanel?

  private var previewEngine: FlutterEngine?
  private var previewChannel: FlutterMethodChannel?
  private var previewPanel: NSPanel?
  private var previewTextureId: Int64?

  private var menuEngine: FlutterEngine?
  private var menuChannel: FlutterMethodChannel?
  private var menuPanel: NSPanel?

  /// What each shape of sheet measured, and the shape currently on screen.
  ///
  /// Keyed by `OverlayPlacementGeometry.menuContentKey`, so a sheet is only ever
  /// corrected the first time its shape is seen — see `showInputMenu`. Not
  /// cleared between sessions: a measurement is a fact about the design and the
  /// system's text metrics, and neither changes when a recording stops.
  private var menuMeasuredSizes: [String: NSSize] = [:]
  private var menuContentKey: String?

  /// The one-shot mouse-up watch each dragged panel has outstanding.
  private var dragEndMonitors: [ObjectIdentifier: Any] = [:]

  /// The most recent left-button event, and the monitor that keeps it.
  ///
  /// `NSApp.currentEvent` cannot answer "what started this gesture". The drag
  /// request arrives on a channel, drained from a run-loop source about a frame
  /// after the pointer move Dart reacted to, so `currentEvent` is merely
  /// whatever AppKit last dequeued — very often an `appKitDefined` window-moved
  /// event, which every `setFrameOrigin` emits, including the previous drag's
  /// own settle. The guard then rejected the gesture, and the Dart side latches
  /// its request for the whole gesture, so the user had to release and press
  /// again. From the outside: a drag that works every other time and a cursor
  /// that does not catch.
  private var lastLeftMouseEvent: NSEvent?
  private var leftMouseMonitor: Any?

  /// The tile, and what the camera behind it produces.
  ///
  /// Held because in display mode the preview window *is* the
  /// picture-in-picture (design `1p`): a drag settles against the same
  /// rectangle the compositor resolves, and a preset, a swap or a change the
  /// application applied re-places the window through it. `previewOverlay` is
  /// nil in window mode, where the preview is a separate captioned object and
  /// deliberately not the tile (design `1e`).
  ///
  /// Kept exactly as Dart sent it, never as resolved: the `camera` preset's
  /// width cap is resolved *from* it against whichever camera is open now, and
  /// storing the answer instead would ratchet the tile down to the narrowest
  /// camera the session has ever held.
  ///
  /// Main-thread state, like every field here except `previewSignal`.
  private var previewOverlay: CameraOverlayConfiguration?
  private var previewSource = CameraTileSource()
  private var previewMatchesPip = false

  /// Where the preview draws, inside its own window: top-left origin, in the
  /// window's own points.
  ///
  /// The window is deliberately **larger than the tile** and is never resized
  /// (`OverlayPlacementGeometry.previewWindowFrame`), so "where is the tile" is
  /// no longer answered by the window's frame. It is answered here, and by the
  /// `content` rectangle the preview engine is pushed — which is the same
  /// rectangle, because both come from this one value.
  ///
  /// Held rather than recomputed at each use because a drag needs it: AppKit's
  /// drag loop moves the *window*, and where the tile ended up is the window's
  /// new origin plus this. Nil before the first placement.
  private var previewContentRect: CGRect?

  /// The chevron the open menu belongs under, in screen coordinates, and the
  /// gap the placement asked for.
  ///
  /// Only Flutter knows where a control ended up inside the strip, so its centre
  /// travels with the command that raised the menu and is resolved against the
  /// strip's frame the moment it arrives (§33.4).
  private var menuAnchorX: CGFloat?
  private var menuGap: Double = 7

  /// What is watching for a click outside the menu, and for Esc.
  private var menuDismissMonitors: [Any] = []
  private var pendingMenuSize: NSSize?

  /// Which input the open sheet belongs to, or nil when none is open.
  ///
  /// Held because a dismissal has to name it: the application draws one chevron
  /// per input and tracks which one it believes is open, and a report that said
  /// only "a menu closed" could not tell it which chevron to draw closed
  /// (§33.4). Cleared by the single close path, so it can never outlive the
  /// window it names.
  private var openMenuKind: MediaDeviceKind?

  /// The engine and texture the camera capture queue is allowed to signal,
  /// published as one value under a lock.
  ///
  /// `showCameraPreview` assigns the engine and the texture id on the main
  /// thread while `markCameraFrameAvailable()` reads both from the camera
  /// capture queue. Two independent optionals can be observed half-updated,
  /// and an unsynchronised read of a class reference can over-release. One
  /// guarded tuple makes the pair atomic and the read safe.
  private let previewSignalLock = NSLock()
  private var previewSignal: (engine: FlutterEngine, textureId: Int64)?

  private var lastStripState: [String: Any] = [:]
  private var lastPreviewState: [String: Any] = [:]

  /// The last size the strip measured itself at.
  ///
  /// The panel outlives a session, and so does the overlay engine: on a second
  /// recording the strip has nothing new to say about its own size, so the
  /// placement's *requested* size — narrower than the strip — would leave Pause
  /// and Stop rendered outside the window and unclickable. Remembering the
  /// measurement here is what makes the second session identical to the first,
  /// and `OverlayPlacementGeometry.effectiveSize` is where it wins over the
  /// request rather than being applied after it.
  private var stripContentSize: NSSize?
  private var pendingStripSize: NSSize?

  /// The display the session's overlays are placed on (§5).
  ///
  /// Captured while the main application window is still on screen and held for
  /// the rest of the session. Recording hides that window on purpose (§6), and
  /// from that moment "the display holding the main window" has no answer —
  /// anything placed later, such as a camera preview raised by the strip's own
  /// toggle, would silently fall back to whichever display has keyboard focus,
  /// i.e. the one the user happens to be working on. §5 defines the current
  /// display as the main window's and allows recalculation only before
  /// recording begins, so the answer is taken once and kept.
  private var sessionScreen: NSScreen?

  /// Where the strip sits, as the fraction §33.3 stores (`OverlayStripRatio`).
  ///
  /// Kept so a display change can re-resolve the *fraction* rather than shuffle
  /// whatever pixels AppKit left the window at: once a display is unplugged the
  /// panel has already been relocated, and its frame no longer says where the
  /// user had put it.
  ///
  /// Main-thread state, like every other field here except `previewSignal`. It
  /// is written from `showControlStrip`, from the end of a drag, from a
  /// measured resize and from the screen-parameters notification — all AppKit
  /// callbacks on the main thread — and read from the same place, so it needs
  /// no lock of its own.
  private var stripPosition: OverlayStripRatio?

  /// The registration for `didChangeScreenParametersNotification`, held so it
  /// can be taken back down in `deinit`.
  private var screenObserver: NSObjectProtocol?

  init() {
    // A display disconnected, a resolution or scale change, and the Dock being
    // shown, hidden or moved all change the usable area under a strip that is
    // already placed (§33.7). The strip is re-resolved rather than left where
    // it was, which is what keeps the menu bar and the notch uncovered
    // continuously instead of only at the moment it was first docked.
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      self?.reclampControlStrip()
    }
  }

  deinit {
    if let screenObserver {
      NotificationCenter.default.removeObserver(screenObserver)
    }
    // A monitor outlives the object that installed it; one left behind would
    // call into a freed controller on the next click anywhere on the machine.
    endMenuDismissWatch()
    for monitor in dragEndMonitors.values {
      NSEvent.removeMonitor(monitor)
    }
    dragEndMonitors.removeAll()
    endLeftMouseWatch()
  }

  /// Raised by the control strip and forwarded to the application engine.
  var onCommand: ((String) -> Void)?

  /// A device chosen in the input menu, forwarded to the application engine as
  /// a map beside the bare command names (§33.4).
  var onMenuSelection: (([String: Any]) -> Void)?

  /// The preview was dragged, and it is the tile: its new top-left as a
  /// fraction of the canvas (§33.5).
  ///
  /// Applied to the live compositor by the plugin rather than waited for from
  /// the application, because the drag happens entirely inside AppKit's own
  /// loop and a preview that has moved while the file has not is exactly the
  /// disagreement design `1p` forbids.
  var onCameraPreviewMoved: ((CGPoint) -> Void)?

  /// Supplies camera frames for the preview texture.
  var cameraFrameProvider: (() -> CVPixelBuffer?)?

  /// The tile as Dart last described it, for a caller that has to hand the same
  /// description to the compositor — a drag settled here, for instance.
  var cameraOverlay: CameraOverlayConfiguration? { previewOverlay }

  /// A panel has just come on screen (§6).
  ///
  /// Every overlay is shown *after* the session was prepared, and the content
  /// filter prepared there was built from a snapshot of the on-screen windows,
  /// so none of them can be in it. The plugin listens here and re-points the
  /// running capture at a filter that names them; see `CaptureExclusionPolicy`.
  var onOverlayWindowsChanged: (() -> Void)?

  /// Every window id the capture filter must exclude.
  var excludedWindowIDs: Set<CGWindowID> { windowIDs(onScreenOnly: false) }

  /// The subset of those that the window server is listing right now.
  ///
  /// `excludedWindowIDs` reports every panel this controller owns, on screen or
  /// not, because that is what the contract's `excludedWindowIds` promises. A
  /// content filter can only be built from windows `SCShareableContent` lists,
  /// which are the on-screen ones — so "is the live filter still complete?" is
  /// asked of this narrower set instead.
  var onScreenWindowIDs: Set<CGWindowID> { windowIDs(onScreenOnly: true) }

  private func windowIDs(onScreenOnly: Bool) -> Set<CGWindowID> {
    var ids = Set<CGWindowID>()
    for panel in [stripPanel, previewPanel, menuPanel] {
      guard let panel, panel.windowNumber > 0 else { continue }
      if onScreenOnly && !panel.isVisible { continue }
      ids.insert(CGWindowID(panel.windowNumber))
    }
    return ids
  }

  /// Reports a panel that has just come on screen, and only then.
  ///
  /// A panel that was already visible is not announced: its id reached the
  /// filter when it first appeared, an exclusion survives the `orderOut(_:)`
  /// and re-show in between because the filter excludes by window id, and
  /// announcing it again would spend a system call on every menu open.
  private func announceOverlayWindow(_ panel: NSPanel, wasOnScreen: Bool) {
    guard !wasOnScreen, panel.isVisible else { return }
    onOverlayWindowsChanged?()
  }

  // MARK: - control strip

  func showControlStrip(placement: [String: Any]) {
    let engine = stripEngine ?? makeEngine(name: "relay.controlStrip", entrypoint: "controlStripMain")
    stripEngine = engine
    if stripChannel == nil {
      stripChannel = makeViewChannel(for: engine) { [weak self] call, result in
        self?.handleViewCall(call, result: result, from: .controlStrip)
      }
    }

    // The strip is the first overlay of a session, and it is shown while the
    // main window is still visible. That makes this the one moment where §5's
    // "the display holding the main application window" still has an answer.
    sessionScreen = mainWindowScreen()

    let wasOnScreen = stripPanel?.isVisible ?? false
    // Resolved before the panel exists, so a first show creates the panel at
    // its final size and a later show is a no-op rather than a resize.
    let placed = stripPlacement(placement)
    let panel =
      stripPanel
      ?? makePanel(
        for: engine, contentRect: placed.frame, acceptsMouse: true, movable: true)
    stripPanel = panel
    // Pushed before the panel comes back, so the strip has the corrected
    // snapshot in flight by the time its pixels are on screen again.
    if !lastStripState.isEmpty {
      stripChannel?.invokeMethod("controlStripState", arguments: lastStripState)
    }
    place(panel, at: placed.frame)
    rememberStripPosition(of: placed.frame, on: placed.screen)
    announceOverlayWindow(panel, wasOnScreen: wasOnScreen)
    // From here until the strip goes away, something on screen is draggable —
    // so the last left-button event has to be current when a drag is asked for.
    beginLeftMouseWatch()
  }

  /// Where the strip is now, as the fraction the contract stores (§33.3).
  ///
  /// Null when no strip is on screen, or when its display cannot be named. The
  /// application keeps whatever it had stored in that case: failing to read a
  /// position is not the user having dragged the strip back.
  func controlStripPosition() -> [String: Any]? {
    guard let panel = stripPanel, panel.isVisible,
      let screen = screenHoldingCenter(of: panel.frame) ?? panel.screen,
      let id = displayId(of: screen),
      let ratio = OverlayPlacementGeometry.positionRatio(
        of: panel.frame, inVisibleFrame: screen.visibleFrame, displayId: id)
    else { return nil }
    return [
      "displayId": ratio.displayId, "x": Double(ratio.x), "y": Double(ratio.y),
    ]
  }

  func hideControlStrip() {
    // The sheet closes with the session, and with the window it is anchored to
    // (§33.7).
    dismissInputMenu()
    // Nothing is draggable once the strip is gone: the preview goes with it.
    endLeftMouseWatch()
    // A drag that was still outstanding has nothing left to settle: the window
    // it belonged to is going away, and the position it would persist is the
    // one the session already read.
    if let panel = stripPanel { endDragWatch(for: panel) }
    stripPanel?.orderOut(nil)
    // The strip's engine, its widget and its last rendered frame all outlive the
    // session, so forgetting the snapshot here is not enough: nothing would then
    // tell the strip to change and it would keep showing the frame it stopped
    // on — the one where Stop had already been pressed, with a frozen clock and
    // a dead Pause and Stop — for the whole of the next session's start.
    // Rewinding the session-scoped fields instead makes the re-push on the next
    // show an actual reset. The input flags are left alone: they are the user's
    // settings, and the session's first real push corrects them anyway.
    guard !lastStripState.isEmpty else { return }
    lastStripState["isStopping"] = false
    lastStripState["isPaused"] = false
    lastStripState["elapsedMs"] = 0
  }

  func updateControlStrip(_ state: [String: Any]) {
    lastStripState = state
    stripChannel?.invokeMethod("controlStripState", arguments: state)
  }

  // MARK: - camera preview

  func showCameraPreview(
    placement: [String: Any],
    configuration: CameraOverlayConfiguration?,
    matchesCompositedPip: Bool,
    mirrored: Bool,
    source: CameraTileSource
  ) {
    let engine = previewEngine ?? makeEngine(name: "relay.cameraPreview", entrypoint: "cameraPreviewMain")
    previewEngine = engine
    if previewChannel == nil {
      previewChannel = makeViewChannel(for: engine) { [weak self] call, result in
        self?.handleViewCall(call, result: result, from: .cameraPreview)
      }
    }
    if previewTextureId == nil, let provider = cameraFrameProvider {
      previewTextureId = engine.register(
        CameraPreviewTexture(provider: provider))
    }

    previewOverlay = configuration
    previewSource = source
    previewMatchesPip = matchesCompositedPip

    let wasOnScreen = previewPanel?.isVisible ?? false
    // What the preview has to *draw*, and the window that carries it. In
    // display mode the two differ: the window is sized for every preset at once
    // and never resized, and the tile is a rectangle inside it (§33.5,
    // `previewWindowFrame`). In window mode the preview is a captioned object
    // in its own right (design `1e`) and the placement is the whole of it.
    let content =
      compositedTileFrame()
      ?? self.frame(for: placement, defaultSize: NSSize(width: 200, height: 140))
    let window = previewWindowFrame(holding: content)
    // Interactive in both modes, and non-activating in both: the preview is
    // dragged by hand (§33.5), and opening or moving it must never take key
    // focus from the application being recorded.
    let panel =
      previewPanel
      ?? makePanel(
        for: engine, contentRect: window, acceptsMouse: true, movable: true)
    previewPanel = panel
    place(panel, at: window)
    rememberPreviewContent(content, in: panel)
    announceOverlayWindow(panel, wasOnScreen: wasOnScreen)

    // Armed only once the panel is on screen. The signal drives the preview
    // engine's raster thread, and there is nothing for it to draw into until
    // the window exists.
    if let previewTextureId {
      previewSignalLock.lock()
      previewSignal = (engine: engine, textureId: previewTextureId)
      previewSignalLock.unlock()
    }

    // The crop and the mask travel with the shape, because the preview has to
    // draw what the compositor draws: design `1p` promises they are the same
    // object, and a circle on screen with a square in the file is the defect
    // that promise exists to prevent (§33.5). In window mode the tile is still
    // composited into the file with the same preset, so the shape travels there
    // too — applied to the picture inside the captioned panel rather than to
    // the panel itself, which stays a rectangle with its caption (design `1e`).
    //
    // Two aspect ratios, deliberately: `aspectRatio` is the shape of the
    // *texture* being pushed, and `pipAspectRatio` the shape of the *box* the
    // picture is drawn into. They are equal in display mode, where the window
    // is the tile; in window mode the texture is the whole camera frame and the
    // box is the tile's — 1:1 for Square and Circle.
    let presentation = CameraPreviewPresentation.resolve(
      configuration: configuration)
    lastPreviewState = [
      "textureId": previewTextureId as Any,
      "mirrored": mirrored,
      "matchesCompositedPip": matchesCompositedPip,
      "aspectRatio": source.aspectRatio,
      "pipAspectRatio": configuration?.effectiveAspectRatio(
        sourceAspectRatio: source.aspectRatio) ?? source.aspectRatio,
      "fit": presentation.fit.rawValue,
      "cornerRadiusRatio": presentation.cornerRadiusRatio,
    ]
    applyPreviewContentRect()
    previewChannel?.invokeMethod("cameraPreviewState", arguments: lastPreviewState)
  }

  func hideCameraPreview() {
    if let panel = previewPanel { endDragWatch(for: panel) }
    previewPanel?.orderOut(nil)
    previewOverlay = nil
    previewMatchesPip = false
    previewContentRect = nil
    // Disarmed with the window. The camera capture queue calls
    // `markCameraFrameAvailable()` for every frame it receives, and a texture
    // marked dirty makes the preview engine schedule a frame — into a panel
    // that is no longer on screen. Nothing can see the result, and the engine
    // is left rasterizing for a session that has ended.
    previewSignalLock.lock()
    previewSignal = nil
    previewSignalLock.unlock()
    lastPreviewState = [:]
  }

  /// Re-places the preview and re-pushes its snapshot after the tile changed.
  ///
  /// Three things reach here: a preset or position the application applied, a
  /// drag this side settled, and a camera swapped for one of another shape. All
  /// three move the picture-in-picture, and in display mode the preview *is*
  /// the picture-in-picture (design `1p`).
  func updateCameraPreview(
    configuration: CameraOverlayConfiguration?, source: CameraTileSource
  ) {
    if let configuration { previewOverlay = configuration }
    previewSource = source
    guard let panel = previewPanel, panel.isVisible else { return }
    if let content = compositedTileFrame() {
      // A `move`, not a `place`: the window was sized for every preset at once
      // when it was shown, so a preset, a swap or a re-place changes only which
      // rectangle inside it the tile occupies. That is the whole point — this
      // call used to resize the panel on every press, which is the A → B → A a
      // hosted `FlutterView` can be handed the wrong surface for (§33.5,
      // flutter/flutter#185394).
      move(panel, to: previewWindowFrame(holding: content))
      rememberPreviewContent(content, in: panel)
    }
    guard !lastPreviewState.isEmpty else { return }
    // Through the same rule the first push took: a window-mode preview is not
    // the tile (design `1e`), so a preset chosen for the file must not crop or
    // mask the captioned window that stands for it (§33.5).
    let presentation = CameraPreviewPresentation.resolve(
      configuration: previewOverlay)
    lastPreviewState["mirrored"] = previewOverlay?.mirrorPreview ?? true
    lastPreviewState["aspectRatio"] = source.aspectRatio
    lastPreviewState["pipAspectRatio"] =
      previewOverlay?.effectiveAspectRatio(sourceAspectRatio: source.aspectRatio)
      ?? source.aspectRatio
    lastPreviewState["fit"] = presentation.fit.rawValue
    lastPreviewState["cornerRadiusRatio"] = presentation.cornerRadiusRatio
    applyPreviewContentRect()
    previewChannel?.invokeMethod("cameraPreviewState", arguments: lastPreviewState)
  }

  /// The window that carries a preview drawing `content`.
  ///
  /// Sized once, to what every preset needs, and moved from then on. In window
  /// mode the preview *is* its window, so the content is the frame and nothing
  /// is added around it (design `1e`).
  private func previewWindowFrame(holding content: NSRect) -> NSRect {
    guard let overlay = resolvedTileOverlay() else { return content }
    let canvas = currentScreen().frame
    guard canvas.width > 0, canvas.height > 0 else { return content }
    let size = overlay.boundingTileSize(
      canvasWidth: canvas.width, canvasHeight: canvas.height,
      encoderCanvasWidth: previewSource.canvasWidth,
      sourceAspectRatio: previewSource.aspectRatio,
      sourceWidth: previewSource.pixelWidth)
    guard OverlayPlacementGeometry.isDrawable(size) else { return content }
    return OverlayPlacementGeometry.previewWindowFrame(
      tile: content, size: size, inDisplayFrame: canvas)
  }

  /// Records where the tile sits inside the window that was actually applied.
  ///
  /// The panel's own frame, not the one that was requested: the no-shrink rule
  /// may hold a panel larger than the request, and the tile has to be drawn
  /// where it really is rather than where the request would have put it.
  private func rememberPreviewContent(_ content: NSRect, in panel: NSPanel) {
    previewContentRect = OverlayPlacementGeometry.contentRect(
      of: content, inWindow: panel.frame)
  }

  /// Puts the content rectangle into the snapshot the preview engine draws.
  ///
  /// Always present once there is one, in both modes: the window can be larger
  /// than the picture in either, and a preview that assumed it filled its
  /// window would stretch the tile across the transparent surplus — a tile on
  /// screen that is not the tile in the file, which is the disagreement design
  /// `1p` exists to forbid.
  private func applyPreviewContentRect() {
    guard let rect = previewContentRect else { return }
    lastPreviewState["contentX"] = Double(rect.minX)
    lastPreviewState["contentY"] = Double(rect.minY)
    lastPreviewState["contentWidth"] = Double(rect.width)
    lastPreviewState["contentHeight"] = Double(rect.height)
  }

  /// Where the preview is now, as a fraction of the canvas (§33.5).
  ///
  /// Nil in window mode, where the preview is a separate captioned object that
  /// is deliberately not the tile (design `1e`) — dragging it there moves the
  /// preview and nothing else — and nil when there is no preview to read.
  func cameraPreviewPosition() -> [String: Any]? {
    guard previewMatchesPip, let tile = previewTileFrame() else { return nil }
    let canvas = currentScreen().frame
    guard canvas.width > 0, canvas.height > 0 else { return nil }
    let ratio = canvasPosition(of: tile, in: canvas)
    return ["x": Double(ratio.x), "y": Double(ratio.y)]
  }

  /// The tile's own rectangle on screen, which is no longer the window's.
  ///
  /// The window is sized for every preset at once and the tile is drawn inside
  /// it, so the two differ by however much surplus that preset leaves. Reading
  /// `panel.frame` here reported the surplus as part of the tile: a drag would
  /// have settled the picture-in-picture somewhere the user did not drop it.
  private func previewTileFrame() -> NSRect? {
    guard let panel = previewPanel, panel.isVisible else { return nil }
    guard let content = previewContentRect else { return panel.frame }
    return NSRect(
      x: panel.frame.minX + content.minX,
      y: panel.frame.maxY - content.minY - content.height,
      width: content.width, height: content.height)
  }

  /// The composited tile, as a window frame on the session's display.
  ///
  /// Dart resolves the tile from the configured *fallback* shape and at the
  /// configured width, because only this side knows what the camera actually
  /// produces — its shape, and the pixels the `camera` preset's cap is measured
  /// against. So in display mode the rectangle is resolved here rather than
  /// taken from the placement, from the same `CameraOverlayConfiguration.rect`
  /// the compositor uses. A window that disagreed with the compositor by even a
  /// few points would make the preview a promise the file does not keep.
  ///
  /// Nil in window mode, where the placement Dart sent stands as it is.
  private func compositedTileFrame() -> NSRect? {
    guard let overlay = resolvedTileOverlay() else { return nil }
    let canvas = currentScreen().frame
    guard canvas.width > 0, canvas.height > 0 else { return nil }
    let rect = overlay.rect(
      canvasWidth: canvas.width, canvasHeight: canvas.height,
      sourceAspectRatio: previewSource.aspectRatio)
    return OverlayPlacementGeometry.absoluteFrame(rect, inDisplayFrame: canvas)
  }

  /// The tile with the width this camera actually gets, or nil where the
  /// preview is not the tile.
  ///
  /// The cap is resolved against the *encoder* canvas, where the sensor's
  /// pixels are the thing being compared; the rectangle is then resolved
  /// against the display, which is measured in points. Two canvases, one for
  /// each question.
  private func resolvedTileOverlay() -> CameraOverlayConfiguration? {
    guard previewMatchesPip, let overlay = previewOverlay else { return nil }
    guard previewSource.canvasWidth > 0 else { return overlay }
    return overlay.resolvedForCamera(
      canvasWidth: previewSource.canvasWidth, sourceWidth: previewSource.pixelWidth)
  }

  /// A window frame as the canvas fraction the contract stores.
  ///
  /// The canvas is the whole display: Dart places the tile against the
  /// display's logical size, and `absoluteFrame` maps that onto the screen, so
  /// the inverse is the same map read backwards. Top-left, AppKit being
  /// bottom-left.
  private func canvasPosition(of frame: NSRect, in canvas: NSRect) -> CGPoint {
    CameraOverlayConfiguration.positionRatio(
      left: Double(frame.minX - canvas.minX),
      top: Double(canvas.maxY - frame.maxY),
      canvasWidth: Double(canvas.width), canvasHeight: Double(canvas.height))
  }

  /// Hands a preview drag to AppKit's own window-drag loop (§33.5).
  ///
  /// The same one-call gesture the strip uses and for the same reasons, settled
  /// by different rules: the tile is clamped to the canvas' margin and snaps to
  /// a canvas corner, which is `CameraOverlayConfiguration.rect` — the
  /// arithmetic Dart and Windows share — and not the strip's usable-area rules.
  private func beginPreviewMove() {
    guard let panel = previewPanel, panel.isVisible else { return }
    // The same event source and the same rejection rule as `beginStripMove`,
    // which this used to differ from in both. It also used to dismiss the sheet
    // *before* the guard, so a dropped preview drag closed the sheet while a
    // dropped strip drag did not.
    guard let event = liveDragEvent() else {
      let rejected = lastLeftMouseEvent.map { String(describing: $0.type) } ?? "none"
      overlayLog.error(
        "beginPreviewMove dropped: last left-button event is \(rejected, privacy: .public)")
      return
    }
    // The click that started this is outside the sheet, whatever else it is.
    dismissInputMenu()
    panel.performDrag(with: event)
    // At the end of the drag, not at the start of it — see `beginStripMove`.
    // Here the cost of settling early was worse than a stale position: the
    // preview *is* the picture-in-picture in display mode, and
    // `settlePreviewAfterMove` reports where it landed to the compositor. Run
    // at drag start it reported the tile's position *before* the drag, so the
    // file did not follow the user's drop.
    watchForDragEnd(of: panel) { [weak self] in
      self?.settlePreviewAfterMove(panel)
    }
  }

  /// Clamps and snaps wherever the drag left the preview, and says where.
  ///
  /// In display mode that is the tile's own arithmetic, so the window lands
  /// exactly where the compositor will draw the picture-in-picture. In window
  /// mode the preview is not the tile (design `1e`) and only the display's
  /// usable area constrains it.
  private func settlePreviewAfterMove(_ panel: NSPanel) {
    guard let overlay = resolvedTileOverlay() else {
      // Window mode. Nothing is snapped, because there is no tile to snap to;
      // it is still pulled back onto the usable area, which is the one rule a
      // window with no visible edge to stop it needs.
      let screen =
        screenHoldingCenter(of: panel.frame) ?? panel.screen ?? currentScreen()
      move(
        panel,
        to: OverlayPlacementGeometry.clamped(
          panel.frame, inVisibleFrame: screen.visibleFrame))
      return
    }
    let canvas = currentScreen().frame
    guard canvas.width > 0, canvas.height > 0 else { return }
    // Where the *tile* was dropped. AppKit's drag loop moved the window, and
    // the window is larger than the tile by however much surplus this preset
    // leaves — so the tile is the window's new origin plus the offset the last
    // placement recorded, and reading the window's own frame here would settle
    // the picture-in-picture somewhere the user did not drop it.
    guard let dragged = previewTileFrame() else { return }
    let dropped = canvasPosition(of: dragged, in: canvas)
    let settled = overlay.moved(to: dropped).rect(
      canvasWidth: canvas.width, canvasHeight: canvas.height,
      sourceAspectRatio: previewSource.aspectRatio)
    let content = OverlayPlacementGeometry.absoluteFrame(
      settled, inDisplayFrame: canvas)
    move(panel, to: previewWindowFrame(holding: content))
    rememberPreviewContent(content, in: panel)
    // The tile moved inside the window, so the engine drawing it has to be told
    // where it is now — the same push a preset change makes.
    if !lastPreviewState.isEmpty {
      applyPreviewContentRect()
      previewChannel?.invokeMethod(
        "cameraPreviewState", arguments: lastPreviewState)
    }
    // Read back off the settled rectangle rather than off the drop, so what is
    // reported is where the tile actually is once the margin and the corner
    // snap have had their say.
    let landed = CameraOverlayConfiguration.positionRatio(
      left: Double(settled.minX), top: Double(settled.minY),
      canvasWidth: Double(canvas.width), canvasHeight: Double(canvas.height))
    // Stored on the configuration as Dart sent it: only the position moved.
    previewOverlay = previewOverlay?.moved(to: landed)
    onCameraPreviewMoved?(landed)
  }

  /// Marks the preview texture dirty. Called from the camera capture queue.
  func markCameraFrameAvailable() {
    previewSignalLock.lock()
    let signal = previewSignal
    previewSignalLock.unlock()
    guard let signal else { return }
    signal.engine.textureFrameAvailable(signal.textureId)
  }

  // MARK: - input menu (§33.4)

  /// Opens the device list under the chevron that asked for it.
  ///
  /// Its own panel, not part of the strip: the strip keeps one size in every
  /// session state (§6), and a list inside it would resize an always-on-top
  /// window during the very click that opened it. Non-activating and excluded
  /// from capture on exactly the terms the other two panels are.
  ///
  /// One menu at a time — showing it again replaces whatever was open, which
  /// falls out of there being a single panel and a single state.
  func showInputMenu(placement: [String: Any], state: [String: Any]) {
    // Anchored to the strip, so without one there is nothing to anchor to.
    guard let strip = stripPanel, strip.isVisible else { return }

    let engine =
      menuEngine ?? makeEngine(name: "relay.inputMenu", entrypoint: "inputMenuMain")
    menuEngine = engine
    if menuChannel == nil {
      menuChannel = makeViewChannel(for: engine) { [weak self] call, result in
        self?.handleViewCall(call, result: result, from: .inputMenu)
      }
    }

    // Remembered before the window is placed, because from this moment on any
    // close this side decides on has to name the input it belonged to (§33.4).
    // A state that names no kind leaves it nil, and a dismissal is then not
    // reported at all rather than reported against the wrong chevron.
    openMenuKind = MediaDeviceKind(name: state["kind"] as? String)

    menuGap = placement["margin"] as? Double ?? menuGap
    // A remembered measurement, per *shape* of sheet.
    //
    // The strip's rule — a measurement always wins — was rejected here on the
    // grounds that a menu's content changes on every show, so last time's
    // height would be the wrong one for this list. That reasoning is right and
    // the conclusion was wrong: the answer is to remember a height per content
    // shape, not to give up remembering. Opening at an estimate and correcting
    // to the measurement drives the panel through two sizes, and a panel driven
    // back to a size it recently left can be handed a surface of the other size
    // out of the engine's back-buffer cache — a render target with no colour
    // attachment, and a null texture read on the raster thread
    // (flutter/flutter#185394). That is a hard crash, and this project has
    // taken it. `docs/adr/2026-08-24-overlay-panels-are-sized-once-per-show.md`
    // records the same fault on the strip.
    //
    // So the first sheet of a given shape is still corrected once; every later
    // one of that shape opens at the size that correction produced, and the
    // correction becomes a no-op.
    menuContentKey = Self.contentKey(of: state)
    let size = OverlayPlacementGeometry.effectiveSize(
      requested: NSSize(
        width: placement["width"] as? Double ?? 268,
        height: placement["height"] as? Double ?? 120),
      measured: menuContentKey.flatMap { menuMeasuredSizes[$0] })
    let wasOnScreen = menuPanel?.isVisible ?? false
    let frame = menuFrame(size: size, strip: strip)
    let panel =
      menuPanel ?? makePanel(for: engine, contentRect: frame, acceptsMouse: true)
    menuPanel = panel
    // Pushed before the panel comes back, so the list is in flight by the time
    // its pixels are on screen. A push that beats the engine's own handler is
    // held in Flutter's channel buffer and delivered when it registers, which
    // is what the strip's first push has always relied on.
    menuChannel?.invokeMethod("inputMenuState", arguments: state)
    place(panel, at: frame)
    // The sheet is created lazily, on the first chevron pressed in a session,
    // which is always after `prepare` built the capture filter — so this is the
    // announcement §6's exclusion list depends on most. A menu that appears in
    // a recording is the one unacceptable outcome.
    announceOverlayWindow(panel, wasOnScreen: wasOnScreen)
    beginMenuDismissWatch()
  }

  /// Re-renders an open menu in place.
  ///
  /// A device that appears or disappears re-renders the list rather than
  /// closing the sheet, and the fallback is shown selected (§33.7). A push with
  /// no menu on screen is dropped: it would otherwise raise one nobody asked
  /// for.
  func updateInputMenu(_ state: [String: Any]) {
    guard let panel = menuPanel, panel.isVisible else { return }
    // The key follows the state, not the show. A sheet changes shape in place
    // on the way up — shown loading, then with its devices, then with a level —
    // so a key fixed at `showInputMenu` filed the loaded sheet's height under
    // the loading sheet's name, and the next loading sheet then opened at the
    // loaded height. The ledger is no longer what stands between this window
    // and a crash (`apply` is), but a ledger that lies is worse than none: it
    // is what decides the first, visible size of every sheet.
    menuContentKey = Self.contentKey(of: state)
    menuChannel?.invokeMethod("inputMenuState", arguments: state)
  }

  /// The shape of a sheet, for the size ledger.
  private static func contentKey(of state: [String: Any]) -> String {
    OverlayPlacementGeometry.menuContentKey(
      kind: state["kind"] as? String,
      rowCount: (state["items"] as? [Any])?.count ?? 0,
      loading: state["loading"] as? Bool ?? false,
      hasLevel: state["level"] != nil && !(state["level"] is NSNull),
      hasNotice: state["notice"] != nil && !(state["notice"] is NSNull),
      presetCount: (state["presets"] as? [Any])?.count ?? 0,
      cornerCount: (state["corners"] as? [Any])?.count ?? 0)
  }

  /// Closes the menu because the application asked it to. Idempotent.
  ///
  /// Silent by design: the application already knows about this one, and an
  /// echo would be read as a second event about a window it has already
  /// forgotten (§33.4).
  func hideInputMenu() {
    closeInputMenu(reportingDismissal: false)
  }

  /// Closes the menu because *this side* decided to, and says so (§33.4).
  ///
  /// The click outside, Esc, the strip being dragged or nudged, a display
  /// configuration change, the session ending: none of them are the
  /// application's `hideInputMenu`, and the application is what draws the
  /// chevron. Left unreported, it goes on believing the sheet is open, and the
  /// next press on that chevron is read as the toggle that closes an
  /// already-closed window — the user presses twice to reopen a menu that is
  /// not there.
  private func dismissInputMenu() {
    closeInputMenu(reportingDismissal: true)
  }

  /// The one path every close takes. Idempotent.
  private func closeInputMenu(reportingDismissal: Bool) {
    endMenuDismissWatch()
    menuAnchorX = nil
    let kind = openMenuKind
    openMenuKind = nil
    guard let panel = menuPanel, panel.isVisible else { return }
    panel.orderOut(nil)
    // Reported only for a window that was actually open, and only when it can
    // be named: a dismissal that named no input would tell the application to
    // forget a chevron it would have to guess at.
    guard reportingDismissal, let kind else { return }
    // No device and no `off`: a dismissal applies nothing, and the shape of the
    // map is what says so (`docs/architecture/platform-channel-contract.md`).
    onMenuSelection?(["kind": kind.rawValue, "dismissed": true])
  }

  /// Where the menu goes, resolved against the strip it belongs to.
  ///
  /// The display is the one holding the strip's centre — the strip may have
  /// been dragged onto another display, and the menu follows the window it is
  /// anchored to rather than §5's current display.
  private func menuFrame(size: NSSize, strip: NSPanel) -> NSRect {
    let screen =
      screenHoldingCenter(of: strip.frame) ?? strip.screen ?? currentScreen()
    return OverlayPlacementGeometry.inputMenuFrame(
      size: size, anchorX: menuAnchorX, stripFrame: strip.frame, gap: menuGap,
      inVisibleFrame: screen.visibleFrame)
  }

  /// Remembers where the control that raised a command sits, in screen
  /// coordinates.
  ///
  /// A command that names no control clears it, so the next menu centres on the
  /// strip instead of appearing under whichever chevron was pressed last.
  private func rememberMenuAnchor(_ anchorX: Double?) {
    guard let anchorX, anchorX.isFinite, let strip = stripPanel else {
      menuAnchorX = nil
      return
    }
    menuAnchorX = strip.frame.minX + CGFloat(anchorX)
  }

  /// Applies the menu's own measurement, on a later main-loop turn.
  ///
  /// The reasoning is `scheduleStripResize`'s exactly — resizing a window that
  /// hosts a Flutter view inside the channel handler that engine just called
  /// would stall the application on its own next frame — with one addition: the
  /// menu is re-placed as well as resized, because a taller list may no longer
  /// fit under the strip and has to flip above it (§33.7).
  private func scheduleMenuResize(to size: NSSize) {
    // Recorded whether or not the panel is resized: this is the height a sheet
    // of this shape measures, and the next one of that shape opens at it rather
    // than being corrected into it.
    if let key = menuContentKey {
      menuMeasuredSizes[key] = size
    }
    guard pendingMenuSize == nil else {
      pendingMenuSize = size
      return
    }
    pendingMenuSize = size
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let target = self.pendingMenuSize
      self.pendingMenuSize = nil
      guard let target, let panel = self.menuPanel, panel.isVisible,
        let strip = self.stripPanel
      else { return }
      let frame = self.menuFrame(size: target, strip: strip)
      let applied = self.apply(panel, frame: frame)
      guard applied != panel.frame else { return }
      panel.setFrame(applied, display: true)
    }
  }

  /// Watches for the two dismissals the menu cannot see itself (§33.4).
  ///
  /// A non-activating panel is never told that the user went somewhere else, so
  /// a click outside has to be observed. Mouse monitors need no accessibility
  /// grant; a *global* keyboard monitor does, so Esc is watched locally and
  /// therefore only while Relay is the active application — which is why the
  /// click outside is the gesture that always works.
  ///
  /// A monitor observes and does not consume: the click that closes the menu
  /// still reaches whatever is under it. Swallowing it would take an invisible
  /// window over the whole display, which is a click-eating surface laid over
  /// the very application being recorded.
  private func beginMenuDismissWatch() {
    guard menuDismissMonitors.isEmpty else { return }
    let mouse: NSEvent.EventTypeMask = [
      .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]
    if let global = NSEvent.addGlobalMonitorForEvents(matching: mouse, handler: {
      [weak self] _ in self?.dismissInputMenu()
    }) {
      menuDismissMonitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: mouse.union(.keyDown),
      handler: { [weak self] event in
        guard let self, let panel = self.menuPanel, panel.isVisible else {
          return event
        }
        if event.type == .keyDown {
          // Esc by key code: a panel that never becomes key produces no
          // characters to compare.
          if event.keyCode == 53 { self.dismissInputMenu() }
          return event
        }
        // The strip is not "outside": it is the sheet's own window furniture,
        // and the chevron on it has to be able to close what it opened.
        if OverlayPlacementGeometry.menuDismissal(
          forEventWindow: event.window.map(ObjectIdentifier.init),
          menu: ObjectIdentifier(panel),
          strip: self.stripPanel.map(ObjectIdentifier.init))
        {
          self.dismissInputMenu()
        }
        return event
      })
    {
      menuDismissMonitors.append(local)
    }
  }

  private func endMenuDismissWatch() {
    for monitor in menuDismissMonitors {
      NSEvent.removeMonitor(monitor)
    }
    menuDismissMonitors.removeAll()
  }

  // MARK: - main window

  func setMainWindowVisible(_ visible: Bool) {
    // The suppression is raised *before* the window goes away: AppKit asks the
    // delegate as part of `orderOut`, so a hold taken afterwards would arrive
    // one termination too late.
    if visible {
      RecorderWindowPolicy.reset()
      // The session is over, so the display it was pinned to stops being the
      // answer; the next one resolves the main window's display again.
      sessionScreen = nil
    } else {
      RecorderWindowPolicy.suppressTermination()
    }
    for window in NSApplication.shared.windows where !(window is NSPanel) {
      if visible {
        window.makeKeyAndOrderFront(nil)
      } else {
        window.orderOut(nil)
      }
    }
    if visible {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }

  // MARK: - plumbing

  private func makeEngine(name: String, entrypoint: String) -> FlutterEngine {
    let engine = FlutterEngine(
      name: name, project: FlutterDartProject(), allowHeadlessExecution: true)
    engine.run(withEntrypoint: entrypoint)
    return engine
  }

  private func makeViewChannel(
    for engine: FlutterEngine,
    handler: @escaping FlutterMethodCallHandler
  ) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(
      name: "relay/overlay/view", binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler(handler)
    return channel
  }

  /// Which overlay window a `relay/overlay/view` call came from.
  ///
  /// The channel name is one string shared by all three engines, so the call
  /// itself cannot say: the answer is which handler was installed on which
  /// engine, and it is passed down from there.
  private enum OverlaySurface {
    case controlStrip
    case cameraPreview
    case inputMenu
  }

  private func handleViewCall(
    _ call: FlutterMethodCall, result: @escaping FlutterResult,
    from surface: OverlaySurface
  ) {
    switch call.method {
    case "command":
      if let arguments = call.arguments as? [String: Any],
        let command = arguments["command"] as? String
      {
        // Where the pressed control sits travels with the command, because only
        // this call knows which window raised it (§33.4).
        if surface == .controlStrip {
          rememberMenuAnchor(arguments["anchorX"] as? Double)
        }
        onCommand?(command)
      }
      result(nil)
    case "beginMove":
      // Replied before the drag rather than after it: the drag loop below runs
      // for the whole gesture, and the caller waiting on this reply is the very
      // engine whose frames the window needs while it is being dragged.
      result(nil)
      switch surface {
      case .controlStrip: beginStripMove()
      case .cameraPreview: beginPreviewMove()
      case .inputMenu: break
      }
    case "contentSize":
      if let arguments = call.arguments as? [String: Any],
        let width = arguments["width"] as? Double,
        let height = arguments["height"] as? Double,
        OverlayPlacementGeometry.isDrawable(CGSize(width: width, height: height))
      {
        let size = NSSize(width: width, height: height)
        switch surface {
        case .controlStrip: scheduleStripResize(to: size)
        case .inputMenu: scheduleMenuResize(to: size)
        // The preview's size is the tile's, and the tile is geometry, not
        // something its content measures.
        case .cameraPreview: break
        }
      }
      result(nil)
    case "chooseInputDevice":
      // Every choice the sheet raises, on one call: a device row, and the
      // camera sheet's shape presets and corners. The choice reaches
      // the application on the events channel as a map — beside the bare
      // command names that channel already emits, which is how Dart tells the
      // two apart (§33.4).
      result(nil)
      if surface == .inputMenu, let arguments = call.arguments as? [String: Any],
        let kind = arguments["kind"] as? String
      {
        let deviceId = arguments["deviceId"] as? String
        let preset = arguments["preset"] as? String
        let corner = arguments["corner"] as? String
        // A shape preset and a corner leave the sheet where it is: the tile
        // changes on screen underneath it, and comparing the choices should not
        // cost a reopen each time (§33.5). Only a device row — `off` included —
        // closes it, and that close is not a dismissal: the map below is the
        // report the application gets, so a `dismissed` beside it would be the
        // same event told twice.
        if preset == nil, corner == nil {
          hideInputMenu()
        }
        // Read through rather than rebuilt from the fields this build happens
        // to know: the shapes are decoded on the Dart side, and a host that
        // reconstructed only the ones it recognises would silently drop the
        // next one the sheet grows.
        onMenuSelection?([
          "kind": kind,
          "deviceId": deviceId as Any,
          "off": arguments["off"] as? Bool ?? false,
          "dismissed": false,
          "preset": preset as Any,
          "corner": corner as Any,
        ])
      }
    case "dismissInputMenu":
      // Esc, or a click the menu itself saw as outside. The application did not
      // ask for this one and it is what draws the chevron, so the window is
      // closed *and* the dismissal reported — otherwise the application goes on
      // believing the sheet is open and the next press on that chevron is read
      // as the one that closes it (§33.4).
      result(nil)
      if surface == .inputMenu {
        dismissInputMenu()
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func makePanel(
    for engine: FlutterEngine, contentRect: NSRect, acceptsMouse: Bool,
    movable: Bool = false
  ) -> NSPanel {
    let controller = FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    // Sized before it is installed, not after. `contentViewController` resizes
    // the window to the controller's view, and a `FlutterView` starts at
    // `NSZeroRect` — so a panel built with the right `contentRect` came back
    // 0 × 0 anyway, and the placement below then resized it, off screen, from
    // nothing to its real size. That is the same two-sizes-in-one-turn shape
    // this file exists to remove, with the worse of the two sizes being the
    // degenerate one a drawable cannot be created for.
    controller.view.frame = NSRect(origin: .zero, size: contentRect.size)
    // The panel below is `isOpaque = false` with a clear background, but that
    // only makes the *window* transparent: a `FlutterView` defaults to opaque
    // black, so a Dart tree that paints nothing behind its content would show
    // black rather than the screen. All three overlays paint their own ground
    // where they want one — the strip and the input menu fill themselves, and
    // the display-mode camera preview deliberately does not, because it is the
    // composited tile and the compositor leaves everything outside the tile
    // untouched (§33.5, design `1p`).
    controller.backgroundColor = .clear
    let panel = NSPanel(
      contentRect: contentRect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.contentViewController = controller
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    // `performDrag(with:)` does nothing on a window AppKit considers immovable,
    // so both the strip (§33.3) and the display-mode camera preview (§33.5) are
    // built movable; the input menu is not, and never asks.
    // `isMovableByWindowBackground` is left off in every case: the only drag is
    // the one the window's own Dart side asks for once its 4 px threshold is
    // crossed, and AppKit's background drag would start one under it without
    // that threshold, eating slow clicks on the controls.
    panel.isMovable = movable
    panel.isMovableByWindowBackground = false
    panel.ignoresMouseEvents = !acceptsMouse
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    // The window-server level exclusion. The content filter's exclusion list is
    // the second, independent mechanism (§6).
    panel.sharingType = .none
    return panel
  }

  /// Brings a panel back at `frame`, never resizing it while it is off screen.
  ///
  /// A resize blocks the platform thread until the panel's engine commits a
  /// frame at the new size, and a window that is not on screen has no drawable
  /// to commit into. When the size genuinely did change, the panel is ordered
  /// front *first* so the commit has somewhere to land.
  private func place(_ panel: NSPanel, at frame: NSRect) {
    let target = apply(panel, frame: frame)
    if OverlayPlacementGeometry.needsResize(from: panel.frame, to: target) {
      panel.orderFrontRegardless()
      panel.setFrame(target, display: true)
    } else if panel.frame.origin != target.origin {
      panel.setFrameOrigin(target.origin)
    }
    panel.orderFrontRegardless()
  }

  /// The one place a panel's size is decided (§33.3, flutter/flutter#185394).
  ///
  /// Every caller that used to reach `setFrame` goes through here, because the
  /// rule it enforces is about a panel's *history* and no single call site can
  /// see that. `OverlayPlacementGeometry.panelSizeAction` holds the reasoning
  /// and the proof; this is the bookkeeping.
  ///
  /// Returns the frame that may actually be applied: the requested origin
  /// always, and a size that never shrinks and never returns to one the panel
  /// has already rendered.
  ///
  /// **Every panel, the camera preview included.** The preview used to be
  /// exempt, because in display mode its window frame *was* the tile rect and
  /// holding it at a high-water size would have drawn a tile that is not the
  /// tile in the file — the disagreement design `1p` exists to forbid. That
  /// exemption is gone: the window is now sized once to what every preset needs
  /// and the tile is drawn as a rectangle inside it
  /// (`OverlayPlacementGeometry.previewWindowFrame`), so a window larger than
  /// the picture is exactly what is wanted and `1p` still holds to the pixel.
  private func apply(_ panel: NSPanel, frame: NSRect) -> NSRect {
    let key = ObjectIdentifier(panel)
    let scale = panel.backingScaleFactor
    let action = OverlayPlacementGeometry.panelSizeAction(
      requested: frame.size,
      highWater: panelHighWaterSizes[key],
      scale: scale,
      renderedScale: panelRenderedScales[key])

    switch action {
    case .move:
      return NSRect(origin: frame.origin, size: panelHighWaterSizes[key] ?? frame.size)
    case .grow(let size):
      panelHighWaterSizes[key] = size
      panelRenderedScales[key] = scale
      return NSRect(origin: frame.origin, size: size)
    case .hold(let size):
      // The panel is left larger than its content asked for. That is the whole
      // trade: a sheet with a little unused room below it, against a raster
      // thread reading a null texture. The Dart side draws its content at its
      // own size inside the window and dismisses on a press in the surplus.
      return NSRect(origin: frame.origin, size: size)
    case .rebuild(let size):
      // The backing scale changed, so the pixel history says nothing about this
      // panel any more. There is no way to rebuild a hosted `FlutterView`
      // without tearing down its engine, which costs more than it saves — so
      // this is recorded rather than acted on, and the size is taken as a fresh
      // start. §0.5 of the crash analysis: closed for sizes we choose,
      // mitigated for sizes the system imposes.
      overlayLog.error(
        "panel crossed a backing-scale boundary: \(size.width, privacy: .public)x\(size.height, privacy: .public) at \(scale, privacy: .public)x"
      )
      panelHighWaterSizes[key] = size
      panelRenderedScales[key] = scale
      return NSRect(origin: frame.origin, size: size)
    }
  }

  /// The largest size each panel has rendered, and the scale it rendered it at.
  ///
  /// Keyed by panel identity and never cleared: the engine's surface cache is
  /// not cleared either, and it is that cache the rule exists to protect.
  private var panelHighWaterSizes: [ObjectIdentifier: NSSize] = [:]
  private var panelRenderedScales: [ObjectIdentifier: CGFloat] = [:]

  /// The control strip's frame and the display it belongs on.
  ///
  /// Its size is resolved exactly once, as ever. The *placement* has two
  /// shapes: the spot the user left it at, as a fraction of one named display's
  /// usable area (§33.3), and the default dock on §5's current display. A
  /// fraction whose display is no longer attached falls back to the dock, so a
  /// placement always resolves — §33.7's "stored display no longer exists" row,
  /// where the stale entry is dropped rather than pointed at.
  private func stripPlacement(_ placement: [String: Any]) -> (
    frame: NSRect, screen: NSScreen
  ) {
    let requested = NSSize(
      width: placement["width"] as? Double ?? 360,
      height: placement["height"] as? Double ?? 46)
    let size = OverlayPlacementGeometry.effectiveSize(
      requested: requested, measured: stripContentSize)

    if let position = placement["position"] as? [String: Any],
      let id = position["displayId"] as? String,
      let x = position["x"] as? Double,
      let y = position["y"] as? Double,
      let screen = screen(withDisplayId: id)
    {
      let frame = OverlayPlacementGeometry.fractionalFrame(
        size: size,
        ratio: OverlayStripRatio(displayId: id, x: CGFloat(x), y: CGFloat(y)),
        inVisibleFrame: screen.visibleFrame)
      return (frame, screen)
    }

    let screen = currentScreen()
    let frame = OverlayPlacementGeometry.anchoredFrame(
      size: size,
      anchor: placement["anchor"] as? String ?? "topCenter",
      margin: placement["margin"] as? Double ?? 6,
      inVisibleFrame: screen.visibleFrame)
    return (frame, screen)
  }

  // MARK: - moving the strip (§33.3)

  /// Hands the gesture to AppKit's own window-drag loop.
  ///
  /// One call rather than a message per pointer move: the operating system
  /// already tracks the pointer at the display's refresh rate and ends the drag
  /// on mouse-up, and `relay/overlay/view` is a command channel (§3).
  ///
  /// **`performDrag(with:)` does not block.** It was written here as though it
  /// did, and on macOS 26 it does not: the call posts a single send-only mach
  /// message to the window server and returns in microseconds — the drag is
  /// tracked server-side and the application learns it ended through a local
  /// event monitor. Settling immediately after it therefore snapped, clamped
  /// and *persisted* the position the strip had before the user moved it, and
  /// wrote a frame into a drag the server was already running.
  ///
  /// So the settle waits for the mouse-up that ends the drag. §33.3's snap and
  /// clamp are about where the strip is **let go**, and until this there was no
  /// moment in the code that corresponded to that.
  /// Keeps [lastLeftMouseEvent] current for as long as an overlay is on screen.
  private func beginLeftMouseWatch() {
    guard leftMouseMonitor == nil else { return }
    leftMouseMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
    ) { [weak self] event in
      self?.lastLeftMouseEvent = event
      return event
    }
  }

  private func endLeftMouseWatch() {
    if let leftMouseMonitor {
      NSEvent.removeMonitor(leftMouseMonitor)
    }
    leftMouseMonitor = nil
    lastLeftMouseEvent = nil
  }

  /// The event a drag should be handed, or nil when the button is not down.
  ///
  /// Rejecting only a `leftMouseUp` is what the guard was always supposed to
  /// mean: a drag begun with nothing held has nothing to end it. Anything else
  /// — a down, a drag — is a live gesture, whatever AppKit happened to dequeue
  /// since.
  private func liveDragEvent() -> NSEvent? {
    guard let event = lastLeftMouseEvent, event.type != .leftMouseUp else {
      return nil
    }
    return event
  }

  private func beginStripMove() {
    guard let panel = stripPanel, panel.isVisible else { return }
    // The strip moving closes the sheet (§33.7). Before the drag, not after
    // it: `performDrag(with:)` blocks for the whole gesture, and a sheet left
    // hanging under a strip that is being dragged away is the state the row
    // exists to forbid.
    dismissInputMenu()
    // A method call can be drained a turn late, by which time the button that
    // started the gesture may already be up. A drag loop begun with nothing
    // held has nothing to end it, so a late call is dropped rather than turned
    // into a strip that follows the pointer with no button down.
    guard let event = liveDragEvent() else {
      // The Dart side latches "a drag was requested" for the whole gesture, so
      // a dropped request reads to the user as a strip that will not move until
      // they release and press again. At `.error` because info-level logging
      // from a third-party subsystem is memory-only and never reaches
      // `log show` — the last report about this arrived with nothing in it.
      let rejected = lastLeftMouseEvent.map { String(describing: $0.type) } ?? "none"
      overlayLog.error("beginMove dropped: last left-button event is \(rejected, privacy: .public)")
      return
    }
    panel.performDrag(with: event)
    watchForDragEnd(of: panel) { [weak self] in
      self?.settleStripAfterMove(panel)
    }
  }

  /// Runs `settle` once, when the drag the window server is running ends.
  ///
  /// A local monitor rather than a notification: `NSWindow.didMoveNotification`
  /// fires on every frame of the drag, and the settle has to happen exactly
  /// once, at the end. AppKit itself ends its own drag on the same event.
  ///
  /// Exactly one watch is outstanding per panel — a second `beginMove` replaces
  /// it rather than stacking, so a gesture that somehow starts twice cannot
  /// settle twice.
  private func watchForDragEnd(of panel: NSPanel, settle: @escaping () -> Void) {
    endDragWatch(for: panel)
    let key = ObjectIdentifier(panel)
    // The same mask AppKit's own drag terminator uses — a window-server drag
    // can end on an `appKitDefined` event rather than a plain mouse-up, and a
    // watch that missed it would never settle *and* would stay installed to
    // fire on the next unrelated click anywhere in the application.
    let monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseUp, .appKitDefined]
    ) { [weak self] event in
      guard let self else { return event }
      // AppKit's own window-drag terminator accepts a plain `leftMouseUp` or
      // an `appKitDefined` of subtype 21 — an undocumented "the window-server
      // drag ended" notification, read out of
      // `-[NSWindow _dragWindowRelativeToMouseDown:options:completionHandler:]`.
      // Any other `appKitDefined` is unrelated and must not end a drag.
      if event.type == .appKitDefined && event.subtype.rawValue != 21 {
        return event
      }
      self.endDragWatch(for: panel)
      // After the monitor is removed, so a settle that somehow raises another
      // mouse-up cannot re-enter this.
      settle()
      return event
    }
    if let monitor {
      dragEndMonitors[key] = monitor
    } else {
      // No monitor, no end-of-drag: settling now is wrong, but never settling
      // at all would leave the strip unclamped and its stored position stale.
      // The immediate settle is what this code did before, so it is the safe
      // fallback rather than a new risk.
      settle()
    }
  }

  private func endDragWatch(for panel: NSPanel) {
    let key = ObjectIdentifier(panel)
    if let monitor = dragEndMonitors.removeValue(forKey: key) {
      NSEvent.removeMonitor(monitor)
    }
  }

  /// Snaps and clamps wherever the drag left the strip.
  ///
  /// The strip belongs to whichever display holds its **centre** when the drag
  /// ends — deliberately not §5's current display, because overriding that
  /// placement is the whole point of being able to drag it.
  private func settleStripAfterMove(_ panel: NSPanel) {
    let screen =
      screenHoldingCenter(of: panel.frame) ?? panel.screen ?? currentScreen()
    let settled = OverlayPlacementGeometry.snapped(
      panel.frame, inVisibleFrame: screen.visibleFrame)
    move(panel, to: settled)
    rememberStripPosition(of: settled, on: screen)
  }

  /// Moves the strip by a keyboard nudge (§33.3).
  ///
  /// The path deferred from the drag, and deliberately the same landing: the
  /// nudged frame is snapped and clamped exactly as a drag end is, so a strip
  /// moved by the arrow keys can reach every spot a dragged one can and no
  /// others.
  func nudgeControlStrip(dx: Double, dy: Double) {
    guard let panel = stripPanel, panel.isVisible else { return }
    dismissInputMenu()
    let screen =
      screenHoldingCenter(of: panel.frame) ?? panel.screen ?? currentScreen()
    let settled = OverlayPlacementGeometry.nudged(
      panel.frame, dx: dx, dy: dy, inVisibleFrame: screen.visibleFrame)
    move(panel, to: settled)
    rememberStripPosition(of: settled, on: screen)
  }

  /// Re-resolves the strip after the display configuration changed (§33.7).
  ///
  /// The *fraction* is re-resolved rather than the pixels re-clamped, which is
  /// what makes one handler cover three rows at once: a resolution or scale
  /// change keeps the strip proportionally where it was, a Dock that appeared
  /// shrinks the usable area under it, and a display that was unplugged leaves
  /// the strip at the same fraction of whichever display it is on now. AppKit
  /// has already relocated the panel by then, so its frame is not the answer.
  private func reclampControlStrip() {
    // A display configuration change closes the sheet: it is placed against a
    // usable area that has just stopped being the one it was placed against
    // (§33.4).
    dismissInputMenu()
    guard let panel = stripPanel, panel.isVisible else { return }
    guard let position = stripPosition else {
      let screen = screenHoldingCenter(of: panel.frame) ?? currentScreen()
      move(
        panel,
        to: OverlayPlacementGeometry.clamped(
          panel.frame, inVisibleFrame: screen.visibleFrame))
      return
    }
    let screen =
      screen(withDisplayId: position.displayId)
      ?? screenHoldingCenter(of: panel.frame) ?? currentScreen()
    let frame = OverlayPlacementGeometry.fractionalFrame(
      size: panel.frame.size, ratio: position,
      inVisibleFrame: screen.visibleFrame)
    move(panel, to: frame)
    // The display may have changed under it, and the fraction is stored against
    // a display.
    rememberStripPosition(of: frame, on: screen)
  }

  /// Records where the strip is, for the next display change to re-resolve.
  ///
  /// A spot that cannot be named leaves the last one alone: a display that
  /// momentarily reports nothing usable is not the user having moved the strip,
  /// which is the same reading the application takes of a null
  /// `controlStripPosition`.
  private func rememberStripPosition(of frame: NSRect, on screen: NSScreen) {
    guard let id = displayId(of: screen),
      let ratio = OverlayPlacementGeometry.positionRatio(
        of: frame, inVisibleFrame: screen.visibleFrame, displayId: id)
    else { return }
    stripPosition = ratio
  }

  /// A move, never a resize — in *points*.
  ///
  /// Moving a window does not recreate its rendering surface, so this costs
  /// nothing of what a resize costs — the distinction this whole file turns on.
  /// The exception is a move that crosses to a display of a different backing
  /// scale: the point size is unchanged and the pixel size is not, which is a
  /// resize as far as the engine's surface cache is concerned. That is why this
  /// goes through `apply` too, rather than trusting its own name.
  private func move(_ panel: NSPanel, to frame: NSRect) {
    let target = apply(panel, frame: frame)
    guard panel.frame != target else { return }
    panel.setFrame(target, display: true)
  }

  /// Resolves the contract's anchored and absolute placements against the
  /// session's display (§5).
  ///
  /// An absolute frame is resolved against the display's **full** frame, an
  /// anchored dock against its **usable** area; `OverlayPlacementGeometry`
  /// carries the reasoning for both, and is where the arithmetic is tested.
  private func frame(for placement: [String: Any], defaultSize: NSSize) -> NSRect {
    let screen = currentScreen()

    if let frame = placement["frame"] as? [String: Any],
      let x = frame["x"] as? Double,
      let y = frame["y"] as? Double,
      let width = frame["width"] as? Double,
      let height = frame["height"] as? Double
    {
      let requested = CGRect(x: x, y: y, width: width, height: height)
      // A degenerate rectangle is a bug upstream, but a window cannot be given
      // one: a zero-sized `FlutterView` has no drawable, and its engine
      // dereferences the surface it did not get. The Windows sibling already
      // clamps here; this side used to write the value straight through.
      if OverlayPlacementGeometry.isPlaceable(requested) {
        return OverlayPlacementGeometry.absoluteFrame(
          requested, inDisplayFrame: screen.frame)
      }
    }

    let size = OverlayPlacementGeometry.effectiveSize(
      requested: NSSize(
        width: placement["width"] as? Double ?? Double(defaultSize.width),
        height: placement["height"] as? Double ?? Double(defaultSize.height)),
      measured: nil)
    return OverlayPlacementGeometry.anchoredFrame(
      size: size,
      anchor: placement["anchor"] as? String ?? "topCenter",
      margin: placement["margin"] as? Double ?? 6,
      inVisibleFrame: screen.visibleFrame)
  }

  /// Applies a measured content size on a later main-loop turn.
  ///
  /// Resizing a window that hosts a Flutter view blocks the platform thread
  /// until that engine commits a frame at the new size. Doing that *inside* the
  /// channel handler the same engine just called would stall the whole
  /// application mid-click — the strip's own message would be waiting on the
  /// strip's own next frame. Coalescing to the next turn keeps the handler
  /// cheap and collapses a burst of measurements into one resize.
  private func scheduleStripResize(to size: NSSize) {
    stripContentSize = size
    guard pendingStripSize == nil else {
      pendingStripSize = size
      return
    }
    pendingStripSize = size
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      let target = self.pendingStripSize
      self.pendingStripSize = nil
      guard let target, let panel = self.stripPanel else { return }
      // A measurement that arrives after the strip has been hidden is kept in
      // `stripContentSize` and applied by the next show, which creates or
      // places the panel at that size directly. Resizing an off-screen window
      // that hosts a rendering surface is the one thing this file exists to
      // avoid.
      guard panel.isVisible else { return }
      self.resizeKeepingTopCenter(panel, to: target)
    }
  }

  /// Grows the strip about its own top centre, kept inside the visible frame.
  private func resizeKeepingTopCenter(_ panel: NSPanel, to size: NSSize) {
    let screen = panel.screen ?? currentScreen()
    let target = OverlayPlacementGeometry.resizedKeepingTopCenter(
      panel.frame, to: size, inVisibleFrame: screen.visibleFrame)
    let applied = apply(panel, frame: target)
    guard OverlayPlacementGeometry.needsResize(from: panel.frame, to: applied)
    else { return }
    panel.setFrame(applied, display: true)
    // Growing about the top centre moves the leading edge, so the remembered
    // fraction is no longer the one the strip is at.
    rememberStripPosition(of: applied, on: screen)
  }

  /// The display this session's overlays belong on.
  ///
  /// Pinned at `showControlStrip` and held for the session; see `sessionScreen`.
  private func currentScreen() -> NSScreen {
    guard let sessionScreen else { return mainWindowScreen() }
    // The pin is honoured by display id, not by object identity: AppKit
    // replaces its `NSScreen` instances whenever the display configuration
    // changes, and a stale one whose display has been unplugged reports an
    // empty `visibleFrame` — a usable area nothing can be placed inside.
    if let id = displayId(of: sessionScreen),
      let live = screen(withDisplayId: id)
    {
      return live
    }
    return mainWindowScreen()
  }

  private func mainWindowScreen() -> NSScreen {
    let window = NSApplication.shared.windows.first { !($0 is NSPanel) && $0.isVisible }
    return window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
  }

  /// The display holding a frame's centre.
  ///
  /// Not `NSWindow.screen`, which reports the display a window *overlaps most*.
  /// That is a different question, and §33.3 asks this one: a strip straddling
  /// two displays belongs to the one under its middle.
  private func screenHoldingCenter(of frame: NSRect) -> NSScreen? {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    return NSScreen.screens.first { $0.frame.contains(center) }
  }

  /// The attached display with this id, or nil once it is no longer attached.
  private func screen(withDisplayId id: String) -> NSScreen? {
    guard !id.isEmpty else { return nil }
    return NSScreen.screens.first { displayId(of: $0) == id }
  }

  /// A display's id, spelled the way the contract already spells display ids.
  ///
  /// The decimal `CGDirectDisplayID` from `NSScreenNumber` — the same string
  /// `CaptureSourceEnumerator.currentDisplayGeometry()` reports as
  /// `DisplayGeometry.id`, and the same number the `display:<n>` capture-source
  /// ids wrap. One spelling, so a stored position names a display the rest of
  /// the contract can already point at.
  private func displayId(of screen: NSScreen) -> String? {
    guard
      let number = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    else { return nil }
    return String(number.uint32Value)
  }
}
