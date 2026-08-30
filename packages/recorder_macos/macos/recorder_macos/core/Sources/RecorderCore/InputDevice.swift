import Foundation

/// Which input a device provides (§33.2).
///
/// The spellings are the wire's, matching `MediaDeviceKind` in
/// `recorder_platform_interface/lib/src/models/media_device.dart`. A name this
/// build does not know decodes to nil rather than to a member: a camera filed
/// under `microphone` would be offered in the wrong list.
public enum MediaDeviceKind: String, CaseIterable {
  case camera
  case microphone

  /// Named on the wire, never chosen on macOS: ScreenCaptureKit delivers the
  /// system mix and there is no endpoint to select (§33.8). It stays a member
  /// so both platforms decode one vocabulary.
  case systemAudio

  public init?(name: String?) {
    guard let name, let kind = MediaDeviceKind(rawValue: name) else { return nil }
    self = kind
  }
}

/// One selectable input, as the platform enumerates it (§33.2).
///
/// The counterpart of `EnumeratedSource` for inputs, and like it a plain value:
/// the enumerator fills it in, the plugin puts `toMap()` on the channel.
public struct InputDevice: Equatable {
  /// Opaque and platform-owned — Dart never parses it (§33.2). Stable across
  /// enumerations *and* across launches, because §33.2 persists the id with the
  /// label so a device that went missing can be named.
  public let id: String

  public let kind: MediaDeviceKind

  /// What the user reads. May be empty; Dart substitutes the kind's own word
  /// rather than drawing a blank row.
  public let label: String

  /// The device this platform would use if nothing were chosen — which is
  /// exactly what a null device id on `RecordingConfiguration` resolves to.
  public let isSystemDefault: Bool

  /// False for a device the platform lists but cannot open right now: held
  /// exclusively by another application, or connected but suspended. Listed and
  /// not selectable, so its absence is legible (§33.7).
  public let isAvailable: Bool

  public init(
    id: String, kind: MediaDeviceKind, label: String,
    isSystemDefault: Bool = false, isAvailable: Bool = true
  ) {
    self.id = id
    self.kind = kind
    self.label = label
    self.isSystemDefault = isSystemDefault
    self.isAvailable = isAvailable
  }

  /// The wire shape, pinned here rather than in the plugin so `swift test`
  /// covers it (`docs/architecture/platform-channel-contract.md`).
  public func toMap() -> [String: Any] {
    [
      "id": id,
      "kind": kind.rawValue,
      "label": label,
      "isSystemDefault": isSystemDefault,
      "isAvailable": isAvailable,
    ]
  }

  /// The system default first, then the platform's own order.
  ///
  /// Part of the contract, not a presentation choice: the list is drawn in the
  /// order it arrives, and the default is the entry the user is currently
  /// recording with. The rest keep the order AVFoundation reported them in, so
  /// two enumerations of an unchanged machine agree.
  public static func ordered(_ devices: [InputDevice]) -> [InputDevice] {
    devices.filter { $0.isSystemDefault } + devices.filter { !$0.isSystemDefault }
  }
}
