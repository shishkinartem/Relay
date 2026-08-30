import Foundation

/// Whether a running capture's content filter still names every overlay window
/// that is on screen (§6).
///
/// §6 keeps the overlays out of the file with two independent mechanisms: each
/// panel's own `sharingType = .none`, and membership of the content filter's
/// exclusion list. The second one is the one that can quietly stop being true.
/// A filter is built from an `SCShareableContent` snapshot, that snapshot lists
/// **on-screen** windows only, and every window this application excludes — the
/// control strip, the camera preview and the input menu — is put on screen
/// *after* the session was prepared. A panel that was not on screen when the
/// filter was built is not in it, and nothing brings it in later on its own.
///
/// A rule over plain ids so `swift test` executes it: `SCContentFilter` and
/// `SCWindow` cannot be constructed in a test, and "must the running stream be
/// re-pointed at a new filter?" is exactly the kind of decision that should not
/// first need a capture session to check.
public enum CaptureExclusionPolicy {
  /// Whether a source id names a whole display (§4.1's `display:<n>` /
  /// `window:<n>` spelling).
  ///
  /// Only a display source needs the exclusion list at all. A window source
  /// captures one window's own content, which nothing this application owns can
  /// enter, so an overlay appearing changes nothing there — and rebuilding a
  /// window filter mid-session would ask the window server for a window that may
  /// since have closed, turning redundancy into a failed recording.
  ///
  /// A malformed id is not a display: the answer to "should this be rebuilt?"
  /// for an id nothing can be resolved from is no.
  public static func isDisplaySource(_ sourceId: String) -> Bool {
    let parts = sourceId.split(separator: ":", maxSplits: 1)
    return parts.count == 2 && parts[0] == "display" && UInt32(parts[1]) != nil
  }

  /// Whether the filter has to be rebuilt for the overlays on screen now.
  ///
  /// `excludedByFilter` is what the live filter actually holds — the ids that
  /// were both ours and on screen when it was last built — rather than every
  /// panel this application owns. The difference is the whole point: an id that
  /// never reached the filter has to put it right, and an id that is already in
  /// it must not spend an `SCShareableContent` fetch every time a menu opens.
  ///
  /// An exclusion survives the window it names being hidden and shown again,
  /// because the filter excludes by window id and the id outlives an
  /// `orderOut(_:)`. So a panel coming back is only a rebuild when it was never
  /// in the list to begin with.
  public static func needsFilterRebuild(
    sourceId: String,
    onScreenOverlayIDs: Set<UInt32>,
    excludedByFilter: Set<UInt32>
  ) -> Bool {
    guard isDisplaySource(sourceId) else { return false }
    return !onScreenOverlayIDs.isSubset(of: excludedByFilter)
  }
}
