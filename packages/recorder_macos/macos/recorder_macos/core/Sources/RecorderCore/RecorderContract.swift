import Foundation

/// The typed error codes shared with Dart.
///
/// These are `RecorderErrorCode` names; the Dart side maps a channel error's
/// code straight onto its enum, so no message strings are ever parsed
/// (`docs/architecture/platform-channel-contract.md`).
public enum RecorderErrorCode: String {
  case permissionDenied
  case sourceUnavailable
  case sourceClosed
  case cameraUnavailable
  case microphoneUnavailable
  case systemAudioUnavailable
  case captureFailed
  case encodingFailed
  case diskFull
  case finalizationFailed
  case invalidState
  case unsupported
  case unknown
}

public struct RecorderError: Error {
  public let code: RecorderErrorCode
  public let message: String
  public let details: String?

  public init(_ code: RecorderErrorCode, _ message: String, details: String? = nil) {
    self.code = code
    self.message = message
    self.details = details
  }
}

/// Platform-side session states, mirrored by `PlatformRecorderState` in Dart.
public enum PlatformRecorderState: String {
  case idle
  case preparing
  case prepared
  case recording
  case paused
  case stopping
  case finalizing
  case finalized
  case failed
}

/// The three shapes and sizes the picture-in-picture comes in (§33.5).
///
/// A preset rather than a number, because "small square" and "small circle" are
/// what people actually want and neither is reachable by dragging a corner.
/// Mirrors `CameraPipPreset` in
/// `recorder_platform_interface/lib/src/models/camera_overlay_configuration.dart`.
public enum CameraPipPreset: String {
  /// The camera's own shape, at its own width capped at
  /// `CameraOverlayConfiguration.cameraPresetWidthCap`. Nothing is cropped, and
  /// this is the behaviour that shipped before presets existed.
  case camera

  /// 1:1 at `CameraOverlayConfiguration.smallPresetWidth`, centre-cropped.
  case square

  /// The square, masked to a circle. Same size, same crop.
  case circle

  /// A name this build does not know is the default, which is the answer Dart's
  /// own decoder gives it.
  public init(name: String?) {
    self = CameraPipPreset(rawValue: name ?? "") ?? .camera
  }

  /// Whether this preset keeps the whole frame.
  public var keepsWholeFrame: Bool { self == .camera }
}

/// How the camera frame fills its tile.
public enum CameraPipFit: String {
  /// The whole frame, letterboxed if the tile is a different shape. Nothing is
  /// lost.
  case contain

  /// The centre of the frame, cropped to the tile's shape. Something is lost,
  /// and the user asked for it by choosing a shape the camera is not.
  case cover

  public init(name: String?) {
    self = CameraPipFit(rawValue: name ?? "") ?? .contain
  }

  /// The uniform scale that maps a frame of `source` onto a tile of `tile`.
  ///
  /// `contain` takes the smaller of the two ratios, so the whole frame fits and
  /// the tile is letterboxed; `cover` takes the larger, so the tile is full and
  /// what falls outside it is cropped away. Uniform either way — the frame is
  /// never distorted, whichever shape the user chose (§33.5).
  ///
  /// One for a degenerate size: a frame nothing can be measured against is
  /// drawn as it is rather than scaled by zero or by infinity.
  public func scale(source: CGSize, tile: CGSize) -> Double {
    guard source.width > 0, source.height > 0, tile.width > 0, tile.height > 0
    else { return 1 }
    let byWidth = Double(tile.width / source.width)
    let byHeight = Double(tile.height / source.height)
    return self == .cover ? max(byWidth, byHeight) : min(byWidth, byHeight)
  }
}

/// Geometry, shape and mirroring of the camera picture-in-picture.
///
/// Every value arrives from Dart as configuration; nothing here is a
/// compositor constant (`TECHNICAL_SPEC.md` §7, §28).
///
/// **The frame is never distorted, and is cropped only by an explicit shape
/// preset** — identically in the preview and in the file
/// (`docs/adr/2026-08-30-user-adjustable-camera-pip.md`, §33.5). The default
/// still never crops.
///
/// The arithmetic mirrors `CameraOverlayConfiguration.resolveRect` in
/// `recorder_platform_interface`, clamp and corner snap included. That file is
/// the authority; this is the copy `swift test` executes.
public struct CameraOverlayConfiguration {
  /// The accepted default, and the largest the `camera` preset ever gets.
  public static let cameraPresetWidthCap: Double = 0.16

