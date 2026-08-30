import 'dart:async';
import 'dart:io';
import 'dart:ui' show Offset;

import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:relay/features/recorder/domain/local_recording_store.dart';
import 'package:relay/features/recorder/domain/session_events.dart';
import 'package:upload_core/upload_core.dart';

/// A scripted [Recorder] with no native side.
///
/// Records every call so a test can assert *what the application asked the
/// platform to do*, which is the part of the contract that must not regress.
class FakeRecorder implements Recorder {
  FakeRecorder({
    this.capabilities = const RecorderCapabilities(
      qualities: <RecordingQuality>{
        RecordingQuality.hd720,
        RecordingQuality.fullHd1080,
      },
      supportedFrameRates: <int>{30, 60},
      supportedSourceTypes: <CaptureSourceType>{
        CaptureSourceType.display,
        CaptureSourceType.window,
      },
      selectableDeviceKinds: <MediaDeviceKind>{
        MediaDeviceKind.camera,
        MediaDeviceKind.microphone,
      },
      meterableDeviceKinds: <MediaDeviceKind>{MediaDeviceKind.microphone},
      supportsCamera: true,
      supportsMicrophone: true,
      supportsSystemAudio: true,
      supportsPause: true,
      supportsCursorCapture: true,
      supportsHardwareEncoding: true,
      platformName: 'fake',
    ),
    List<CaptureSource>? sources,
    Map<MediaDeviceKind, List<MediaDevice>>? devices,
  }) : sources = sources ?? defaultSources,
       devices = devices ?? defaultDevices;

  static final List<CaptureSource> defaultSources = <CaptureSource>[
    const CaptureSource(
      id: 'display:1',
      type: CaptureSourceType.display,
      title: 'Built-in Display',
      subtitle: '2560 × 1600',
      pixelWidth: 2560,
      pixelHeight: 1600,
      isCurrentDisplay: true,
    ),
    const CaptureSource(
      id: 'window:11',
      type: CaptureSourceType.window,
      title: 'Terminal',
      subtitle: 'zsh — flutter run',
      pixelWidth: 1280,
      pixelHeight: 800,
    ),
    const CaptureSource(
      id: 'window:12',
      type: CaptureSourceType.window,
      title: 'Safari',
      subtitle: 'ScreenCaptureKit',
      pixelWidth: 1440,
      pixelHeight: 900,
    ),
  ];

  /// System default first, then the platform's own order — the ordering the
  /// contract promises (§33.2).
  static final Map<MediaDeviceKind, List<MediaDevice>> defaultDevices =
      <MediaDeviceKind, List<MediaDevice>>{
        MediaDeviceKind.camera: <MediaDevice>[
          const MediaDevice(
            id: 'camera:facetime',
            kind: MediaDeviceKind.camera,
            label: 'FaceTime HD Camera',
            isSystemDefault: true,
          ),
          const MediaDevice(
            id: 'camera:brio',
            kind: MediaDeviceKind.camera,
            label: 'Logitech Brio',
          ),
        ],
        MediaDeviceKind.microphone: <MediaDevice>[
          const MediaDevice(
            id: 'mic:builtin',
            kind: MediaDeviceKind.microphone,
            label: 'MacBook Pro Microphone',
            isSystemDefault: true,
          ),
          const MediaDevice(
            id: 'mic:mv7',
            kind: MediaDeviceKind.microphone,
            label: 'Shure MV7',
          ),
        ],
        MediaDeviceKind.systemAudio: <MediaDevice>[],
      };

  RecorderCapabilities capabilities;
  List<CaptureSource> sources;
  Map<MediaDeviceKind, List<MediaDevice>> devices;

  /// Kinds currently metering, so a test can assert the tap is closed again.
  final Set<MediaDeviceKind> metering = <MediaDeviceKind>{};

