import XCTest

@testable import RecorderCore

/// The input-device value and its wire shape (§33.2).
final class InputDeviceTests: XCTestCase {
  private func device(
    _ id: String, isSystemDefault: Bool = false, isAvailable: Bool = true
  ) -> InputDevice {
    InputDevice(
      id: id, kind: .microphone, label: id, isSystemDefault: isSystemDefault,
      isAvailable: isAvailable)
  }

  func testTheKindNamesAreTheOnesDartDecodes() {
    // `MediaDeviceKind.fromName` in Dart matches on these exact strings, and
    // nothing else on either side of the channel is allowed to spell them.
    XCTAssertEqual(MediaDeviceKind.camera.rawValue, "camera")
    XCTAssertEqual(MediaDeviceKind.microphone.rawValue, "microphone")
    XCTAssertEqual(MediaDeviceKind.systemAudio.rawValue, "systemAudio")
    XCTAssertEqual(MediaDeviceKind.allCases.count, 3)
  }

  func testAnUnknownKindResolvesToNothingRatherThanToAMember() {
    // A kind decoded into the wrong member would enumerate cameras for a
    // microphone request.
    XCTAssertEqual(MediaDeviceKind(name: "camera"), .camera)
    XCTAssertNil(MediaDeviceKind(name: "gramophone"))
    XCTAssertNil(MediaDeviceKind(name: nil))
    XCTAssertNil(MediaDeviceKind(name: ""))
  }

  func testTheWireMapCarriesEveryKeyDartReads() throws {
    let map = InputDevice(
      id: "microphone:BuiltInMicrophoneDevice", kind: .microphone,
      label: "MacBook Pro Microphone", isSystemDefault: true, isAvailable: false
    ).toMap()

    XCTAssertEqual(map.keys.sorted(), [
      "id", "isAvailable", "isSystemDefault", "kind", "label",
    ])
    XCTAssertEqual(map["id"] as? String, "microphone:BuiltInMicrophoneDevice")
    XCTAssertEqual(map["kind"] as? String, "microphone")
    XCTAssertEqual(map["label"] as? String, "MacBook Pro Microphone")
    XCTAssertEqual(map["isSystemDefault"] as? Bool, true)
    XCTAssertEqual(map["isAvailable"] as? Bool, false)
  }

  func testAnUnnamedDeviceIsStillAWellFormedRow() {
    // Dart substitutes the kind's own word for an empty label. Inventing one
    // here would put two different fallbacks on the two platforms.
    let map = InputDevice(id: "microphone:x", kind: .microphone, label: "").toMap()
    XCTAssertEqual(map["label"] as? String, "")
    XCTAssertEqual(map["isSystemDefault"] as? Bool, false)
    XCTAssertEqual(map["isAvailable"] as? Bool, true)
  }

  func testTheSystemDefaultIsListedFirstAndTheRestKeepTheirOrder() {
    // Ordering is part of the contract: the list is drawn in the order it
    // arrives, and the default is the device the session is already using.
    let ordered = InputDevice.ordered([
      device("a"), device("b"), device("c", isSystemDefault: true), device("d"),
    ])
    XCTAssertEqual(ordered.map { $0.id }, ["c", "a", "b", "d"])
  }

  func testAListWithNoDefaultIsLeftAsThePlatformReportedIt() {
    // No default is a legitimate answer — every microphone can be unplugged
    // between the enumeration and the read of the default.
    let devices = [device("a"), device("b")]
    XCTAssertEqual(InputDevice.ordered(devices).map { $0.id }, ["a", "b"])
    XCTAssertEqual(InputDevice.ordered([]).count, 0)
  }
}
