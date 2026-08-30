import AVFoundation
import RecorderCore

/// A configured device id, resolved back to the device it names (§33.2).
struct ResolvedInputDevice {
  /// Nil when the machine has no device of that kind at all.
  let device: AVCaptureDevice?

  /// The requested id, and only when it did not resolve. The caller reports it
  /// and carries on with `device`, which is then the platform's own default.
  let unresolvedId: String?
}

/// Enumerates the cameras and microphones a session can open, and resolves a
/// chosen id back to a device (§33.2).
///
/// The input-side counterpart of `CaptureSourceEnumerator`: it produces typed
/// values, and the plugin puts them on the channel. Everything here is a
/// mapping onto AVFoundation — the ordering rule and the wire shape live in
/// `InputDevice`, where `swift test` can reach them.
enum InputDeviceEnumerator {

  /// The devices of one kind, the system default first (§33.2).
  ///
  /// An empty list is an answer, not a failure: a Mac with no camera attached
  /// has no cameras, and the caller names the gap rather than reporting an
  /// error.
  static func devices(kind: MediaDeviceKind) -> [InputDevice] {
    let defaultId = defaultDevice(kind: kind)?.uniqueID
    return InputDevice.ordered(
      discovered(kind: kind).map { device in
        InputDevice(
          id: identifier(kind: kind, device: device),
          kind: kind,
          label: device.localizedName,
          isSystemDefault: device.uniqueID == defaultId,
          // Listed but not openable right now: unplugged between the
          // enumeration and this read, held exclusively by another
          // application, or a camera the system has suspended (§33.7).
          isAvailable: device.isConnected && !device.isSuspended
            && !device.isInUseByAnotherApplication)
      })
  }

  /// Exactly the device a session with no configured id opens.
  ///
  /// The same two expressions `CameraCapture` and `MicrophoneCapture` used
  /// before any of this existed, kept in one place so three things cannot drift
  /// apart: what an unconfigured `prepare` records, what a device id of null
  /// means, and which row the list marks as the default.
  static func defaultDevice(kind: MediaDeviceKind) -> AVCaptureDevice? {
    switch kind {
    case .camera:
      return AVCaptureDevice.default(
        .builtInWideAngleCamera, for: .video, position: .front)
        ?? AVCaptureDevice.default(for: .video)
    case .microphone:
      return AVCaptureDevice.default(for: .audio)
    case .systemAudio:
      return nil
    }
  }

  /// The device a configuration asked for, or the default in its place.
  ///
  /// A device that has gone is reported, never raised: §33.2 degrades an input,
  /// and a `prepare` that refused would turn an unplugged microphone into no
  /// recording at all.
  static func resolve(kind: MediaDeviceKind, requestedId: String?)
    -> ResolvedInputDevice
  {
    guard let requestedId else {
      return ResolvedInputDevice(device: defaultDevice(kind: kind), unresolvedId: nil)
    }
    // Matched against the enumeration rather than looked up by unique id, so a
    // session can only ever open a device the picker was willing to offer.
    if let match = discovered(kind: kind).first(where: {
      identifier(kind: kind, device: $0) == requestedId
    }) {
      return ResolvedInputDevice(device: match, unresolvedId: nil)
    }
    return ResolvedInputDevice(
      device: defaultDevice(kind: kind), unresolvedId: requestedId)
  }

  /// Opaque to Dart, and stable: `uniqueID` survives a replug and a restart,
  /// which is what §33.2's "persist the id with the label" needs. The kind is
  /// prefixed so an id can never be resolved against the wrong list.
  private static func identifier(kind: MediaDeviceKind, device: AVCaptureDevice)
    -> String
  {
    "\(kind.rawValue):\(device.uniqueID)"
  }

  private static func discovered(kind: MediaDeviceKind) -> [AVCaptureDevice] {
    switch kind {
    case .camera:
      return AVCaptureDevice.DiscoverySession(
        deviceTypes: cameraTypes, mediaType: .video, position: .unspecified
      ).devices
    case .microphone:
      return AVCaptureDevice.DiscoverySession(
        deviceTypes: microphoneTypes, mediaType: .audio, position: .unspecified
      ).devices
    case .systemAudio:
      // ScreenCaptureKit delivers the system mix; there is no endpoint to name,
      // so the honest answer is an empty list (§33.8). It is still an answer:
      // the caller must never fall through to `FlutterMethodNotImplemented`,
      // which reaches Dart as `unsupported` — a failure rather than "there is
      // nothing here to choose".
      return []
    }
  }

  /// Every camera a person can point at themselves, and nothing else.
  ///
  /// `.builtInWideAngleCamera` is the FaceTime camera, `.deskViewCamera` and
  /// `.continuityCamera` are what an iPhone offers over Continuity, `.external`
  /// is a USB webcam. macOS 14 renamed the last two; macOS 13.5 is this build's
  /// floor (`Package.swift`) and spells an external camera `.externalUnknown`,
  /// so both vocabularies appear and neither is used where it does not exist.
  private static var cameraTypes: [AVCaptureDevice.DeviceType] {
    if #available(macOS 14.0, *) {
      return [.builtInWideAngleCamera, .deskViewCamera, .external, .continuityCamera]
    }
    return [.builtInWideAngleCamera, .deskViewCamera, .externalUnknown]
  }

  /// The built-in microphone and anything plugged in, under the same two
  /// vocabularies as the cameras above.
  private static var microphoneTypes: [AVCaptureDevice.DeviceType] {
    if #available(macOS 14.0, *) {
      return [.microphone, .external]
    }
    return [.builtInMicrophone, .externalUnknown]
  }
}
