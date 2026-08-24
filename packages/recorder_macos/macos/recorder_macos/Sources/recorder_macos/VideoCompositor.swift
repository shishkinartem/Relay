import CoreImage
import CoreVideo
import Foundation
import RecorderCore

/// Draws the screen frame and the optional camera picture-in-picture onto the
/// fixed output canvas (§7, `docs/architecture/media-pipeline.md`).
///
/// The canvas is established once at `prepare` and never changes, so a source
/// that is resized mid-session is letterboxed rather than re-negotiating the
/// encoder — the conservative reading of the still-open §4.4.
///
/// Geometry comes from `CameraOverlayConfiguration`; nothing here hard-codes a
/// position or a size.
final class VideoCompositor {
  private let context: CIContext
  private let canvasSize: CGSize
  private let overlay: CameraOverlayConfiguration
  private let background: CIImage

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

    // The tile takes the camera's own shape, so the frame lands whole and at
    // its own proportions: nothing is cropped away and nothing is squeezed.
    // Core Image's origin is bottom-left; the configuration's rectangle is
    // expressed top-left, so the vertical position is flipped once here.
    let target = overlay.rect(
      canvasWidth: canvasSize.width, canvasHeight: canvasSize.height,
      sourceAspectRatio: Double(extent.width / extent.height))
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

    // Aspect fit, centred: with a tile that follows the source this is an exact
    // fit, and with a tile that does not — `followsSourceAspectRatio` off — the
    // frame is letterboxed rather than cropped or distorted, matching Windows.
    let scale = min(flipped.width / extent.width, flipped.height / extent.height)
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let dx = flipped.origin.x - scaled.extent.origin.x
      + (flipped.width - scaled.extent.width) / 2
    let dy = flipped.origin.y - scaled.extent.origin.y
      + (flipped.height - scaled.extent.height) / 2
    return scaled
      .transformed(by: CGAffineTransform(translationX: dx.rounded(), y: dy.rounded()))
      .cropped(to: flipped)
  }
}
