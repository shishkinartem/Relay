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
  private static var suppressed = false

  /// The answer `applicationShouldTerminateAfterLastWindowClosed` should give.
  public static var terminatesOnLastWindowClosed: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !suppressed
  }

  /// Raised whenever the main panel is hidden, and idempotent: overlapping
  /// hides — a camera preview going up while the strip is already shown — are
  /// the same hold, not two.
  ///
  /// This was a counter, paired with an `allowTermination()` that decremented
  /// it. Nothing ever called that: the only release is `reset()`, because the
  /// only moment the application may quit again is when the session is over and
  /// the panel is back. A count with no individual release is a flag, and one
  /// that reads as a count invites a caller to try balancing it.
  static func suppressTermination() {
    lock.lock()
    suppressed = true
    lock.unlock()
  }

  /// Drops the hold. Used when the session ends, where the only correct state
  /// is "the application may quit again" regardless of how it got here.
  static func reset() {
    lock.lock()
    suppressed = false
    lock.unlock()
  }
}
