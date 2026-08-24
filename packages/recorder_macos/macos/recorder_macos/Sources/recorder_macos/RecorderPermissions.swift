import AVFoundation
import AppKit
import CoreGraphics
import RecorderCore

/// Permission checks and requests (`TECHNICAL_SPEC.md` §23).
///
/// A denial is reported as a status, never thrown: the application decides
/// whether a denied optional input blocks the session.
enum RecorderPermissions {
  static func check() -> [String: String] {
    return [
      "screenRecording": screenRecordingStatus(),
      "microphone": deviceStatus(for: .audio),
      "camera": deviceStatus(for: .video),
    ]
  }

  /// Whether this application has ever asked for screen recording.
  ///
  /// macOS offers no `notDetermined` for screen recording:
  /// `CGPreflightScreenCaptureAccess` answers false both for "never asked" and
  /// for "refused", and the two need opposite treatment — the first wants the
  /// system prompt, the second wants the privacy pane, because macOS lists an
  /// application under a privacy category only once it has asked. Remembering
  /// the ask is the only way to tell them apart.
  private static let hasAskedKey = "relay.permissions.askedScreenRecording"

  private static var hasAskedForScreenRecording: Bool {
    get { UserDefaults.standard.bool(forKey: hasAskedKey) }
    set { UserDefaults.standard.set(newValue, forKey: hasAskedKey) }
  }

  /// Whether *this process* has raised the prompt.
  ///
  /// Separate from the stored flag because the two answer different questions:
  /// this one means "the answer exists but no process can see it until the next
  /// launch", the stored one means "asked at some point in the past".
  private static var hasAskedThisRun = false

  /// Records that the system prompt was raised, wherever it was raised from.
  ///
  /// `SCShareableContent` raises it too, so the enumerator reports back here —
  /// otherwise a user who answered the prompt macOS threw at them during source
  /// enumeration would still be offered "ask again" forever.
  static func noteScreenRecordingAsked() {
    hasAskedThisRun = true
    hasAskedForScreenRecording = true
  }

  static func request(kind: String, completion: @escaping (String) -> Void) {
    switch kind {
    case "screenRecording":
      // Triggers the system prompt on first use. `false` here does not mean
      // refused: macOS grants screen recording to the launched binary, so the
      // answer cannot become visible until the application is opened again.
      // The flag is written only once the call has actually run — writing it
      // beforehand made a request that never happened look like a refusal, and
      // the bit survives launches.
      DispatchQueue.global(qos: .userInitiated).async {
        let granted = CGRequestScreenCaptureAccess()
        DispatchQueue.main.async {
          noteScreenRecordingAsked()
          completion(granted ? "granted" : ScreenRecordingPermissionState.pendingRelaunch)
        }
      }
    case "microphone":
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        DispatchQueue.main.async { completion(granted ? "granted" : "denied") }
      }
    case "camera":
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async { completion(granted ? "granted" : "denied") }
      }
    default:
      completion("notDetermined")
    }
  }

  /// Some denials cannot be re-prompted, so the privacy pane is the only route
  /// left (design `1d`).
  static func openSystemSettings(kind: String) {
    let anchor: String
    switch kind {
    case "microphone": anchor = "Privacy_Microphone"
    case "camera": anchor = "Privacy_Camera"
    default: anchor = "Privacy_ScreenCapture"
    }
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    else { return }
    NSWorkspace.shared.open(url)
  }

  private static func screenRecordingStatus() -> String {
    // Unasked is not refused, and asked-just-now is neither. Reporting `denied`
    // for the first sent a first-run user to a System Settings list that does
    // not yet contain this application; reporting it for the second told a user
    // who had just pressed Allow that they had refused.
    return ScreenRecordingPermissionState.resolve(
      preflightGranted: CGPreflightScreenCaptureAccess(),
      askedThisRun: hasAskedThisRun,
      askedEver: hasAskedForScreenRecording)
  }

  /// Quits this process and opens the application again through Launch
  /// Services, so macOS applies a screen-recording answer it only applies to a
  /// fresh process — and attributes it to this application rather than to
  /// whatever started it.
  ///
  /// Terminates only once the replacement is on its way: a failed reopen must
  /// leave the user with a running application, not with none.
  static func relaunch(completion: @escaping (Bool) -> Void) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(
      at: Bundle.main.bundleURL, configuration: configuration
    ) { _, error in
      DispatchQueue.main.async {
        if error != nil {
          completion(false)
          return
        }
        completion(true)
        NSApp.terminate(nil)
      }
    }
  }

  /// Quits through the ordinary exit path, so capture, camera and power
  /// assertions are released by the application's own lifecycle handler.
  static func quit() {
    DispatchQueue.main.async { NSApp.terminate(nil) }
  }

  private static func deviceStatus(for mediaType: AVMediaType) -> String {
    switch AVCaptureDevice.authorizationStatus(for: mediaType) {
    case .authorized: return "granted"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "notDetermined"
    }
  }
}
