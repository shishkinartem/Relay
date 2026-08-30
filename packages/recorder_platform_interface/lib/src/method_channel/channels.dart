/// Names of the Flutter/native channels.
///
/// This is an internal API contract: every supported platform implementation
/// must speak exactly these names, methods and payload shapes
/// (`docs/architecture/platform-abstraction.md`). See
/// `docs/architecture/platform-channel-contract.md` for the payloads.
abstract final class RecorderChannels {
  /// Application engine → native. Commands, configuration, capabilities.
  static const String recorder = 'relay/recorder';

  /// Native → application engine. State, ticks, stats and typed errors.
  static const String recorderEvents = 'relay/recorder/events';

  /// Application engine → native. Overlay window lifecycle and state pushes.
  static const String overlay = 'relay/overlay';

  /// Native → application engine. Commands raised by the control strip.
  static const String overlayEvents = 'relay/overlay/events';

  /// Overlay engine ↔ native. Used only inside an overlay window's own engine.
  static const String overlayView = 'relay/overlay/view';
}

/// Entrypoint names the native side runs in the secondary Flutter engines.
abstract final class OverlayEntrypoints {
  static const String controlStrip = 'controlStripMain';
  static const String cameraPreview = 'cameraPreviewMain';

  /// The device list a chevron opens (§33.4). Its own engine for the same
  /// reason the other two have one: it is a separate always-on-top window, and
  /// it must be excluded from capture as they are (§6).
  static const String inputMenu = 'inputMenuMain';
}
