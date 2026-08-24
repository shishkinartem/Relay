import 'models/camera_overlay_configuration.dart';
import 'models/capture_source.dart';
import 'models/overlay.dart';
import 'models/permissions.dart';
import 'models/recorder_capabilities.dart';
import 'models/recorder_event.dart';
import 'models/recording_configuration.dart';
import 'models/recording_file.dart';
import 'unsupported_recorder_platform.dart';

/// Enumerates capture targets (§4.1).
///
/// Kept separate from [Recorder] so a platform that can only offer a native
/// picker still satisfies the same contract.
abstract interface class CaptureSourceProvider {
  /// Displays first, then windows (§4.1).
  ///
  /// [refreshThumbnails] takes a fresh shareable-content snapshot; false reuses
  /// the last one. Thumbnails are stills, never a live stream.
  Future<List<CaptureSource>> getAvailableSources({
    bool refreshThumbnails = true,
  });
}

/// The recorder contract (§20).
///
/// Lifecycle: `prepare → start → (pause ⇄ resume)* → stop`. Every lifecycle
/// call is idempotent or explicitly guarded, so double clicks and repeated
/// callbacks cannot corrupt the output (`docs/architecture/recording.md`).
abstract interface class Recorder implements CaptureSourceProvider {
  Future<RecorderCapabilities> getCapabilities();

  /// The display holding the main application window (§5). Overlay placement
  /// is resolved against it, independently of the selected capture source.
  Future<DisplayGeometry> getCurrentDisplay();

  Future<void> prepare(RecordingConfiguration configuration);

  Future<void> start();

  Future<void> pause();

  Future<void> resume();

  /// Finalizes `recording-<id>.part` into `recording-<id>.mp4` and returns it.
  ///
  /// Calling stop on an already-stopped session returns the same file rather
  /// than failing.
  Future<RecordingFile> stop();

  /// Aborts without finalizing. The `.part` artefact is left on disk for
  /// startup recovery; nothing is deleted here (§18).
  Future<void> abort();

  /// Drops the finished session and everything it still holds.
  ///
  /// Distinct from both [abort] and [dispose]. [abort] is about an *unfinished*
  /// recording and platforms are entitled to refuse it once a file has been
  /// finalized; [dispose] ends the platform's life with the process. Neither
  /// covers "this recording is over and the user has moved on", which is when
  /// the capture graph a session built should stop existing. Without it the
  /// only release was at process exit, so an idle recorder went on owning a
  /// configured camera and microphone — and, if a stop had gone wrong, a
  /// capture the operating system was still attributing to the application.
  ///
  /// Idempotent, and a no-op where there is no session. Never deletes a
  /// recording (§18).
  Future<void> releaseSession();

  Future<void> setMicrophoneEnabled(bool enabled);

  Future<void> setCameraEnabled(bool enabled);

  Future<void> setSystemAudioEnabled(bool enabled);

  /// Reads an orphaned `.part` artefact and finalizes it if it is readable.
  ///
  /// Returns null when nothing recoverable is in the file. Never deletes the
  /// artefact (§18).
  Future<RecordingFile?> recoverArtifact(String artifactPath);

  Stream<RecorderEvent> get events;

  Future<void> dispose();
}

/// Permission checks and requests (§23).
abstract interface class RecorderPermissions {
  Future<PermissionReport> check();

  Future<PermissionStatus> request(PermissionKind kind);

  /// Opens the relevant OS privacy pane. Some permissions cannot be re-prompted
  /// once denied, so this is the only remaining path (design `1d`).
  Future<void> openSystemSettings(PermissionKind kind);

  /// Quits the application and opens it again through the platform's own
  /// launcher.
  ///
  /// Lives on the permissions gateway because it exists for one reason: a
  /// permission the platform applies only to a fresh process
  /// ([RecorderCapabilities.screenRecordingNeedsRelaunch]) cannot otherwise be
  /// applied without the user quitting the application by hand. Never throws;
  /// a platform that cannot relaunch itself does nothing, and the application
  /// keeps running.
  Future<void> relaunchApplication();

  /// Quits the application through the ordinary exit path, so capture, camera
  /// and power assertions are released.
  ///
  /// The remedy when the process cannot repair its own permission attribution
  /// ([RecorderCapabilities.screenRecordingLaunchedByThisApp] is false) and the
  /// user has to open it themselves.
  Future<void> quitApplication();
}

/// Creates, places and tears down the application's always-on-top windows.
///
/// Implementations must register every window they create with the capture
/// filter's exclusion list before the capture session starts (§6).
abstract interface class OverlayWindowController {
  Future<void> showControlStrip(OverlayPlacement placement);

  Future<void> hideControlStrip();

  /// Shows the camera preview at [placement].
  ///
  /// [matchesCompositedPip] is the *presentation mode*, and is stated rather
  /// than inferred: both modes place the window absolutely, so a host that
  /// read the mode off the placement — the presence of a frame, say — would
  /// see display mode every time and the window-mode presentation would never
  /// render (design `1e`).
  ///
  /// [cameraOverlay] travels with it because the host resolves the tile
  /// against the camera's *own* shape, which only the platform knows: the
  /// preview must land exactly where the compositor draws the
  /// picture-in-picture (design `1p`), and Dart can only compute that
  /// rectangle from the configured fallback aspect ratio.
  Future<void> showCameraPreview(
    OverlayPlacement placement, {
    required bool matchesCompositedPip,
    CameraOverlayConfiguration? cameraOverlay,
  });

  Future<void> hideCameraPreview();

  /// Pushes a rendering snapshot to the control-strip window.
  Future<void> updateControlStrip(RecordingOverlayState state);

  /// Hides or restores the main application panel.
  ///
  /// The panel is ordinary application chrome, not an excluded overlay, so a
  /// display recording would otherwise contain it. The designed in-situ
  /// screens show only the strip and the camera preview.
  Future<void> setMainWindowVisible(bool visible);

  /// Window ids currently excluded from capture. Exposed so an integration test
  /// can assert the exclusion list is non-empty before recording starts.
  Future<List<String>> excludedWindowIds();

  /// Commands raised by the control strip.
  Stream<OverlayCommand> get commands;
}

/// Composition root for a platform implementation.
///
/// A platform package registers itself through [instance] from its
/// `dartPluginClass` entry point, so no feature code ever branches on the
/// operating-system name (`docs/architecture/platform-abstraction.md`).
abstract class RecorderPlatform {
  static RecorderPlatform instance = UnsupportedRecorderPlatform();

  Recorder get recorder;
  RecorderPermissions get permissions;
  OverlayWindowController get overlays;
}
