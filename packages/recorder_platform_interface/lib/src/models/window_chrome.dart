/// How the host window frames the Flutter view.
///
/// A capability, not an operating-system name (§28): what the application's
/// own header row needs to know is whether the system's window buttons are
/// drawn *over* the view, and that is a fact about the window the runner
/// creates rather than about macOS or Windows. A runner that stopped making
/// its title bar transparent would change this answer without changing
/// platform, and a Linux port would answer it from its own runner in the same
/// way (`docs/architecture/platform-abstraction.md`).
enum WindowChrome {
  /// The window keeps a title bar of its own and the Flutter view sits below
  /// it, inside the client area.
  ///
  /// Nothing of the system's is painted over the view, so the header row
  /// begins at the design's own padding. Reserving room for window buttons
  /// here leaves a dead gap on the leading edge, which is what a plain
  /// `WS_OVERLAPPEDWINDOW` gets.
  separateTitleBar,

  /// The window's title bar is transparent and full-size, so the system draws
  /// its window buttons on top of the Flutter view.
  ///
  /// The header row has to leave the space they occupy free; without it the
  /// title is drawn underneath the buttons.
  overlaidWindowButtons,
}