  /// Which device each open tap was asked for. Null is the platform default.
  final Map<MediaDeviceKind, String?> meteredDevices =
      <MediaDeviceKind, String?>{};

  final List<String> calls = <String>[];
  final StreamController<RecorderEvent> _events =
      StreamController<RecorderEvent>.broadcast();

  RecorderException? failOnPrepare;
  RecorderException? failOnStop;
  RecorderException? failOnEnumerate;
  RecorderException? failOnPause;
  RecorderException? failOnMicrophoneToggle;
  RecorderException? failOnEnumerateDevices;

  /// Completed by the test to release a pause that is "in flight", so an
  /// overlapping command can be issued the way a second click would.
  Completer<void>? holdPause;

  /// The same, for the microphone toggle. Two of them are needed because the
  /// strip's controls are guarded one at a time: whether a slow microphone
  /// still blocks Pause is only observable while the microphone is waiting.
  Completer<void>? holdMicrophone;

  /// Not a [RecorderException] on purpose: the application must survive an
  /// error type it did not anticipate.
  Object? failOnStart;

  /// Never completes, standing in for a platform call that blocks behind a
  /// system prompt.
  bool hangOnStart = false;

  /// The same, for enumeration — the call that actually blocks behind macOS's
  /// screen-recording prompt.
  bool hangOnEnumerate = false;

  RecorderException? failOnRecover;
  RecordingFile? stopResult;
  RecordingFile? recoverResult;
  RecordingConfiguration? lastConfiguration;
  int stopCount = 0;

  void emit(RecorderEvent event) => _events.add(event);

  @override
  Future<void> abort() async => calls.add('abort');

  /// Makes `releaseSession` fail the way a platform mid-teardown does.
  bool failOnReleaseSession = false;

  @override
  Future<void> releaseSession() async {
    calls.add('releaseSession');
    if (failOnReleaseSession) {
      throw const RecorderException(
        RecorderErrorCode.invalidState,
        'The session is already gone.',
      );
    }
  }

