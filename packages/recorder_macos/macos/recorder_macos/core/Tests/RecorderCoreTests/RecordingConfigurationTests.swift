import XCTest

@testable import RecorderCore

/// Decoding `prepare` and sizing the encoded canvas (§11, §28).
final class RecordingConfigurationTests: XCTestCase {
  private func map(_ overrides: [String: Any] = [:]) -> [String: Any] {
    var base: [String: Any] = [
      "sourceId": "display:1",
      "recordingId": "abc123",
      "outputDirectoryPath": "/tmp/relay",
    ]
    for (key, value) in overrides {
      base[key] = value
    }
    return base
  }

  func testTheThreeRequiredKeysAreRequired() {
    // A malformed `prepare` must fail at the boundary. Decoding it into
    // defaults would start a recording that writes to the wrong place.
    for missing in ["sourceId", "recordingId", "outputDirectoryPath"] {
      var incomplete = map()
      incomplete.removeValue(forKey: missing)
      XCTAssertThrowsError(try RecordingConfiguration(map: incomplete), missing) {
        error in
        XCTAssertEqual((error as? RecorderError)?.code, .invalidState)
      }
    }
  }

  func testTheDefaultsMatchTheSpecifiedProductBehaviour() throws {
    let configuration = try RecordingConfiguration(map: map())

    // CLAUDE.md: microphone on, camera off, system audio on, cursor recorded,
    // 30 fps. These are the values a `prepare` without them must produce.
    XCTAssertTrue(configuration.microphoneEnabled)
    XCTAssertFalse(configuration.cameraEnabled)
    XCTAssertTrue(configuration.systemAudioEnabled)
    XCTAssertTrue(configuration.showCursor)
    XCTAssertEqual(configuration.frameRate, 30)
    // A `prepare` that names no preset gets the one a fresh install defaults
    // to: the source's own pixels, and the 0 sentinel that means "no box".
    XCTAssertEqual(configuration.quality, "native")
    XCTAssertEqual(configuration.targetHeight, 0)
  }

  func testEveryDeclaredValueSurvivesDecoding() throws {
    let configuration = try RecordingConfiguration(
      map: map([
        "sourceType": "window",
        "sourceWidth": 1280,
        "sourceHeight": 800,
        "quality": "fullHd1080",
        "targetHeight": 1080,
        "frameRate": 60,
        "cameraEnabled": true,
        "microphoneEnabled": false,
        "systemAudioEnabled": false,
        "showCursor": false,
        "composition": ["aspectRatioPolicy": "stretchToPreset"],
      ]))

    XCTAssertEqual(configuration.sourceType, "window")
    XCTAssertEqual(configuration.sourceWidth, 1280)
    XCTAssertEqual(configuration.sourceHeight, 800)
    XCTAssertEqual(configuration.quality, "fullHd1080")
    XCTAssertEqual(configuration.frameRate, 60)
    XCTAssertTrue(configuration.cameraEnabled)
    XCTAssertFalse(configuration.microphoneEnabled)
    XCTAssertFalse(configuration.systemAudioEnabled)
    XCTAssertFalse(configuration.showCursor)
    XCTAssertEqual(configuration.aspectRatioPolicy, "stretchToPreset")
  }

  func testAnUnconfiguredSessionAsksForNoParticularDevice() throws {
    // Null on all three is what every recording made before devices could be
    // chosen sends, and it has to keep opening exactly the devices it opened
    // then (§33.2).
    let configuration = try RecordingConfiguration(map: map())

    XCTAssertNil(configuration.cameraDeviceId)
    XCTAssertNil(configuration.microphoneDeviceId)
    XCTAssertNil(configuration.systemAudioDeviceId)
  }

  func testAChosenDeviceSurvivesDecodingUnparsed() throws {
    // The id is opaque on both sides. Nothing here may read a meaning out of
    // its shape.
    let configuration = try RecordingConfiguration(
      map: map([
        "cameraDeviceId": "camera:3F45E80A-0176",
        "microphoneDeviceId": "microphone:BuiltInMicrophoneDevice",
        "systemAudioDeviceId": "systemAudio:0",
      ]))

    XCTAssertEqual(configuration.cameraDeviceId, "camera:3F45E80A-0176")
    XCTAssertEqual(
      configuration.microphoneDeviceId, "microphone:BuiltInMicrophoneDevice")
    XCTAssertEqual(configuration.systemAudioDeviceId, "systemAudio:0")
  }

  func testAnEmptyDeviceIdIsNoDeviceIdAtAll() throws {
    // An empty string would match no device and be reported to the user as a
    // device that went missing — a fallback they never asked for.
    let configuration = try RecordingConfiguration(
      map: map([
        "cameraDeviceId": "",
        "microphoneDeviceId": 7,
      ]))

    XCTAssertNil(configuration.cameraDeviceId)
    XCTAssertNil(configuration.microphoneDeviceId)
  }