  /// `Square · small` and `Circle · small`.
  public static let smallPresetWidth: Double = 0.10

  /// The bounds §33.5 states. A tile below the floor cannot be read; one above
  /// the ceiling is no longer picture-in-picture.
  public static let minWidthRatio: Double = 0.08
  public static let maxWidthRatio: Double = 0.50

  /// How close to a corner the tile snaps, as a fraction of canvas width.
  public static let snapRatio: Double = 0.02

  public var preset: CameraPipPreset = .camera
  public var widthRatio: Double = cameraPresetWidthCap
  public var aspectRatio: Double = 16.0 / 9.0
  public var followsSourceAspectRatio: Bool = true

  /// Corner radius as a fraction of the tile's *width*. `0.5` is a circle.
  ///
  /// A ratio, not pixels: the same configuration has to describe the same shape
  /// on a 720p and a 1080p canvas, and on the preview window, which is a third
  /// size again.
  public var cornerRadiusRatio: Double = 0

  /// Margin from the canvas edges as a fraction of the canvas width. With a
  /// free `position` it is the minimum distance from any edge.
  public var marginRatio: Double = 0.01

  /// Where the tile goes when `position` is nil, and the set of places a
  /// dragged tile snaps to.
  public var corner: String = "bottomRight"

  /// The tile's top-left as a fraction of the canvas, or nil for `corner`.
  ///
  /// Nil is not "unset": it is a live reference to the corner, so a canvas that
  /// changes shape keeps the tile in the corner rather than at whatever
  /// fraction that corner used to be.
  public var position: CGPoint?

  public var mirrorPreview: Bool = true
  public var mirrorOutput: Bool = false

  /// The fit the map named, when it named one. See `fit`.
  private var requestedFit: CameraPipFit?

  public init() {}

  public init(map: [String: Any]) {
    preset = CameraPipPreset(name: map["preset"] as? String)
    widthRatio = CameraOverlayConfiguration.clampedWidth(
      map["widthRatio"] as? Double ?? widthRatio)
    aspectRatio = map["aspectRatio"] as? Double ?? aspectRatio
    followsSourceAspectRatio =
      map["followsSourceAspectRatio"] as? Bool ?? followsSourceAspectRatio
    cornerRadiusRatio = min(max(map["cornerRadiusRatio"] as? Double ?? 0, 0), 0.5)
    marginRatio = map["marginRatio"] as? Double ?? marginRatio
    corner = map["corner"] as? String ?? corner
    // Half a position is no position, the rule Dart decodes by: a tile placed
    // on one axis and cornered on the other is a shape nobody asked for.
    if let x = map["positionX"] as? Double, let y = map["positionY"] as? Double {
      position = CGPoint(x: x, y: y)
    }
    if let fit = map["fit"] as? String {
      requestedFit = CameraPipFit(name: fit)
    }
    mirrorPreview = map["mirrorPreview"] as? Bool ?? mirrorPreview
    mirrorOutput = map["mirrorOutput"] as? Bool ?? mirrorOutput
  }

  /// Whether the frame is cropped to fill the tile, or fitted whole inside it.
  ///
  /// The preset is what decides — `square` and `circle` crop, `camera` does not
  /// — and it is also what writes the wire's `fit` key. The key is read anyway
  /// because a preset this build does not know decodes to `camera`: without it,
  /// a newer Dart asking for a crop would silently get the whole frame.
  public var fit: CameraPipFit {
    requestedFit ?? (preset.keepsWholeFrame ? .contain : .cover)
  }

  /// The tile's width / height for a camera of `sourceAspectRatio`.
  ///
  /// A tile shaped differently from the camera can only be filled by cropping
  /// or stretching. The `camera` preset removes the choice by taking the
  /// camera's shape; `square` and `circle` make it explicitly, and crop.
  public func effectiveAspectRatio(sourceAspectRatio: Double?) -> Double {
    if followsSourceAspectRatio, let source = sourceAspectRatio, source > 0 {
      return source
    }
    // A non-positive fallback is a malformed configuration, not a shape. It
    // used to clamp to 0.0001 here and to a square in `ResolvePipRect` on
    // Windows, so the same bad input produced a different tile on each
    // platform and nothing on the Dart side could see the difference. Both
    // now fall back to the default 16:9.
    return aspectRatio > 0 ? aspectRatio : 16.0 / 9.0
  }