  /// Makes `dispose` fail the way a platform whose channel has already gone
  /// away does.
  bool failOnDispose = false;

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _events.close();
    if (failOnDispose) {
      throw const RecorderException(
        RecorderErrorCode.unknown,
        'The platform channel is gone.',
      );
    }
  }

  @override
  Stream<RecorderEvent> get events => _events.stream;

  @override
  Future<List<CaptureSource>> getAvailableSources({
    bool refreshThumbnails = true,
  }) async {
    calls.add('getAvailableSources($refreshThumbnails)');
    if (hangOnEnumerate) {
      await Completer<void>().future;
    }
    final RecorderException? failure = failOnEnumerate;
    if (failure != null) {
      throw failure;
    }
    return sources;
  }

  @override
  Future<List<MediaDevice>> getInputDevices(MediaDeviceKind kind) async {
    calls.add('getInputDevices(${kind.name})');
    final RecorderException? failure = failOnEnumerateDevices;
    if (failure != null) {
      throw failure;
    }
    return devices[kind] ?? const <MediaDevice>[];
  }

  @override
  Future<void> startInputMetering(
    MediaDeviceKind kind, {
    String? deviceId,
  }) async {
    calls.add('startInputMetering(${kind.name}, ${deviceId ?? 'default'})');
    metering.add(kind);
    meteredDevices[kind] = deviceId;
  }

  @override
  Future<void> stopInputMetering(MediaDeviceKind kind) async {
    calls.add('stopInputMetering(${kind.name})');
    metering.remove(kind);
    meteredDevices.remove(kind);
  }

  /// The device each input was swapped to while a session was running.
  final Map<MediaDeviceKind, String?> liveDevices =
      <MediaDeviceKind, String?>{};

  RecorderException? failOnSelectDevice;

  @override
  Future<void> selectInputDevice(
    MediaDeviceKind kind, {
    String? deviceId,
  }) async {
    calls.add('selectInputDevice(${kind.name}, ${deviceId ?? 'default'})');
    final RecorderException? failure = failOnSelectDevice;
    if (failure != null) {
      throw failure;
    }
    liveDevices[kind] = deviceId;
  }

  /// Every picture-in-picture geometry pushed mid-session.
  final List<CameraOverlayConfiguration> cameraOverlays =
      <CameraOverlayConfiguration>[];

  /// What the host would report the preview's position to be.
  Offset? reportedCameraPreviewPosition;

  @override
  Future<void> setCameraOverlay(
    CameraOverlayConfiguration configuration,
  ) async {
    calls.add('setCameraOverlay(${configuration.preset.name})');
    cameraOverlays.add(configuration);
  }

  @override
  Future<Offset?> cameraPreviewPosition() async {
    calls.add('cameraPreviewPosition');
    return reportedCameraPreviewPosition;
  }

  @override
  Future<RecorderCapabilities> getCapabilities() async {
    calls.add('getCapabilities');
    return capabilities;
  }

  @override
  Future<DisplayGeometry> getCurrentDisplay() async {
    calls.add('getCurrentDisplay');
    return const DisplayGeometry(
      id: '1',
      logicalWidth: 1512,
      logicalHeight: 982,
      pixelWidth: 3024,
      pixelHeight: 1964,
      scaleFactor: 2,
    );
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    await holdPause?.future;
    final RecorderException? failure = failOnPause;
    if (failure != null) {
      throw failure;
    }
  }

  @override
  Future<void> prepare(RecordingConfiguration configuration) async {
    calls.add('prepare');
    lastConfiguration = configuration;
    final RecorderException? failure = failOnPrepare;
    if (failure != null) {
      throw failure;
    }
  }

  @override
  Future<RecordingFile?> recoverArtifact(String artifactPath) async {
    calls.add('recoverArtifact');
    final RecorderException? failure = failOnRecover;
    if (failure != null) {
      throw failure;
    }
    return recoverResult;
  }

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> setCameraEnabled(bool enabled) =>
      _record('setCameraEnabled($enabled)');

  @override
  Future<void> setMicrophoneEnabled(bool enabled) async {
    calls.add('setMicrophoneEnabled($enabled)');
    await holdMicrophone?.future;
    final RecorderException? failure = failOnMicrophoneToggle;
    if (failure != null) {
      throw failure;
    }
  }

  @override
  Future<void> setSystemAudioEnabled(bool enabled) =>
      _record('setSystemAudioEnabled($enabled)');

  @override
  Future<void> start() async {
    calls.add('start');
    if (hangOnStart) {
      await Completer<void>().future;
    }
    final Object? failure = failOnStart;
    if (failure != null) {
      throw failure;
    }
  }

  @override
  Future<RecordingFile> stop() async {
    calls.add('stop');
    stopCount++;
    final RecorderException? failure = failOnStop;
    if (failure != null) {
      throw failure;
    }
    return stopResult ?? sampleRecording();
  }

  Future<void> _record(String call) async => calls.add(call);

  static RecordingFile sampleRecording({
    String path = '/tmp/relay/recording-abc123.mp4',
    int sizeBytes = 1094813696,
  }) => RecordingFile(
    path: path,
    recordingId: 'abc123',
    sizeBytes: sizeBytes,
    duration: const Duration(minutes: 14, seconds: 32),
    createdAt: DateTime.utc(2026, 8, 22, 14, 22),
    width: 1920,
    height: 1080,
    frameRate: 60,
  );
}

class FakeRecorderPermissions implements RecorderPermissions {
  FakeRecorderPermissions({Map<PermissionKind, PermissionStatus>? statuses})
    : statuses =
          statuses ??
          <PermissionKind, PermissionStatus>{
            PermissionKind.screenRecording: PermissionStatus.granted,
            PermissionKind.microphone: PermissionStatus.granted,
            PermissionKind.camera: PermissionStatus.granted,
          };

