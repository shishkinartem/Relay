import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import RecorderCore

/// Draws the screen frame and the optional camera picture-in-picture onto the
/// fixed output canvas (§7, `docs/architecture/media-pipeline.md`).
///
/// The canvas is established once at `prepare` and never changes, so a source
/// that is resized mid-session is letterboxed rather than re-negotiating the
/// encoder — the conservative reading of the still-open §4.4. The *tile* does
/// change: §33.5 lets the user drag and re-shape it mid-session, and
/// `setOverlay(_:)` applies that between two frames, never inside one, so the
/// file keeps one continuous video track (§11).
///
/// Geometry comes from `CameraOverlayConfiguration`; nothing here hard-codes a
/// position, a size or a shape.
final class VideoCompositor {
  private let context: CIContext
  private let canvasSize: CGSize
  private let background: CIImage

  /// The tile, as the user last left it.
  ///
  /// Written by `setOverlay(_:)` and read by `render`, both of which run on the
  /// session's `processingQueue` — the queue that serializes frame encoding. It
  /// is what makes "applied between frames, for the next frame" literal rather
  /// than hopeful, and it is why this needs no lock of its own.
  private var overlay: CameraOverlayConfiguration

  /// The last rounded-rectangle mask that was built, kept because the tile's
  /// shape changes only when the configuration does — once per menu choice, not
  /// once per frame. Touched only from `render`, on `processingQueue`.
  private var maskCache: (width: Int, height: Int, radius: Double, image: CIImage)?

  init(canvasSize: CGSize, overlay: CameraOverlayConfiguration) {
    self.canvasSize = canvasSize
    self.overlay = overlay
    self.context = CIContext(options: [
      .useSoftwareRenderer: false,
      .cacheIntermediates: false,
    ])
    self.background = CIImage(color: .black).cropped(
      to: CGRect(origin: .zero, size: canvasSize))
  }

  /// Re-points the picture-in-picture (§33.5).
  ///
  /// Must be called on the session's `processingQueue`; see `overlay`.
  func setOverlay(_ overlay: CameraOverlayConfiguration) {
    self.overlay = overlay
  }

  /// True when the screen frame can go straight to the encoder with no
  /// composition at all — the common case with the camera off.
  func canPassThrough(screen: CVPixelBuffer, cameraEnabled: Bool) -> Bool {
    guard !cameraEnabled else { return false }
    return CVPixelBufferGetWidth(screen) == Int(canvasSize.width)
      && CVPixelBufferGetHeight(screen) == Int(canvasSize.height)
  }

  /// Renders one output frame into `destination`.
  func render(
    screen: CVPixelBuffer,
    camera: CVPixelBuffer?,
    into destination: CVPixelBuffer
  ) {
    var image = fit(CIImage(cvPixelBuffer: screen), into: canvasSize)
      .composited(over: background)

    if let camera {
      image = pictureInPicture(camera).composited(over: image)
    }

    context.render(
      image,
      to: destination,
      bounds: CGRect(origin: .zero, size: canvasSize),
      colorSpace: CGColorSpaceCreateDeviceRGB())
  }

