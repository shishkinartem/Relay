import Foundation

/// Resolves the screen-recording permission into one of the statuses the
/// application understands (`TECHNICAL_SPEC.md` §23).
///
/// macOS offers no status of its own: `CGPreflightScreenCaptureAccess()`
/// answers a single bool, and `CGRequestScreenCaptureAccess()` cannot return
/// true in the process that asked, because the grant is applied to the launched
/// binary and takes effect on the next launch. Three questions therefore stand
/// in for one answer, and they mean three different things to the user:
///
/// - never asked -> the system prompt is the remedy;
/// - asked in this process -> nothing is wrong; the application has to reopen;
/// - asked in an earlier process and still not granted -> refused, and only the
///   privacy pane can change it.
///
/// Kept free of AppKit so it can be tested (`swift test`), and kept free of the
/// decision of what each status *means* — that belongs to the application.
public enum ScreenRecordingPermissionState {
  public static let granted = "granted"
  public static let pendingRelaunch = "pendingRelaunch"
  public static let denied = "denied"
  public static let notDetermined = "notDetermined"

  /// - Parameters:
  ///   - preflightGranted: `CGPreflightScreenCaptureAccess()`.
  ///   - askedThisRun: this process has already raised the system prompt.
  ///   - askedEver: any earlier process did, remembered across launches.
  public static func resolve(
    preflightGranted: Bool,
    askedThisRun: Bool,
    askedEver: Bool
  ) -> String {
    if preflightGranted { return granted }
    // Asking in this process wins over the remembered flag: the answer cannot
    // be visible here, so calling it a refusal would accuse the user of
    // refusing something they may have just allowed.
    if askedThisRun { return pendingRelaunch }
    return askedEver ? denied : notDetermined
  }
}