  Map<PermissionKind, PermissionStatus> statuses;
  final List<String> calls = <String>[];

  /// The platform refusing to answer, which must degrade rather than throw.
  bool failOnCheck = false;
  bool hangOnCheck = false;
  bool failOnRequest = false;
  bool failOnOpenSettings = false;
  bool failOnRelaunch = false;

  @override
  Future<PermissionReport> check() async {
    calls.add('check');
    if (hangOnCheck) {
      await Completer<void>().future;
    }
    if (failOnCheck) {
      throw const RecorderException(
        RecorderErrorCode.unknown,
        'The permission service is unavailable.',
      );
    }
    // A copy, not the live map: a real platform answers with a snapshot, and
    // handing out this fake's own storage lets a test that changes a status
    // retroactively change the report the subject already holds.
    return PermissionReport(
      Map<PermissionKind, PermissionStatus>.from(statuses),
    );
  }

  @override
  Future<void> openSystemSettings(PermissionKind kind) async {
    calls.add('openSystemSettings(${kind.name})');
    if (failOnOpenSettings) {
      throw const RecorderException(
        RecorderErrorCode.unsupported,
        'There is no privacy pane to open.',
      );
    }
  }

  @override
  Future<PermissionStatus> request(PermissionKind kind) async {
    calls.add('request(${kind.name})');
    if (failOnRequest) {
      throw const RecorderException(
        RecorderErrorCode.unknown,
        'The prompt could not be shown.',
      );
    }
    return statuses[kind] ?? PermissionStatus.denied;
  }

  @override
  Future<void> relaunchApplication() async {
    calls.add('relaunchApplication');
    if (failOnRelaunch) {
      throw const RecorderException(
        RecorderErrorCode.unsupported,
        'This platform cannot reopen itself.',
      );
    }
  }

  @override
  Future<void> quitApplication() async => calls.add('quitApplication');
}

class FakeOverlayWindowController implements OverlayWindowController {
  final List<String> calls = <String>[];
  final List<RecordingOverlayState> pushed = <RecordingOverlayState>[];
  final List<OverlayPlacement> cameraPlacements = <OverlayPlacement>[];
  final List<CameraOverlayConfiguration?> cameraOverlays =
      <CameraOverlayConfiguration?>[];
  final List<bool> cameraPipModes = <bool>[];
  final StreamController<OverlayCommand> commandController =
      StreamController<OverlayCommand>.broadcast();
  List<String> excluded = <String>['3001', '3002'];

  /// The placements the strip was shown at, so a test can assert what the
  /// remembered position turned into.
  final List<OverlayPlacement> stripPlacements = <OverlayPlacement>[];

  /// What the host would report the strip's position to be. Null stands for a
  /// host that cannot read one — a strip already hidden, or a display it can no
  /// longer name.
  OverlayStripPosition? reportedStripPosition;

  @override
  Stream<OverlayCommand> get commands => commandController.stream;

  @override
  Future<OverlayStripPosition?> controlStripPosition() async {
    calls.add('controlStripPosition');
    return reportedStripPosition;
  }

  /// Every menu snapshot the host was asked to show or update.
  final List<InputMenuOverlayState> menuStates = <InputMenuOverlayState>[];

  /// Choices the menu window reports back, as the event channel would.
  ///
  /// Never closed, like `commandController` beside it: the harness discards the
  /// whole fake, and closing a broadcast controller the view model is still
  /// unsubscribing from races that teardown.
  // ignore: close_sinks
  final StreamController<InputMenuSelection> menuController =
      StreamController<InputMenuSelection>.broadcast();

  @override
  Stream<InputMenuSelection> get menuSelections => menuController.stream;

  @override
  Future<void> showInputMenu(
    OverlayPlacement placement,
    InputMenuOverlayState state,
  ) async {
    calls.add('showInputMenu(${state.kind.name})');
    menuStates.add(state);
  }