  /// Aspect-preserving contain: never distorts, never crops.
  private func fit(_ image: CIImage, into size: CGSize) -> CIImage {
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return image }
    let scale = min(size.width / extent.width, size.height / extent.height)
    let scaled = image.transformed(
      by: CGAffineTransform(scaleX: scale, y: scale))
    let dx = ((size.width - scaled.extent.width) / 2).rounded()
    let dy = ((size.height - scaled.extent.height) / 2).rounded()
    return scaled.transformed(
      by: CGAffineTransform(
        translationX: dx - scaled.extent.origin.x,
        y: dy - scaled.extent.origin.y))
  }

  private func pictureInPicture(_ camera: CVPixelBuffer) -> CIImage {
    var image = CIImage(cvPixelBuffer: camera)
    let extent = image.extent
    guard extent.width > 0, extent.height > 0 else { return image }

    // On the default preset the tile takes the camera's own shape and its own
    // width, so the frame lands whole and at its own proportions: nothing is
    // cropped away and nothing is squeezed. `square` and `circle` ask for a
    // shape the sensor is not, and pay for it with a centre crop the user chose
    // by name (§33.5). Core Image's origin is bottom-left; the configuration's
    // rectangle is expressed top-left, so the vertical position is flipped once
    // here.
    let target = overlay.rect(
      canvasWidth: canvasSize.width, canvasHeight: canvasSize.height,
      sourceAspectRatio: Double(extent.width / extent.height),
      sourceWidth: Int(extent.width))
    let flipped = CGRect(
      x: target.origin.x,
      y: canvasSize.height - target.origin.y - target.height,
      width: target.width,
      height: target.height)

    if overlay.mirrorOutput {
      image =
        image
        .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        .transformed(by: CGAffineTransform(translationX: extent.maxX, y: 0))
    }

    // Two fits, one of them chosen by a preset and neither of them a stretch.
    // `contain` letterboxes the frame inside the tile, which with a tile that
    // follows the source is an exact fit; `cover` scales until the tile is full
    // and drops what falls outside it. The floor on the sensor's own pixels is
    // the width cap in `effectiveWidthRatio`, on the one preset that promises
    // it: filling a chosen square with a letterboxed frame would leave a tile
    // that is partly desktop, which is what the shape presets exist to avoid.
    let scale = overlay.fit.scale(source: extent.size, tile: flipped.size)
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let dx = flipped.origin.x - scaled.extent.origin.x
      + (flipped.width - scaled.extent.width) / 2
    let dy = flipped.origin.y - scaled.extent.origin.y
      + (flipped.height - scaled.extent.height) / 2
    let placed = scaled
      .transformed(by: CGAffineTransform(translationX: dx.rounded(), y: dy.rounded()))
      .cropped(to: flipped)
    return rounded(placed, in: flipped)
  }

  /// Masks the tile's corners, which at `cornerRadiusRatio` 0.5 is a circle.
  ///
  /// The mask's alpha is what the corners lose, so what is dropped is
  /// transparent rather than black: a circle drawn on a black square is a black
  /// square. `CIImage.empty()` is the transparent background the blend uses
  /// outside the mask.
  private func rounded(_ image: CIImage, in rect: CGRect) -> CIImage {
    let radius = overlay.cornerRadius(forTileWidth: Double(rect.width))
    // Below half a pixel there is no corner to draw, and the mask would cost a
    // full-tile blend per frame for nothing.
    guard radius >= 0.5, let mask = tileMask(size: rect.size, radius: radius)
    else { return image }
    return image.applyingFilter(
      "CIBlendWithAlphaMask",
      parameters: [
        kCIInputBackgroundImageKey: CIImage.empty(),
        kCIInputMaskImageKey: mask.transformed(
          by: CGAffineTransform(translationX: rect.minX, y: rect.minY)),
      ])
  }

  /// A white rounded rectangle on transparent, at the tile's pixel size.
  ///
  /// Drawn with Core Graphics rather than generated by a filter: the radius has
  /// to be the same fraction of the tile's width that the preview window rounds
  /// its own corners by, and a path is the one description both sides can be
  /// held to.
  private func tileMask(size: CGSize, radius: Double) -> CIImage? {
    let width = Int(size.width.rounded())
    let height = Int(size.height.rounded())
    guard width > 0, height > 0 else { return nil }
    if let cached = maskCache, cached.width == width, cached.height == height,
      abs(cached.radius - radius) < 0.5
    {
      return cached.image
    }
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let bounds = CGRect(x: 0, y: 0, width: Double(width), height: Double(height))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.addPath(
      CGPath(
        roundedRect: bounds,
        cornerWidth: min(radius, bounds.width / 2),
        cornerHeight: min(radius, bounds.height / 2),
        transform: nil))
    context.fillPath()
    guard let bitmap = context.makeImage() else { return nil }
    let image = CIImage(cgImage: bitmap)
    maskCache = (width: width, height: height, radius: radius, image: image)
    return image
  }
}
