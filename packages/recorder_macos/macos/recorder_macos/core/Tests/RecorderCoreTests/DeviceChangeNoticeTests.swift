import XCTest

@testable import RecorderCore

/// The `devicesChanged` event and the kind it names (§33.7).
final class DeviceChangeNoticeTests: XCTestCase {
  func testADeviceThatIsOnlyACameraNamesTheCameraList() {
    let notice = DeviceChangeNotice.device(isCamera: true, isMicrophone: false)
    XCTAssertEqual(notice.kind, .camera)
    XCTAssertEqual(notice.toMap()["kind"] as? String, "camera")
  }

  func testADeviceThatIsOnlyAMicrophoneNamesTheMicrophoneList() {
    let notice = DeviceChangeNotice.device(isCamera: false, isMicrophone: true)
    XCTAssertEqual(notice.kind, .microphone)
    XCTAssertEqual(notice.toMap()["kind"] as? String, "microphone")
  }

  func testADeviceThatIsBothNamesNeither() {
    // A capture card is a camera and a microphone at once. Naming one of the
    // two lists would leave the other stale; naming neither re-reads both.
    let notice = DeviceChangeNotice.device(isCamera: true, isMicrophone: true)
    XCTAssertNil(notice.kind)
    XCTAssertNil(notice.toMap()["kind"])
  }

  func testAChangeWithNoDeviceToNameRereadsEverything() {
    // A notification that carried no device, or a default that moved without
    // anything being plugged in or out: "re-read everything" is the only honest
    // answer.
    let notice = DeviceChangeNotice.device(isCamera: false, isMicrophone: false)
    XCTAssertNil(notice.kind)
  }

  func testTheEventCarriesTheTypeDartMatchesOn() {
    let map = DeviceChangeNotice(kind: nil).toMap()
    XCTAssertEqual(map["type"] as? String, "devicesChanged")
    XCTAssertEqual(map.keys.sorted(), ["type"])

    let named = DeviceChangeNotice(kind: .microphone).toMap()
    XCTAssertEqual(named.keys.sorted(), ["kind", "type"])
  }

  func testOnlyAChangeThatCanHaveMovedTheInputDisturbsTheMeter() {
    // Re-pointing the tap costs a device open and a bar that jumps. A changed
    // audio *output* moved no input, and neither did a camera.
    XCTAssertTrue(DeviceChangeNotice(kind: nil).affectsMicrophone)
    XCTAssertTrue(DeviceChangeNotice(kind: .microphone).affectsMicrophone)
    XCTAssertFalse(DeviceChangeNotice(kind: .camera).affectsMicrophone)
    XCTAssertFalse(DeviceChangeNotice(kind: .systemAudio).affectsMicrophone)
  }
}