  /// Held open by a test to keep a push "in flight" while more samples arrive.
  ///
  /// The real call is a round trip to another Flutter engine; without a way to
  /// stall one, nothing can assert that two never overlap.
  Completer<void>? holdMenuUpdate;

  /// How many pushes are inside `updateInputMenu` right now.
  int menuUpdatesInFlight = 0;
  int peakMenuUpdatesInFlight = 0;

  @override
  Future<void> updateInputMenu(InputMenuOverlayState state) async {
    calls.add('updateInputMenu(${state.kind.name})');
    menuStates.add(state);
    menuUpdatesInFlight++;
    peakMenuUpdatesInFlight = menuUpdatesInFlight > peakMenuUpdatesInFlight
        ? menuUpdatesInFlight
        : peakMenuUpdatesInFlight;
    try {
      await holdMenuUpdate?.future;
    } finally {
      menuUpdatesInFlight--;
    }
  }

  @override
  Future<void> hideInputMenu() async {
    calls.add('hideInputMenu');
    if (hangOnHideInputMenu) {
      await Completer<void>().future;
    }
  }

  final List<Offset> nudges = <Offset>[];

  @override
  Future<void> nudgeControlStrip(double dx, double dy) async {
    nudges.add(Offset(dx, dy));
    calls.add('nudgeControlStrip($dx, $dy)');
  }

  @override
  Future<List<String>> excludedWindowIds() async => excluded;

  @override
  Future<void> hideCameraPreview() async => calls.add('hideCameraPreview');

  @override
  Future<void> hideControlStrip() async => calls.add('hideControlStrip');

  @override
  Future<void> setMainWindowVisible(bool visible) async {
    calls.add('setMainWindowVisible($visible)');
    mainWindowVisible = visible;
  }

  /// The main window is hidden for the whole of a recording, so whether it came
  /// back is the difference between a finished session and an unreachable app.
  bool mainWindowVisible = true;

  /// Makes the sheet's close hang the way a wedged channel call does, so a
  /// teardown that is not guarded can be caught in a test rather than by a
  /// user with no window.
  bool hangOnHideInputMenu = false;

  @override
  Future<void> showCameraPreview(
    OverlayPlacement placement, {
    required bool matchesCompositedPip,
    CameraOverlayConfiguration? cameraOverlay,
  }) async {
    calls.add('showCameraPreview');
    cameraPlacements.add(placement);
    cameraOverlays.add(cameraOverlay);
    cameraPipModes.add(matchesCompositedPip);
  }

  @override
  Future<void> showControlStrip(OverlayPlacement placement) async {
    calls.add('showControlStrip');
    stripPlacements.add(placement);
  }

  @override
  Future<void> updateControlStrip(RecordingOverlayState state) async {
    calls.add('updateControlStrip');
    pushed.add(state);
  }

  Future<void> dispose() => commandController.close();
}

/// A scriptable destination that never touches the network.
class FakeUploadDestination implements UploadDestination {
  FakeUploadDestination({
    this.id = 'fake',
    this.displayName = 'Fake destination',
    this.capabilities = const UploadCapabilities(
      supportsResume: true,
      transportSummary: 'Fake transport',
    ),
    this.account = 'fake@example.com',
  });

  @override
  final String id;

  @override
  final String displayName;

  @override
  final UploadCapabilities capabilities;

  String? account;

  /// Events replayed on `upload`, in order.
  List<UploadEvent> Function(String uploadId, UploadFile file)? script;

  UploadValidationResult validation = const UploadValidationResult.ok();
  final List<String> calls = <String>[];
  final List<String> cancelled = <String>[];
  Completer<void>? holdBeforeTerminal;

  @override
  Future<void> cancel(String uploadId) async {
    cancelled.add(uploadId);
    holdBeforeTerminal?.complete();
  }