  /// The width the tile is actually drawn at, as a fraction of the canvas.
  ///
  /// `sourceWidth` is the camera's own width in pixels. On the `camera` preset
  /// it lowers the width so a small sensor is never upscaled past its own
  /// pixels; it does nothing to the fixed presets, whose size is the point.
  public func effectiveWidthRatio(canvasWidth: Double, sourceWidth: Int? = nil)
    -> Double
  {
    let configured = CameraOverlayConfiguration.clampedWidth(widthRatio)
    guard preset.keepsWholeFrame, let sourceWidth, sourceWidth > 0,
      canvasWidth > 0
    else { return configured }
    let natural = Double(sourceWidth) / canvasWidth
    return max(min(natural, configured), CameraOverlayConfiguration.minWidthRatio)
  }

  /// The corner radius in canvas pixels for a tile of `tileWidth`.
  public func cornerRadius(forTileWidth tileWidth: Double) -> Double {
    cornerRadiusRatio * tileWidth
  }

  /// A copy whose width is the one this camera actually gets on this canvas.
  ///
  /// The cap is resolved against the *encoder* canvas, where the camera's own
  /// pixels are the thing being compared, and the result then describes the
  /// tile on any canvas — including the preview window's display, which is
  /// measured in points and would answer a different question.
  public func resolvedForCamera(canvasWidth: Double, sourceWidth: Int?)
    -> CameraOverlayConfiguration
  {
    var resolved = self
    resolved.widthRatio = effectiveWidthRatio(
      canvasWidth: canvasWidth, sourceWidth: sourceWidth)
    return resolved
  }

  /// A copy placed at `position`, or back on its corner when that is nil.
  public func moved(to position: CGPoint?) -> CameraOverlayConfiguration {
    var moved = self
    moved.position = position
    return moved
  }

  /// The picture-in-picture rectangle for a canvas of the given size, in the
  /// canvas' own top-left origin coordinate space.
  ///
  /// The result is always fully inside the canvas and never closer to an edge
  /// than the margin, whatever `position` said — the bounds live here rather
  /// than in whatever dragged the tile, so they hold however the value arrived
  /// (§33.5).
  public func rect(
    canvasWidth: Double, canvasHeight: Double, sourceAspectRatio: Double? = nil,
    sourceWidth: Int? = nil
  ) -> CGRect {
    let width =
      canvasWidth
      * effectiveWidthRatio(canvasWidth: canvasWidth, sourceWidth: sourceWidth)
    let height = width / effectiveAspectRatio(sourceAspectRatio: sourceAspectRatio)
    let margin = canvasWidth * marginRatio

    guard let position else {
      let left: Double
      switch corner {
      case "topLeft", "bottomLeft": left = margin
      default: left = canvasWidth - margin - width
      }
      let top: Double
      switch corner {
      case "topLeft", "topRight": top = margin
      default: top = canvasHeight - margin - height
      }
      return CGRect(x: left, y: top, width: width, height: height)
    }

    let left = CameraOverlayConfiguration.clampInside(
      Double(position.x) * canvasWidth, extent: width, canvasExtent: canvasWidth,
      margin: margin)
    let top = CameraOverlayConfiguration.clampInside(
      Double(position.y) * canvasHeight, extent: height,
      canvasExtent: canvasHeight, margin: margin)
    return snapped(
      CGRect(x: left, y: top, width: width, height: height),
      canvasWidth: canvasWidth, canvasHeight: canvasHeight, margin: margin)
  }

  /// The fraction a tile at `left`, `top` on this canvas would be stored as.
  ///
  /// The inverse of `rect`'s free branch, so a drag that reports points can be
  /// turned back into a position that survives a canvas of another size.
  public static func positionRatio(
    left: Double, top: Double, canvasWidth: Double, canvasHeight: Double
  ) -> CGPoint {
    guard canvasWidth > 0, canvasHeight > 0 else { return .zero }
    return CGPoint(
      x: unitFraction(left / canvasWidth), y: unitFraction(top / canvasHeight))
  }

  /// Keeps one axis inside the canvas, margin included.
  ///
  /// A tile larger than the canvas is pinned to the near margin rather than
  /// centred: the leading edge on screen beats a tile that overhangs on both
  /// sides.
  private static func clampInside(
    _ value: Double, extent: Double, canvasExtent: Double, margin: Double
  ) -> Double {
    let upper = canvasExtent - margin - extent
    guard upper > margin else { return margin }
    return min(max(value, margin), upper)
  }