  func testTheCanvasIsAlwaysEven() throws {
    // H.264 4:2:0 requires even dimensions. An odd canvas is not a slightly
    // wrong file, it is an encoder that refuses to start.
    for (width, height) in [(1365, 767), (999, 555), (1023, 601), (2560, 1600)] {
      let configuration = try RecordingConfiguration(
        map: map([
          "sourceWidth": width, "sourceHeight": height, "targetHeight": 720,
        ]))
      let size = configuration.canvasSize()
      XCTAssertEqual(
        Int(size.width) % 2, 0, "width for \(width)x\(height) is \(size.width)")
      XCTAssertEqual(
        Int(size.height) % 2, 0, "height for \(width)x\(height) is \(size.height)")
    }
  }

  func testTheSourceShapeIsPreservedInsideThePreset() throws {
    // "Contain within preset" means the source is fitted, never stretched: a
    // 16:10 display in a 720p box comes out 16:10, letterboxed by being
    // smaller, not distorted by being filled.
    let configuration = try RecordingConfiguration(
      map: map(["sourceWidth": 2560, "sourceHeight": 1600, "targetHeight": 720]))
    let size = configuration.canvasSize()

    XCTAssertEqual(
      Double(size.width) / Double(size.height), 2560.0 / 1600.0, accuracy: 0.01)
    XCTAssertLessThanOrEqual(size.height, 720)
    XCTAssertLessThanOrEqual(size.width, 1280)
  }

  func testASourceSmallerThanThePresetIsNotUpscaled() throws {
    // The scale is clamped at 1. Upscaling a small window to fill a 1080p box
    // spends bitrate on invented pixels.
    let configuration = try RecordingConfiguration(
      map: map(["sourceWidth": 640, "sourceHeight": 480, "targetHeight": 1080]))
    let size = configuration.canvasSize()

    XCTAssertEqual(size.width, 640)
    XCTAssertEqual(size.height, 480)
  }

  func testAnUnknownSourceSizeFallsBackToTheSixteenByNinePreset() throws {
    let configuration = try RecordingConfiguration(map: map(["targetHeight": 1080]))
    let size = configuration.canvasSize()

    XCTAssertEqual(size.height, 1080)
    XCTAssertEqual(size.width, 1920)
  }

  func testAPolicyOtherThanContainUsesThePresetBox() throws {
    let configuration = try RecordingConfiguration(
      map: map([
        "sourceWidth": 2560, "sourceHeight": 1600, "targetHeight": 720,
        "composition": ["aspectRatioPolicy": "stretchToPreset"],
      ]))
    let size = configuration.canvasSize()

    XCTAssertEqual(size.width, 1280)
    XCTAssertEqual(size.height, 720)
  }

  func testTheCanvasNeverCollapses() throws {
    // A one-pixel window would otherwise round down to a zero-sized canvas and
    // the writer would fail with an error nobody could interpret.
    let configuration = try RecordingConfiguration(
      map: map(["sourceWidth": 1, "sourceHeight": 1, "targetHeight": 720]))
    let size = configuration.canvasSize()

    XCTAssertGreaterThanOrEqual(size.width, 2)
    XCTAssertGreaterThanOrEqual(size.height, 2)
  }

  func testTheNativePresetTakesTheSourceUnchanged() throws {
    // The defect it exists for: a 14-inch MacBook's panel is 3024x1964 backing
    // pixels, and every preset box capped it at the point grid — "1080p"
    // produced 982 lines, a 2:1 downsample done before anything that
    // understands glyphs saw the frame.
    let configuration = try RecordingConfiguration(
      map: map(["sourceWidth": 3024, "sourceHeight": 1964, "targetHeight": 0]))
    let size = configuration.canvasSize()

    XCTAssertEqual(size.width, 3024)
    XCTAssertEqual(size.height, 1964)
  }

  func testTheNativeCanvasIsStillEven() throws {
    let configuration = try RecordingConfiguration(
      map: map(["sourceWidth": 1367, "sourceHeight": 769, "targetHeight": 0]))
    let size = configuration.canvasSize()

    XCTAssertEqual(Int(size.width) % 2, 0)
    XCTAssertEqual(Int(size.height) % 2, 0)
  }

  func testANativeCanvasBeyondTheEncoderBudgetIsScaledDown() throws {
    // A 5K panel's 5120x2880 needs an H.264 level above 5.2, which little
    // hardware accepts. The cap scales; it never crops or distorts.
    let configuration = try RecordingConfiguration(
      map: map(["sourceWidth": 5120, "sourceHeight": 2880, "targetHeight": 0]))
    let size = configuration.canvasSize()

    XCTAssertLessThanOrEqual(
      Int(size.width) * Int(size.height), RecordingConfiguration.maxNativePixels)
    XCTAssertEqual(
      Double(size.width) / Double(size.height), 5120.0 / 2880.0, accuracy: 0.01)
  }

