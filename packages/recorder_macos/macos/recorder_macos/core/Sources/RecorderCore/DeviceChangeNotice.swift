import Foundation

/// The `devicesChanged` event: "read the lists again", naming which one when
/// that can be said honestly (§33.7).
///
/// Dart is told to re-read rather than told what changed, because the list it
/// draws is the enumeration and not a diff. Two very different things reach it
/// through this one event: a device arriving or leaving, and the machine moving
/// its *default* from one device to another — a user changing the input in
/// System Settings > Sound unplugs nothing, and a list that went on marking the
/// old microphone "default" would be wrong in the one place the user is
/// looking (§33.2).
public struct DeviceChangeNotice: Equatable {
  /// The list that changed, or nil for "re-read everything".
  public let kind: MediaDeviceKind?

  public init(kind: MediaDeviceKind?) {
    self.kind = kind
  }

  /// The notice for a device that arrived or left.
  ///
  /// A device that is both a camera and a microphone — a capture card — names
  /// neither, and an omitted kind means "re-read everything", which is the
  /// honest answer for it.
  public static func device(isCamera: Bool, isMicrophone: Bool)
    -> DeviceChangeNotice
  {
    guard isCamera != isMicrophone else { return DeviceChangeNotice(kind: nil) }
    return DeviceChangeNotice(kind: isCamera ? .camera : .microphone)
  }

  /// Whether a change of this shape can have moved the microphone a meter is
  /// listening to.
  ///
  /// A notice that names no kind can, and says so: the honest reading of an
  /// unnamed change is that it may have been anything. A changed audio
  /// *output* cannot — nothing about the machine's input moved — and neither
  /// can a camera.
  public var affectsMicrophone: Bool {
    kind == nil || kind == .microphone
  }

  /// The wire shape, pinned here rather than in the plugin so `swift test`
  /// covers it (`docs/architecture/platform-channel-contract.md`).
  ///
  /// The kind is omitted rather than sent as null, because Dart reads a missing
  /// kind and a null kind the same way and an absent key is the smaller claim.
  public func toMap() -> [String: Any] {
    var map: [String: Any] = ["type": "devicesChanged"]
    if let kind { map["kind"] = kind.rawValue }
    return map
  }
}