  /// Pulls a nearly-cornered tile onto the corner exactly.
  ///
  /// "Put it back in the corner" is one gesture rather than a pixel hunt, and a
  /// snap can never be the thing that pushes the tile out: the targets are the
  /// margin itself.
  private func snapped(
    _ rect: CGRect, canvasWidth: Double, canvasHeight: Double, margin: Double
  ) -> CGRect {
    let distance = canvasWidth * CameraOverlayConfiguration.snapRatio
    let right = canvasWidth - margin - rect.width
    let bottom = canvasHeight - margin - rect.height
    return CGRect(
      x: CameraOverlayConfiguration.snap(
        Double(rect.minX), to: [margin, right], within: distance),
      y: CameraOverlayConfiguration.snap(
        Double(rect.minY), to: [margin, bottom], within: distance),
      width: rect.width, height: rect.height)
  }

  /// The first candidate within `distance`, or the value unchanged. First
  /// rather than nearest, because Dart's own snap is written that way and the
  /// two must not disagree about a tile equidistant from both edges.
  private static func snap(
    _ value: Double, to targets: [Double], within distance: Double
  ) -> Double {
    for target in targets where abs(value - target) <= distance {
      return target
    }
    return value
  }

  private static func clampedWidth(_ value: Double) -> Double {
    guard value.isFinite else { return cameraPresetWidthCap }
    return min(max(value, minWidthRatio), maxWidthRatio)
  }

  /// A fraction pulled into `[0, 1]`, with anything unrepresentable read as 0 —
  /// the same reading `OverlayPlacementGeometry` takes of a stored position.
  private static func unitFraction(_ value: Double) -> CGFloat {
    guard value.isFinite else { return 0 }
    return CGFloat(min(max(value, 0), 1))
  }
}

/// What the camera preview window draws: the tile's shape, in **both** modes
/// (§33.5).
///
/// This once returned an unmasked, uncropped frame in window mode, reasoning
/// that the window-mode preview is a separate captioned object and not the tile
/// (design `1e`), so a preset chosen for the file must not reach in and mask
/// the window that stands for it. The premise was right and the conclusion was
/// wrong. `1e` constrains the **panel** — a captioned rectangle, never a
/// circular window — and says nothing about the picture inside it. Meanwhile
/// the compositor has no source-type gate at all: a window recording gets the
/// circle in the file exactly as a display recording does. So all three presets
/// looked identical on screen while the MP4 differed, and a user who chose
/// `Circle` by name had no way to see what they had chosen.
///
/// The crop and the mask therefore travel in both modes. What differs is where
/// they are applied: in display mode to the whole window, which *is* the tile;
/// in window mode to the picture inside a captioned panel that keeps its frame.
///
/// Resolved here rather than at each assignment so `showCameraPreview` and
/// `updateCameraPreview` cannot answer it differently, and so `swift test`
/// executes the rule.
public struct CameraPreviewPresentation: Equatable {
  public init(fit: CameraPipFit, cornerRadiusRatio: Double) {
    self.fit = fit
    self.cornerRadiusRatio = cornerRadiusRatio
  }

  public let fit: CameraPipFit

  /// Corner radius as a fraction of the preview's width; `0.5` is a circle.
  public let cornerRadiusRatio: Double

  /// The whole frame, unmasked — the answer when there is no tile configured at
  /// all, and so nothing whose shape could be shown.
  public static let letterboxed = CameraPreviewPresentation(
    fit: .contain, cornerRadiusRatio: 0)

  /// [matchesCompositedPip] is deliberately not a parameter any more: the shape
  /// is the tile's in both modes, and the only thing the mode decides is which
  /// box it is applied to — the window, or the picture inside a captioned panel.
  public static func resolve(
    configuration: CameraOverlayConfiguration?
  ) -> CameraPreviewPresentation {
    guard let configuration else { return letterboxed }
    return CameraPreviewPresentation(
      fit: configuration.fit, cornerRadiusRatio: configuration.cornerRadiusRatio)
  }
}

/// Everything `prepare` needs, decoded once at the channel boundary.
public struct RecordingConfiguration {
  public let sourceId: String
  public let sourceType: String
  public let sourceWidth: Int
  public let sourceHeight: Int
  public let recordingId: String
  public let outputDirectoryPath: String
  public let quality: String
  public let targetHeight: Int
  public let frameRate: Int
  public let cameraEnabled: Bool
  public let microphoneEnabled: Bool
  public let systemAudioEnabled: Bool
  public let showCursor: Bool

