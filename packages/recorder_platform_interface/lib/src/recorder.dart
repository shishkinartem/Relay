import 'dart:ui' show Offset;

import 'models/camera_overlay_configuration.dart';
import 'models/capture_source.dart';
import 'models/media_device.dart';
import 'models/overlay.dart';
import 'models/permissions.dart';
import 'models/recorder_capabilities.dart';
import 'models/recorder_event.dart';
import 'models/recording_configuration.dart';
import 'models/recording_file.dart';
import 'models/resource_census.dart';
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

/// Enumerates and meters the inputs a recording can use (§33.2).
///
/// Separate from [Recorder] for the same reason [CaptureSourceProvider] is: a
/// platform that can enumerate devices but not record still satisfies it, and
/// the launch screen depends on this half alone.
abstract interface class MediaDeviceProvider {
  /// Every device of [kind] the platform can see, system default first.
  ///
  /// Ordering is part of the contract: **the system default first, then the
  /// rest in the platform's own order**, so the two platforms present the same
  /// list. An empty list is a legitimate answer — no camera is attached — and
  /// is not an error.
  ///
  /// Called for a kind outside `RecorderCapabilities.selectableDeviceKinds` it
  /// returns the single device that kind will use, so a caller can name it
  /// without offering a choice.
  Future<List<MediaDevice>> getInputDevices(MediaDeviceKind kind);

  /// Starts reporting [RecorderInputLevelEvent] for [kind].
  ///
  /// [deviceId] is the device to listen to, and null means the platform
  /// default — the same meaning it has on `RecordingConfiguration`. It is here
  /// because a meter that showed the system default while the user was
  /// choosing a different microphone would answer a question nobody asked: the
  /// bar under a device row has to be *that* device, or picking between two
  /// microphones by speaking does not work at all.
  ///
  /// Nested starts are counted, not stacked: two meters on screen make one tap,
  /// and the tap closes when the last one stops. Starting again with a
  /// different [deviceId] re-points the tap rather than opening a second one.
  /// Metering never opens a device that a recording already holds — during a
  /// session the levels come off the live capture.
  ///
  /// A kind outside `RecorderCapabilities.meterableDeviceKinds` is a no-op
  /// rather than an error, so a caller that asks anyway gets silence instead of
  /// a failure.
  Future<void> startInputMetering(MediaDeviceKind kind, {String? deviceId});

  /// Stops what [startInputMetering] began. Idempotent, and a no-op when
  /// nothing is metering.
  Future<void> stopInputMetering(MediaDeviceKind kind);

  /// Swaps the device an input is using **while a session is running** (§33.2).
  ///
  /// Valid in `recording` and `paused`. The platform re-points the live capture:
  /// it does not restart the session, does not close the output file, and does
  /// not produce a second track — the file keeps one video track and one mixed
  /// audio track (§11).
  ///
  /// Failure degrades and never stops a recording. A device that will not open
  /// leaves the previous one running and raises a non-fatal error; the swap gap
  /// is silence at a known position on the monotonic timeline (§8), never a
  /// drift.
  ///
  /// [deviceId] null means the platform default. Called outside a session it is
  /// a no-op: what the next recording opens is `RecordingConfiguration`'s
  /// business.
  Future<void> selectInputDevice(MediaDeviceKind kind, {String? deviceId});
}

/// The recorder contract (§20).
///
/// Lifecycle: `prepare → start → (pause ⇄ resume)* → stop`. Every lifecycle
/// call is idempotent or explicitly guarded, so double clicks and repeated
/// callbacks cannot corrupt the output (`docs/architecture/recording.md`).
abstract interface class Recorder
    implements CaptureSourceProvider, MediaDeviceProvider {
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

  /// Re-points the camera picture-in-picture mid-session (§33.5).
  ///
  /// Applied between frames, for the next frame. The encoder's canvas never
  /// changes, so the output stays one continuous video track. A no-op outside
  /// a session: what the next recording opens is
  /// [RecordingConfiguration.cameraOverlay]'s business.
  Future<void> setCameraOverlay(CameraOverlayConfiguration configuration);

  /// Where the camera preview window is now, as a fraction of the canvas.
  ///
  /// Null when there is no preview, or when it is not the tile — in window mode
  /// the preview is a separate captioned object and dragging it moves the
  /// preview, not the picture-in-picture (design `1e`, §33.5).
  Future<Offset?> cameraPreviewPosition();

  Future<void> setMicrophoneEnabled(bool enabled);

  Future<void> setCameraEnabled(bool enabled);

  Future<void> setSystemAudioEnabled(bool enabled);

  /// Reads an orphaned `.part` artefact and finalizes it if it is readable.
  ///
  /// Returns null when nothing recoverable is in the file. Never deletes the
  /// artefact (§18).
  Future<RecordingFile?> recoverArtifact(String artifactPath);

  Stream<RecorderEvent> get events;

  /// What the host is still holding, counted (§19.1).
  ///
  /// Debug-only, and the reason it exists is that §19.1's release requirements
  /// are otherwise unfalsifiable: "the session let go of the camera" is not
  /// something a test can assert against an object graph it cannot see. Two
  /// tests bind on it — census equality across ten start → stop cycles, and
  /// every row zero after one stop.
  ///
  /// Never branched on by the application. A host that cannot count a row
  /// answers zero for it rather than failing, because a census raised on the
  /// teardown path must not be able to turn a leak into a crash.
  Future<ResourceCensus> debugResourceCensus();

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

  /// Where the control strip is now, as a fraction of its display's usable
  /// area (§33.3).
  ///
  /// Pulled rather than pushed. The application asks once, when the session
  /// that owns the strip is ending, and persists the answer — so a position is
  /// remembered exactly when §33.7 says it should be ("the strip returns where
  /// the user left it") without a stream of events for a window that may be
  /// dragged for a second and a half.
  ///
  /// Null when there is no strip on screen, or when the host cannot name the
  /// display it is on. A caller keeps the previous stored position rather than
  /// clearing it: failing to read a position is not the user having moved the
  /// strip back.
  Future<OverlayStripPosition?> controlStripPosition();

  /// Shows the input menu at [placement], anchored under the chevron that asked
  /// for it (§33.4).
  ///
  /// A non-activating window: opening it must not take key focus from the
  /// application being recorded. Only one exists — showing it again replaces
  /// whatever was open — and it is registered with the capture filter's
  /// exclusion list on the same terms as the strip and the preview (§6).
  Future<void> showInputMenu(
    OverlayPlacement placement,
    InputMenuOverlayState state,
  );

  /// Pushes a fresh snapshot into an open menu, so a device that appears or
  /// disappears re-renders it in place rather than closing it (§33.7).
  Future<void> updateInputMenu(InputMenuOverlayState state);

  Future<void> hideInputMenu();

  /// Choices made in the input menu.
  ///
  /// A second stream off the same event channel rather than a widening of
  /// [commands]: a command is a bare name and always will be, and a choice
  /// carries a device id. Decoding by shape keeps a host that only ever emits
  /// names working untouched.
  Stream<InputMenuSelection> get menuSelections;

  /// Moves the control strip by [dx], [dy] logical points (§33.3).
  ///
  /// The keyboard path, for a strip that cannot be reached with a pointer. The
  /// host clamps and snaps exactly as it does after a drag.
  Future<void> nudgeControlStrip(double dx, double dy);

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
