import AppKit
import CoreVideo
import FlutterMacOS
import Foundation
import RecorderCore

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

/// Creates, places and tears down the application's always-on-top windows.
///
/// Every window created here is a separate top-level panel — never a child of
/// a captured window — is marked `sharingType = .none`, and is reported from
/// `excludedWindowIDs` so it also reaches the capture filter's exclusion list.
/// With a display source, that exclusion is the only thing keeping these
/// surfaces out of the file (§6).
///
/// **One size per show.** A panel hosting a `FlutterView` blocks the platform
/// thread on every resize until that engine's raster thread commits a frame at
/// the new size, so each distinct size a panel is driven through is a real
/// rendered frame. Sizes are therefore resolved once, in
/// `OverlayPlacementGeometry`, and applied once. This is not tidiness: driving
/// a panel through size A → B → A inside one main-loop turn is what crashed the
/// second recording of every session. See `docs/architecture/recording.md`.
final class OverlayWindowController {
  private var stripEngine: FlutterEngine?
  private var stripChannel: FlutterMethodChannel?
  private var stripPanel: NSPanel?

  private var previewEngine: FlutterEngine?
  private var previewChannel: FlutterMethodChannel?
  private var previewPanel: NSPanel?
  private var previewTextureId: Int64?

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
  }

  /// Raised by the control strip and forwarded to the application engine.
  var onCommand: ((String) -> Void)?

  /// Supplies camera frames for the preview texture.
  var cameraFrameProvider: (() -> CVPixelBuffer?)?

  /// Every window id the capture filter must exclude.
  var excludedWindowIDs: Set<CGWindowID> {
    var ids = Set<CGWindowID>()
    for panel in [stripPanel, previewPanel] {
      if let panel, panel.windowNumber > 0 {
        ids.insert(CGWindowID(panel.windowNumber))
      }
    }
    return ids
  }

  // MARK: - control strip

  func showControlStrip(placement: [String: Any]) {
    let engine = stripEngine ?? makeEngine(name: "relay.controlStrip", entrypoint: "controlStripMain")
    stripEngine = engine
    if stripChannel == nil {
      stripChannel = makeViewChannel(for: engine) { [weak self] call, result in
        self?.handleViewCall(call, result: result, isStrip: true)
      }
    }

    // The strip is the first overlay of a session, and it is shown while the
    // main window is still visible. That makes this the one moment where §5's
    // "the display holding the main application window" still has an answer.
    sessionScreen = mainWindowScreen()

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
    aspectRatio: Double
  ) {
    let engine = previewEngine ?? makeEngine(name: "relay.cameraPreview", entrypoint: "cameraPreviewMain")
    previewEngine = engine
    if previewChannel == nil {
      previewChannel = makeViewChannel(for: engine) { [weak self] call, result in
        self?.handleViewCall(call, result: result, isStrip: false)
      }
    }
    if previewTextureId == nil, let provider = cameraFrameProvider {
      previewTextureId = engine.register(
        CameraPreviewTexture(provider: provider))
    }

    let frame = self.frame(
      for: alignedToCamera(
        placement, configuration: configuration, aspectRatio: aspectRatio),
      defaultSize: NSSize(width: 200, height: 140))
    let panel = previewPanel ?? makePanel(for: engine, contentRect: frame, acceptsMouse: false)
    previewPanel = panel
    place(panel, at: frame)

    // Armed only once the panel is on screen. The signal drives the preview
    // engine's raster thread, and there is nothing for it to draw into until
    // the window exists.
    if let previewTextureId {
      previewSignalLock.lock()
      previewSignal = (engine: engine, textureId: previewTextureId)
      previewSignalLock.unlock()
    }

    lastPreviewState = [
      "textureId": previewTextureId as Any,
      "mirrored": mirrored,
      "matchesCompositedPip": matchesCompositedPip,
      "aspectRatio": aspectRatio,
    ]
    previewChannel?.invokeMethod("cameraPreviewState", arguments: lastPreviewState)
  }

  func hideCameraPreview() {
    previewPanel?.orderOut(nil)
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

  /// Re-resolves a picture-in-picture frame against the camera's real shape.
  ///
  /// Dart resolves the tile from the *fallback* aspect ratio, because only this
  /// side knows what the camera actually produces. In display mode the preview
  /// must sit exactly where the compositor draws the picture-in-picture (design
  /// `1p`), and the compositor uses the camera's own shape — so the preview
  /// window has to be corrected here or the two would disagree. Only the height
  /// moves, and only away from the corner the tile is anchored to.
  private func alignedToCamera(
    _ placement: [String: Any],
    configuration: CameraOverlayConfiguration?,
    aspectRatio: Double
  ) -> [String: Any] {
    guard let configuration, configuration.followsSourceAspectRatio,
      aspectRatio > 0,
      var frame = placement["frame"] as? [String: Any],
      let y = frame["y"] as? Double,
      let width = frame["width"] as? Double,
      let height = frame["height"] as? Double,
      width > 0, height > 0
    else { return placement }
    let corrected = width / aspectRatio
    frame["height"] = corrected
    if !configuration.pinsTopEdge {
      frame["y"] = y + (height - corrected)
    }
    var updated = placement
    updated["frame"] = frame
    return updated
  }

  /// Marks the preview texture dirty. Called from the camera capture queue.
  func markCameraFrameAvailable() {
    previewSignalLock.lock()
    let signal = previewSignal
    previewSignalLock.unlock()
    guard let signal else { return }
    signal.engine.textureFrameAvailable(signal.textureId)
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

  private func handleViewCall(
    _ call: FlutterMethodCall, result: @escaping FlutterResult, isStrip: Bool
  ) {
    switch call.method {
    case "command":
      if let arguments = call.arguments as? [String: Any],
        let command = arguments["command"] as? String
      {
        onCommand?(command)
      }
      result(nil)
    case "beginMove":
      // Replied before the drag rather than after it: the drag loop below runs
      // for the whole gesture, and the caller waiting on this reply is the very
      // engine whose frames the strip needs while it is being dragged.
      result(nil)
      if isStrip {
        beginStripMove()
      }
    case "contentSize":
      if isStrip, let arguments = call.arguments as? [String: Any],
        let width = arguments["width"] as? Double,
        let height = arguments["height"] as? Double,
        OverlayPlacementGeometry.isDrawable(CGSize(width: width, height: height))
      {
        scheduleStripResize(to: NSSize(width: width, height: height))
      }
      result(nil)
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
    // so the strip has to be movable for §33.3's drag to run at all; the camera
    // preview stays fixed. `isMovableByWindowBackground` is left off in both
    // cases: the only drag is the one the strip asks for once its own 4 px
    // threshold is crossed, and AppKit's background drag would start one under
    // it without that threshold, eating slow clicks on the controls.
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
  /// to commit into. A re-show at an unchanged size — the normal case, because
  /// the size is resolved from the same measurement every time — is a move at
  /// most. When the size genuinely did change, the panel is ordered front
  /// *first* so the commit has somewhere to land.
  private func place(_ panel: NSPanel, at frame: NSRect) {
    if OverlayPlacementGeometry.needsResize(from: panel.frame, to: frame) {
      panel.orderFrontRegardless()
    }
    if panel.frame != frame {
      panel.setFrame(frame, display: true)
    }
    panel.orderFrontRegardless()
  }

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
  /// `performDrag(with:)` **blocks until the drag ends** — it runs an event
  /// tracking loop of its own — so the snap and the clamp below run once the
  /// user has let go, which is exactly when §33.3 asks for them.
  private func beginStripMove() {
    guard let panel = stripPanel, panel.isVisible else { return }
    // A method call can be drained a turn late, by which time the button that
    // started the gesture may already be up. A drag loop begun with nothing
    // held has nothing to end it, so a late call is dropped rather than turned
    // into a strip that follows the pointer with no button down.
    guard let event = NSApp.currentEvent,
      event.type == .leftMouseDown || event.type == .leftMouseDragged
    else { return }
    panel.performDrag(with: event)
    settleStripAfterMove(panel)
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

  /// Re-resolves the strip after the display configuration changed (§33.7).
  ///
  /// The *fraction* is re-resolved rather than the pixels re-clamped, which is
  /// what makes one handler cover three rows at once: a resolution or scale
  /// change keeps the strip proportionally where it was, a Dock that appeared
  /// shrinks the usable area under it, and a display that was unplugged leaves
  /// the strip at the same fraction of whichever display it is on now. AppKit
  /// has already relocated the panel by then, so its frame is not the answer.
  private func reclampControlStrip() {
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

  /// A move, never a resize: the frame carries the panel's own size.
  ///
  /// Moving a window does not recreate its rendering surface, so this costs
  /// nothing of what a resize costs — the distinction this whole file turns on.
  private func move(_ panel: NSPanel, to frame: NSRect) {
    guard panel.frame != frame else { return }
    panel.setFrame(frame, display: true)
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
    guard OverlayPlacementGeometry.needsResize(from: panel.frame, to: target)
    else { return }
    panel.setFrame(target, display: true)
    // Growing about the top centre moves the leading edge, so the remembered
    // fraction is no longer the one the strip is at.
    rememberStripPosition(of: target, on: screen)
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
