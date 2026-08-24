import AppKit
import Foundation
import RecorderCore

/// Whether the host application may quit once its last ordinary window closes.
///
/// Starting a recording hides the main panel: the panel is an ordinary window
/// and would otherwise sit in the middle of the capture (§6). The control strip
/// that replaces it is an `NSPanel`, and AppKit does not count panels as
/// windows for this purpose — so with the Flutter template's default
/// `applicationShouldTerminateAfterLastWindowClosed` of `true`, hiding the panel
/// terminates the process the instant a recording starts.
///
/// The recorder raises a suppression for exactly as long as it is the reason no
/// ordinary window is on screen, and `AppDelegate` consults it. Closing the
/// panel by hand still quits the application, which is the behaviour the
/// product expects when nothing is being recorded.
public enum RecorderWindowPolicy {
  private static let lock = NSLock()
  private static var suppressions = 0

  /// The answer `applicationShouldTerminateAfterLastWindowClosed` should give.
  public static var terminatesOnLastWindowClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return suppressions == 0
  }

  /// Counted rather than boolean so overlapping hides — a camera preview going
  /// up while the strip is already shown — cannot release each other's hold.
  static func suppressTermination() {
    lock.lock()
    defer { lock.unlock() }
    suppressions += 1
  }

  /// Idempotent: releasing a hold that was never taken is a no-op, so a
  /// duplicated teardown cannot drive the count negative and re-arm termination
  /// while a recording is still live.
  static func allowTermination() {
    lock.lock()
    defer { lock.unlock() }
    if suppressions > 0 {
      suppressions -= 1
    }
  }

  /// Drops every hold. Used when the session ends, where the only correct state
  /// is "the application may quit again" regardless of how it got here.
  static func reset() {
    lock.lock()
    defer { lock.unlock() }
    suppressions = 0
  }
}
