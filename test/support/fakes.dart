import 'dart:async';
import 'dart:io';

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
      supportsCamera: true,
      supportsMicrophone: true,
      supportsSystemAudio: true,
      supportsPause: true,
      supportsCursorCapture: true,
      supportsHardwareEncoding: true,
      platformName: 'fake',
    ),
    List<CaptureSource>? sources,
  }) : sources = sources ?? defaultSources;

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

  RecorderCapabilities capabilities;
  List<CaptureSource> sources;

  final List<String> calls = <String>[];
  final StreamController<RecorderEvent> _events =
      StreamController<RecorderEvent>.broadcast();

  RecorderException? failOnPrepare;
  RecorderException? failOnStop;
  RecorderException? failOnEnumerate;
  RecorderException? failOnPause;
  RecorderException? failOnMicrophoneToggle;

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

  @override
  Stream<OverlayCommand> get commands => commandController.stream;

  @override
  Future<List<String>> excludedWindowIds() async => excluded;

  @override
  Future<void> hideCameraPreview() async => calls.add('hideCameraPreview');

  @override
  Future<void> hideControlStrip() async => calls.add('hideControlStrip');

  @override
  Future<void> setMainWindowVisible(bool visible) async =>
      calls.add('setMainWindowVisible($visible)');

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
  Future<void> showControlStrip(OverlayPlacement placement) async =>
      calls.add('showControlStrip');

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