  /// Records that the owner released it, so a test can assert the composition
  /// root fans `dispose` out over every destination it registered.
  bool disposed = false;

  @override
  void dispose() => disposed = true;

  @override
  Future<String?> describeAccount() async => account;

  /// A destination that needs one value, so a test can drive the whole connect
  /// screen without a network.
  @override
  DestinationSetup setup = const DestinationSetup(
    kind: DestinationSetupKind.credentials,
    actionLabel: 'Connect',
    steps: <String>['Ask the fake service for a token.'],
    fields: <DestinationField>[
      DestinationField(key: 'token', label: 'Token', secret: true),
      DestinationField(key: 'room', label: 'Room', hint: 'Where to send it'),
    ],
  );

  /// Set to have `connect` refuse the way a real service would.
  UploadError? connectFailure;

  Map<String, String> connected = <String, String>{};

  @override
  Future<bool> isConnected() async => account != null;

  @override
  Future<Map<String, String>> storedSetupValues() async => <String, String>{
    'room': connected['room'] ?? '',
  };

  @override
  Future<void> connect(Map<String, String> values) async {
    calls.add('connect');
    final UploadError? failure = connectFailure;
    if (failure != null) {
      throw failure;
    }
    connected = Map<String, String>.of(values);
    account = 'fake@example.com';
  }

  @override
  Future<void> disconnect() async {
    calls.add('disconnect');
    connected = <String, String>{};
    account = null;
  }

  @override
  Future<UploadValidationResult> validate(UploadFile file) async {
    calls.add('validate');
    return validation;
  }

  @override
  Stream<UploadEvent> upload(UploadFile file, UploadContext context) async* {
    calls.add('upload');
    final List<UploadEvent> events =
        script?.call(context.uploadId, file) ??
        <UploadEvent>[
          UploadStarted(context.uploadId, totalBytes: file.sizeBytes),
          UploadProgress(
            context.uploadId,
            bytesSent: file.sizeBytes,
            totalBytes: file.sizeBytes,
          ),
          UploadSucceeded(
            context.uploadId,
            RemoteUploadResult(
              destinationId: id,
              remoteFileId: 'remote-1',
              remoteName: file.displayName,
              bytesUploaded: file.sizeBytes,
            ),
          ),
        ];
    for (final UploadEvent event in events) {
      if (event is UploadSucceeded ||
          event is UploadFailed ||
          event is UploadCancelled) {
        final Completer<void>? hold = holdBeforeTerminal;
        if (hold != null && !hold.isCompleted) {
          await hold.future;
        }
      }
      yield event;
    }
  }
}

/// A [RecordingStore] that answers from memory.
///
/// The harness wires the *real* store against a temp directory; this exists for
/// the units that only need to know what the store said, not what a disk did.
class FakeRecordingStore implements RecordingStore {
  FakeRecordingStore({List<IncompleteRecordingArtifact>? artifacts})
    : _artifacts = artifacts ?? const <IncompleteRecordingArtifact>[];

  List<IncompleteRecordingArtifact> _artifacts;

  final List<String> discarded = <String>[];
  final List<String> deleted = <String>[];

  @override
  Directory get directory => Directory.systemTemp;

  @override
  Future<void> ensureExists() async {}

  @override
  Future<List<IncompleteRecordingArtifact>> findIncompleteArtifacts() async =>
      _artifacts;

  @override
  Future<RecordingFile> rename(RecordingFile recording, String newName) async =>
      recording;

  @override
  Future<void> delete(RecordingFile recording, DeletionReason reason) async =>
      deleted.add('${recording.path}:${reason.name}');

  @override
  Future<void> discardArtifact(String path) async {
    discarded.add(path);
    _artifacts = _artifacts
        .where((IncompleteRecordingArtifact a) => a.path != path)
        .toList(growable: false);
  }

  @override
  String pathForName(String name) => '${directory.path}/$name.mp4';
}