  /// The device each input opens, or nil for this platform's own default
  /// (§33.2).
  ///
  /// Null is today's behaviour exactly: a `prepare` carrying no ids opens the
  /// same camera and the same microphone it opened before a device could be
  /// chosen. An id that no longer resolves falls back to the default and
  /// reports a non-fatal error — a wrong microphone is a degraded recording,
  /// where a refused `prepare` is no recording at all
  /// (`docs/adr/2026-08-23-optional-inputs-degrade-instead-of-blocking.md`).
  public let cameraDeviceId: String?
  public let microphoneDeviceId: String?

  /// Decoded and unused on macOS, where system audio is the mix ScreenCaptureKit
  /// delivers and there is no endpoint to choose (§33.8). It is decoded anyway
  /// so the configuration map is one shape on both platforms.
  public let systemAudioDeviceId: String?

  public let cameraOverlay: CameraOverlayConfiguration
  public let aspectRatioPolicy: String

  public init(map: [String: Any]) throws {
    guard let sourceId = map["sourceId"] as? String,
      let recordingId = map["recordingId"] as? String,
      let outputDirectoryPath = map["outputDirectoryPath"] as? String
    else {
      throw RecorderError(.invalidState, "The recording configuration is incomplete.")
    }
    self.sourceId = sourceId
    self.sourceType = map["sourceType"] as? String ?? "display"
    self.sourceWidth = map["sourceWidth"] as? Int ?? 0
    self.sourceHeight = map["sourceHeight"] as? Int ?? 0
    self.recordingId = recordingId
    self.outputDirectoryPath = outputDirectoryPath
    self.quality = map["quality"] as? String ?? "hd720"
    self.targetHeight = map["targetHeight"] as? Int ?? 720
    self.frameRate = map["frameRate"] as? Int ?? 30
    self.cameraEnabled = map["cameraEnabled"] as? Bool ?? false
    self.microphoneEnabled = map["microphoneEnabled"] as? Bool ?? true
    self.systemAudioEnabled = map["systemAudioEnabled"] as? Bool ?? true
    self.showCursor = map["showCursor"] as? Bool ?? true
    self.cameraDeviceId = RecordingConfiguration.deviceId(map["cameraDeviceId"])
    self.microphoneDeviceId = RecordingConfiguration.deviceId(map["microphoneDeviceId"])
    self.systemAudioDeviceId = RecordingConfiguration.deviceId(map["systemAudioDeviceId"])
    self.cameraOverlay = CameraOverlayConfiguration(
      map: map["cameraOverlay"] as? [String: Any] ?? [:])
    self.aspectRatioPolicy =
      (map["composition"] as? [String: Any])?["aspectRatioPolicy"] as? String
      ?? "containWithinPreset"
  }

  /// An empty id is not an id.
  ///
  /// Dart sends null or a real id, and the standard codec's null arrives here
  /// as a failed cast. An empty string would arrive as a String, match no
  /// device, and be reported to the user as a device that went missing — a
  /// fallback they never asked for.
  private static func deviceId(_ value: Any?) -> String? {
    guard let id = value as? String, !id.isEmpty else { return nil }
    return id
  }

  /// The encoded canvas, matching `VideoCompositionConfiguration` in Dart.
  ///
  /// Even dimensions because H.264 4:2:0 requires them.
  public func canvasSize() -> CGSize {
    let boxHeight = Double(targetHeight)
    let boxWidth = (boxHeight * 16.0 / 9.0).rounded()
    guard sourceWidth > 0, sourceHeight > 0,
      aspectRatioPolicy == "containWithinPreset"
    else {
      return CGSize(width: evenValue(boxWidth), height: evenValue(boxHeight))
    }
    let scale = min(
      boxWidth / Double(sourceWidth), boxHeight / Double(sourceHeight), 1.0)
    return CGSize(
      width: evenValue((Double(sourceWidth) * scale).rounded()),
      height: evenValue((Double(sourceHeight) * scale).rounded()))
  }

  private func evenValue(_ value: Double) -> Double {
    let clamped = max(2, Int(value))
    return Double(clamped % 2 == 0 ? clamped : clamped - 1)
  }
}