  func testAnUnknownSourceSizeUnderNativeFallsBackToThePresetBox() throws {
    // Never a 2x2 canvas: `native` has no box, so the box arithmetic would
    // compute 0x0 and clamp.
    let configuration = try RecordingConfiguration(map: map(["targetHeight": 0]))
    let size = configuration.canvasSize()

    XCTAssertEqual(size.width, 1920)
    XCTAssertEqual(size.height, 1080)
  }

  func testTheBitrateReproducesBothShippedAnchors() throws {
    // The per-pixel rule replaced a step on height, and it had to land on the
    // two rates this application already shipped or every existing recording
    // profile would have moved.
    XCTAssertEqual(
      Double(RecordingConfiguration.videoBitrate(width: 1280, height: 720, frameRate: 30)),
      1_800_000, accuracy: 30_000)
    XCTAssertEqual(
      Double(RecordingConfiguration.videoBitrate(width: 1920, height: 1080, frameRate: 30)),
      4_000_000, accuracy: 30_000)
    XCTAssertEqual(
      Double(RecordingConfiguration.videoBitrate(width: 1920, height: 1080, frameRate: 60)),
      8_000_000, accuracy: 60_000)
  }

  func testTheBitrateHasNoCliffBetweenPresets() throws {
    // The bug the step function had: a 1512x982 Retina canvas has 1.6 times the
    // pixels of 720p and was given 720p's bitrate, because the step tested
    // `height >= 1000` and 982 misses it by eighteen lines.
    let retina = RecordingConfiguration.videoBitrate(
      width: 1512, height: 982, frameRate: 30)
    let sevenTwenty = RecordingConfiguration.videoBitrate(
      width: 1280, height: 720, frameRate: 30)
    let tenEighty = RecordingConfiguration.videoBitrate(
      width: 1920, height: 1080, frameRate: 30)

    XCTAssertGreaterThan(retina, sevenTwenty)
    XCTAssertLessThan(retina, tenEighty)
  }

  func testTheBitrateIsClampedAtBothEnds() throws {
    XCTAssertEqual(
      RecordingConfiguration.videoBitrate(width: 64, height: 64, frameRate: 30),
      RecordingConfiguration.minimumVideoBitrate)
    XCTAssertEqual(
      RecordingConfiguration.videoBitrate(width: 7680, height: 4320, frameRate: 60),
      RecordingConfiguration.maximumVideoBitrate)
  }

  func testTheNestedCameraOverlayIsDecoded() throws {
    let configuration = try RecordingConfiguration(
      map: map(["cameraOverlay": ["corner": "topLeft", "widthRatio": 0.2]]))

    XCTAssertEqual(configuration.cameraOverlay.corner, "topLeft")
    XCTAssertEqual(configuration.cameraOverlay.widthRatio, 0.2)
  }
}

/// The wire contract shared with Dart.
///
/// Both sides hand-write these names. A rename on either side is caught by
/// nothing else in the project, so the spellings are asserted literally.
final class RecorderContractTests: XCTestCase {
  func testEveryErrorCodeKeepsItsWireSpelling() {
    let expected: Set<String> = [
      "permissionDenied", "sourceUnavailable", "sourceClosed", "cameraUnavailable",
      "microphoneUnavailable", "systemAudioUnavailable", "captureFailed",
      "encodingFailed", "diskFull", "finalizationFailed", "invalidState",
      "unsupported", "unknown",
    ]
    let actual = Set(
      [
        RecorderErrorCode.permissionDenied, .sourceUnavailable, .sourceClosed,
        .cameraUnavailable, .microphoneUnavailable, .systemAudioUnavailable,
        .captureFailed, .encodingFailed, .diskFull, .finalizationFailed,
        .invalidState, .unsupported, .unknown,
      ].map(\.rawValue))

    XCTAssertEqual(actual, expected)
    XCTAssertEqual(actual.count, 13, "Dart declares thirteen codes")
  }

  func testEveryStateKeepsItsWireSpelling() {
    let actual = Set(
      [
        PlatformRecorderState.idle, .preparing, .prepared, .recording, .paused,
        .stopping, .finalizing, .finalized, .failed,
      ].map(\.rawValue))

    XCTAssertEqual(
      actual,
      [
        "idle", "preparing", "prepared", "recording", "paused", "stopping",
        "finalizing", "finalized", "failed",
      ])
    XCTAssertEqual(actual.count, 9, "Dart declares nine states")
  }

  func testAnErrorCarriesItsCodeAndOptionalDetails() {
    let bare = RecorderError(.diskFull, "The disk is full.")
    XCTAssertEqual(bare.code, .diskFull)
    XCTAssertNil(bare.details)

    let detailed = RecorderError(.encodingFailed, "Nope.", details: "AVError -11800")
    XCTAssertEqual(detailed.details, "AVError -11800")
  }
}
