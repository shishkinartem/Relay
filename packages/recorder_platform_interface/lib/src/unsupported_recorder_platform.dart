import 'dart:async';

import 'models/camera_overlay_configuration.dart';
import 'models/capture_source.dart';
import 'models/overlay.dart';
import 'models/permissions.dart';
import 'models/recorder_capabilities.dart';
import 'models/recorder_error.dart';
import 'models/recorder_event.dart';
import 'models/recording_configuration.dart';
import 'models/recording_file.dart';
import 'recorder.dart';

/// The platform used when no native implementation is registered.
///
/// It fails loudly with [RecorderErrorCode.unsupported] rather than pretending
/// to record, and reports empty capabilities so the UI disables itself instead
/// of offering controls that cannot work.
class UnsupportedRecorderPlatform extends RecorderPlatform {
  UnsupportedRecorderPlatform([
    this.reason = 'Recording is not supported on this platform.',
  ]);

  final String reason;

  @override
  late final Recorder recorder = _UnsupportedRecorder(reason);

  @override
  late final RecorderPermissions permissions = _UnsupportedPermissions();

  @override
  late final OverlayWindowController overlays = _UnsupportedOverlays();
}

Never _unsupported(String reason) =>
    throw RecorderException(RecorderErrorCode.unsupported, reason);

class _UnsupportedRecorder implements Recorder {
  _UnsupportedRecorder(this.reason);

  final String reason;

  @override
  Future<void> abort() async {}

  @override
  Future<void> releaseSession() async {}

  @override
  Future<void> dispose() async {}

  @override
  Stream<RecorderEvent> get events => const Stream<RecorderEvent>.empty();

  @override
  Future<List<CaptureSource>> getAvailableSources({
    bool refreshThumbnails = true,
  }) async => const <CaptureSource>[];

  @override
  Future<RecorderCapabilities> getCapabilities() async =>
      RecorderCapabilities.unsupported(reason);

  @override
  Future<DisplayGeometry> getCurrentDisplay() async => const DisplayGeometry(
    id: '',
    logicalWidth: 0,
    logicalHeight: 0,
    pixelWidth: 0,
    pixelHeight: 0,
    scaleFactor: 1,
  );

  @override
  Future<void> pause() async => _unsupported(reason);

  @override
  Future<void> prepare(RecordingConfiguration configuration) async =>
      _unsupported(reason);

  @override
  Future<RecordingFile?> recoverArtifact(String artifactPath) async => null;

  @override
  Future<void> resume() async => _unsupported(reason);

  @override
  Future<void> setCameraEnabled(bool enabled) async {}

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {}

  @override
  Future<void> setSystemAudioEnabled(bool enabled) async {}

  @override
  Future<void> start() async => _unsupported(reason);

  @override
  Future<RecordingFile> stop() async => _unsupported(reason);
}

class _UnsupportedPermissions implements RecorderPermissions {
  @override
  Future<PermissionReport> check() async =>
      const PermissionReport(<PermissionKind, PermissionStatus>{});

  @override
  Future<void> openSystemSettings(PermissionKind kind) async {}

  @override
  Future<PermissionStatus> request(PermissionKind kind) async =>
      PermissionStatus.restricted;

  /// Nothing to relaunch into: without a platform implementation a fresh
  /// process would be just as unable to record as this one.
  @override
  Future<void> relaunchApplication() async {}

  @override
  Future<void> quitApplication() async {}
}

class _UnsupportedOverlays implements OverlayWindowController {
  @override
  Stream<OverlayCommand> get commands => const Stream<OverlayCommand>.empty();

  @override
  Future<List<String>> excludedWindowIds() async => const <String>[];

  @override
  Future<void> hideCameraPreview() async {}

  @override
  Future<void> hideControlStrip() async {}

  @override
  Future<void> showCameraPreview(
    OverlayPlacement placement, {
    required bool matchesCompositedPip,
    CameraOverlayConfiguration? cameraOverlay,
  }) async {}

  @override
  Future<void> showControlStrip(OverlayPlacement placement) async {}

  @override
  Future<void> setMainWindowVisible(bool visible) async {}

  @override
  Future<void> updateControlStrip(RecordingOverlayState state) async {}
}
