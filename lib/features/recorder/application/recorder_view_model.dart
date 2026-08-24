import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:upload_core/upload_core.dart';

import '../../../core/ids.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/settings/app_settings.dart';
import '../../../upload/application/upload_coordinator.dart';
import '../../../upload/application/upload_destination_registry.dart';
import '../../settings/application/settings_controller.dart';
import '../domain/local_recording_store.dart';
import '../domain/recording_naming.dart';
import '../domain/session_events.dart';
import '../domain/session_machine.dart';
import '../domain/session_state.dart';
import '../domain/upload_translation.dart';
import 'artifact_recovery.dart';
import 'overlay_presenter.dart';
import 'permission_coordinator.dart';
import 'source_catalog.dart';

/// The controls a live session exposes, one at a time each.
///
/// Only the four that change the session while it runs. `Stop` is not here:
/// it is idempotent by way of `isStopping`, and a Stop that had to wait behind
/// a stuck microphone toggle would be the worst control on the strip to lose.
enum StripControl { pauseOrResume, microphone, camera, systemAudio }

/// Orchestrates a recording session: capture lifecycle, overlays, the §19 state
/// machine, and the handoff to upload and deletion.
///
/// All platform work goes through the [Recorder] contract, so nothing here
/// knows which operating system it is running on.
class RecorderViewModel extends ChangeNotifier with WidgetsBindingObserver {
  RecorderViewModel({
    required Recorder recorder,
    required RecorderPermissions permissions,
    required this._overlays,
    required this._store,
    required this._settings,
    required this._uploads,
    required this._destinations,
    required this._logger,
    DateTime Function()? clock,
    this._machine = const SessionMachine(),
    SessionPermissions? permissionCoordinator,
    SourceCatalog? sourceCatalog,
    ArtifactRecovery? artifactRecovery,
  }) : _recorder = recorder,
       _clock = clock ?? DateTime.now,
       // Built here rather than injected from the composition root, because
       // both are this object's own decomposition and not a wiring decision:
       // there is exactly one sensible implementation of each and it needs the
       // same platform handle the recorder already holds. The optional
       // parameters exist so a test can substitute either without a platform.
       _permissions =
           permissionCoordinator ??
           PermissionCoordinator(
             permissions: permissions,
             logger: _logger,
             checkTimeout: platformCallTimeout,
             promptTimeout: permissionPromptTimeout,
           ),
       _catalog =
           sourceCatalog ??
           PlatformSourceCatalog(
             provider: recorder,
             logger: _logger,
             timeout: platformCallTimeout,
           ),
       _recovery =
           artifactRecovery ??
           PlatformArtifactRecovery(
             recorder: recorder,
             store: _store,
             logger: _logger,
           );

  final Recorder _recorder;
  final SessionPermissions _permissions;
  final SourceCatalog _catalog;
  final ArtifactRecovery _recovery;
  final SessionOverlays _overlays;
  final RecordingStore _store;
  final SettingsGateway _settings;
  final Uploads _uploads;
  final DestinationRegistry _destinations;
  final Logger _logger;
  final DateTime Function() _clock;
  final SessionMachine _machine;

  StreamSubscription<RecorderEvent>? _recorderEvents;
  StreamSubscription<OverlayCommand>? _overlayCommands;
  StreamSubscription<UploadEvent>? _uploadEvents;

  SessionState _state = const SessionIdle();
  RecorderCapabilities _capabilities = const RecorderCapabilities.unsupported(
    'Capabilities have not been read yet.',
  );
  DisplayGeometry? _currentDisplay;
  String? _activeRecordingId;
  bool _busy = false;

  /// One command per control at a time. Every one of them reads the session
  /// state, asks the platform to change it, and only then dispatches the
  /// change; two overlapping clicks on the *same* control would both read the
  /// state before either wrote it.
  ///
  /// Per control rather than one latch for all of them. A single latch also
  /// made a microphone toggle block Pause, and — because the platform call it
  /// was holding had no deadline — one call that never answered left every
  /// control on the always-on-top strip dead for the rest of the recording.
  final Set<StripControl> _inFlight = <StripControl>{};
  bool _initialized = false;
  bool _refreshingPermissions = false;

  SessionState get state => _state;
  RecorderCapabilities get capabilities => _capabilities;
  DisplayGeometry? get currentDisplay => _currentDisplay;
  List<CaptureSource> get sources => _catalog.sources;
  CaptureSource? get selectedSource => _catalog.selected;
  List<IncompleteRecordingArtifact> get pendingArtifacts => _recovery.pending;
  PermissionReport get permissionReport => _permissions.report;
  bool get isBusy => _busy;

  /// True while permissions are being re-read.
  ///
  /// Deliberately not [_busy]: this re-read also runs unprompted, from the
  /// lifecycle observer, and sharing one flag would let a resume clear the
  /// busy state a prompt still owns — re-enabling the button that raised it.
  bool get isRefreshingPermissions => _refreshingPermissions;

  /// True when the platform could not be asked what is permitted.
  ///
  /// An unanswered permission and an unreachable platform both read
  /// `notDetermined`; only this tells the screen which story to tell.
  bool get permissionCheckFailed => _permissions.lastCheckFailed;
  AppSettings get settings => _settings.settings;

  /// True while an unfinished artefact is waiting for the user's decision
  /// (design `1n`). Nothing is finalized or deleted until they choose.
  bool get hasRecoverableArtifacts => _recovery.pending.isNotEmpty;

  /// How long a platform call may take before it is treated as unavailable.
  ///
  /// ScreenCaptureKit blocks while macOS shows its permission prompt, which the
  /// user may never answer. Nothing in the application waits forever on it.
  static const Duration platformCallTimeout = Duration(seconds: 8);

  /// Writing out a long recording legitimately takes longer than a command.
  static const Duration finalizationTimeout = Duration(minutes: 2);

  /// A permission prompt is answered by a person, who may be reading it.
  static const Duration permissionPromptTimeout = Duration(minutes: 2);

  bool get isInitialized => _initialized;

  bool get isDiscoveringSources => _catalog.isLoading;

  Future<void> initialize() async {
    _recorderEvents = _recorder.events.listen(
      _onRecorderEvent,
      onError: (Object error, StackTrace _) => _logger.error(
        'recorder_event_stream_error',
        fields: <String, Object?>{'error': error.runtimeType.toString()},
      ),
    );
    _overlayCommands = _overlays.commands.listen(_onOverlayCommand);
    _uploadEvents = _uploads.events.listen(_onUploadEvent);

    WidgetsBinding.instance.addObserver(this);
    await _store.ensureExists();

    try {
      _capabilities = await _recorder.getCapabilities();
      _currentDisplay = await _recorder.getCurrentDisplay();
    } on RecorderException catch (e) {
      _capabilities = RecorderCapabilities.unsupported(e.message);
      _logger.warn(
        'capabilities_unavailable',
        fields: <String, Object?>{'code': e.code.name},
      );
    }

    await _recovery.scan();

    await _permissions.refresh();
    await _loadSources(refreshThumbnails: false, silent: true);
    _presentBlockingPermissionIfNeeded();
    _initialized = true;
    notifyListeners();
  }

  /// Permissions are changed in System Settings, outside this process, and the
  /// only signal we get is the window coming back. Re-reading them on resume is
  /// what keeps the preflight from showing a stale answer.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refreshPermissionsAndSources());
    }
  }

  /// Re-reads permissions, and the source list too once screen recording is
  /// available.
  Future<void> refreshPermissionsAndSources() async {
    if (!_initialized || _state is SessionActive) {
      return;
    }
    _refreshingPermissions = true;
    notifyListeners();
    try {
      await _refreshPermissionsAndSources();
    } finally {
      _refreshingPermissions = false;
      notifyListeners();
    }
  }

  Future<void> _refreshPermissionsAndSources() async {
    final bool couldRecordBefore = _permissions.report.canRecordScreen;
    await _permissions.refresh();
    final bool canRecordNow = _permissions.report.canRecordScreen;

    if (canRecordNow && !couldRecordBefore) {
      _logger.info('screen_permission_granted');
      // The blocking preflight is over; go back to the launch screen and get
      // the sources the user could not see before.
      if (_state is SessionPreflight) {
        _dispatch(const SessionReset());
      }
      await _loadSources(refreshThumbnails: false);
    } else if (!canRecordNow) {
      // Still refused. On the preflight that means re-stating it with the
      // statuses just read — `_presentBlockingPermissionIfNeeded` only enters
      // the preflight from idle, so on its own it would leave `Check again`
      // showing the answer from before the user changed anything.
      if (_state is SessionPreflight) {
        _syncPreflight();
      } else {
        _presentBlockingPermissionIfNeeded();
      }
    } else if (_state is SessionPreflight) {
      _syncPreflight();
    }
    notifyListeners();
  }

  /// Screen recording is never optional: without it there is no video track, so
  /// a denial is shown as the blocking preflight rather than as an empty source
  /// list (design `1d` annotation, §23).
  void _presentBlockingPermissionIfNeeded() {
    if (_permissions.report.canRecordScreen || _state is! SessionIdle) {
      return;
    }
    final CaptureSource? source = _catalog.selected;
    _dispatch(
      PreflightCompleted(
        source:
            source ??
            const CaptureSource(
              id: '',
              type: CaptureSourceType.display,
              title: 'Entire screen',
              subtitle: 'Pending permission',
              pixelWidth: 0,
              pixelHeight: 0,
              isCurrentDisplay: true,
            ),
        report: _permissions.report,
        blockingDenials: _permissions.report.blockingDenials(),
      ),
    );
  }

  // ── source selection ──────────────────────────────────────────────────────

  Future<void> openSourcePicker() async {
    _dispatch(const SourcePickerOpened());
    await _loadSources(refreshThumbnails: true);
  }

  void closeSourcePicker() => _dispatch(const SourcePickerDismissed());

  Future<void> refreshSources() => _loadSources(refreshThumbnails: true);

  void selectSource(CaptureSource source) {
    _catalog.select(source);
    unawaited(_settings.setPreferredSourceType(source.type));
    _dispatch(SourceChosen(source));
    notifyListeners();
  }

  /// The launch screen's `Entire screen` / `A window` choice.
  ///
  /// Choosing a display selects the current display straight away; choosing a
  /// window has to ask which one.
  Future<void> chooseSourceType(CaptureSourceType type) async {
    await _settings.setPreferredSourceType(type);
    if (type == CaptureSourceType.display) {
      final CaptureSource? display = _catalog.preferredDisplay;
      if (display != null) {
        _catalog.select(display);
        notifyListeners();
        return;
      }
    }
    await openSourcePicker();
  }

  Future<void> _loadSources({
    required bool refreshThumbnails,
    bool silent = false,
  }) async {
    // `isLoading` is set before the first suspension, so notifying here is what
    // puts the picker into its loading state. The catalogue owns the latch that
    // keeps two enumerations from overlapping.
    final Future<SourceLoadResult> pending = _catalog.load(
      refreshThumbnails: refreshThumbnails,
    );
    notifyListeners();
    final SourceLoadResult result = await pending;
    try {
      switch (result) {
        case SourceLoadResult.skipped:
          return;
        case SourceLoadResult.loaded:
          if (!silent) {
            _dispatch(
              SourcesLoaded(_catalog.sources, preselect: _catalog.selected),
            );
          }
        case SourceLoadResult.failed:
          final RecorderErrorCode code =
              _catalog.lastFailure ?? RecorderErrorCode.sourceUnavailable;
          if (!silent) {
            _dispatch(SourceEnumerationFailed(code));
          }
          // A refused enumeration is the permission story, not the source
          // story, and only this layer knows the answer belongs on the
          // blocking preflight.
          if (code == RecorderErrorCode.permissionDenied) {
            await _permissions.refresh();
            _presentBlockingPermissionIfNeeded();
          }
      }
    } finally {
      notifyListeners();
    }
  }

  // ── recording lifecycle ───────────────────────────────────────────────────

  /// Runs the permission preflight, then either shows it or starts directly.
  Future<void> requestStart() async {
    final CaptureSource? source = _catalog.selected;
    if (source == null || _busy) {
      return;
    }
    _setBusy(true);
    try {
      await _permissions.refresh();
      final AppSettings s = _settings.settings;

      // An input the user switched on but has never answered for gets its
      // system prompt now, at the moment it is actually needed. Sending them to
      // a settings list that does not yet contain this application would be
      // useless — macOS lists an app under a privacy category only once it has
      // asked.
      for (final MapEntry<PermissionKind, bool> input in <PermissionKind, bool>{
        PermissionKind.microphone: s.microphoneEnabled,
        PermissionKind.camera: s.cameraEnabled,
      }.entries) {
        if (input.value &&
            _permissions.report[input.key] == PermissionStatus.notDetermined) {
          await _permissions.requestQuietly(input.key);
        }
      }
      await _permissions.refresh();

      final Set<PermissionKind> blocking = _permissions.report
          .blockingDenials();
      final Set<PermissionKind> degraded = _permissions.report.degradedInputs(
        microphoneRequested: s.microphoneEnabled,
        cameraRequested: s.cameraEnabled,
      );

      // The preflight is shown when there is something to say: recording is
      // impossible, or an input the user switched on will be missing. A denied
      // permission for an input that is already off is not worth a screen.
      if (blocking.isEmpty && degraded.isEmpty) {
        await _beginRecording(source);
        return;
      }
      _dispatch(
        PreflightCompleted(
          source: source,
          report: _permissions.report,
          blockingDenials: blocking,
          degradedInputs: degraded,
        ),
      );
    } finally {
      _setBusy(false);
    }
  }

  /// Start from the preflight screen once the user has seen it.
  Future<void> confirmPreflight() async {
    final SessionState current = _state;
    if (current is! SessionPreflight || !current.canStart || _busy) {
      return;
    }
    _setBusy(true);
    try {
      await _beginRecording(current.source);
    } finally {
      _setBusy(false);
    }
  }

  /// Asks the OS for [kind]. Screen recording is granted process-wide only
  /// after a relaunch, so the caller keeps showing the preflight until a fresh
  /// check succeeds.
  ///
  /// Guarded: without it a second tap while the operating system's own window
  /// is still up raises a second prompt for the same permission.
  Future<void> requestPermission(PermissionKind kind) async {
    if (_busy) {
      return;
    }
    final SessionState before = _state;
    final bool wasBlocked = before is SessionPreflight && !before.canStart;
    _setBusy(true);
    try {
      await _permissions.requestAndRefresh(kind);
      // Only a preflight that *was* blocking and no longer is has served its
      // purpose. Leaving on any usable screen recording would also fire for the
      // row buttons of the degraded preflight, where screen recording is
      // granted already — abandoning the Start the user had just pressed.
      if (wasBlocked && _permissions.report.canRecordScreen) {
        _logger.info('screen_permission_granted');
        _dispatch(const SessionReset());
        await _loadSources(refreshThumbnails: false, silent: true);
        notifyListeners();
      } else {
        _syncPreflight();
      }
    } finally {
      _setBusy(false);
    }
  }

  Future<void> openPermissionSettings(PermissionKind kind) =>
      _permissions.openSettings(kind);

  /// Quits and reopens the application so a permission the platform applies
  /// only to a fresh process takes effect (§23).
  Future<void> relaunchApplication() async {
    if (_busy) {
      return;
    }
    _setBusy(true);
    try {
      await _permissions.relaunchApplication();
    } finally {
      _setBusy(false);
    }
  }

  /// Quits the application, for the case where only the user can reopen it in
  /// a way the operating system attributes to this application.
  Future<void> quitApplication() => _permissions.quitApplication();

  /// Leaves the preflight without starting a recording.
  ///
  /// The preflight is a question, not a live session (`session_machine.dart`),
  /// so the answer may be "not now" — before this there was no widget that
  /// could say it.
  void cancelPreflight() {
    if (_state is SessionPreflight) {
      _dispatch(const SessionReset());
      notifyListeners();
    }
  }

  /// Re-states the preflight against the current report.
  ///
  /// The screen shows what is blocked and what will be missing, so a permission
  /// answered while it is up has to be reflected there or the user is looking
  /// at a stale reason not to record.
  void _syncPreflight() {
    final SessionState current = _state;
    if (current is SessionPreflight) {
      final AppSettings s = _settings.settings;
      _dispatch(
        PreflightCompleted(
          source: current.source,
          report: _permissions.report,
          blockingDenials: _permissions.report.blockingDenials(),
          degradedInputs: _permissions.report.degradedInputs(
            microphoneRequested: s.microphoneEnabled,
            cameraRequested: s.cameraEnabled,
          ),
        ),
      );
    }
    notifyListeners();
  }

  Future<void> _beginRecording(CaptureSource source) async {
    final AppSettings s = _settings.settings;
    // An input the OS refuses is dropped for this session rather than blocking
    // it; the user's stored preference is left alone so it comes back once the
    // permission is granted.
    // Two independent gates, and both are needed. A permission answers "may
    // we", capabilities answer "is there anything to ask for" — a machine with
    // no camera reports `supportsCamera: false` while the permission stays
    // granted from the last machine that had one.
    final bool microphoneAvailable =
        _capabilities.supportsMicrophone &&
        _permissions.report.isUsable(PermissionKind.microphone);
    final bool cameraAvailable =
        _capabilities.supportsCamera &&
        _permissions.report.isUsable(PermissionKind.camera);
    final bool systemAudioAvailable = _capabilities.supportsSystemAudio;

    final bool microphone = s.microphoneEnabled && microphoneAvailable;
    final bool camera = s.cameraEnabled && cameraAvailable;
    final bool systemAudio = s.systemAudioEnabled && systemAudioAvailable;
    final String recordingId = newId();
    _activeRecordingId = recordingId;
    _dispatch(PreparationStarted(source));

    // The panel is hidden as part of starting, and a failure anywhere in here
    // must put it back. Without the `finally` a thrown timeout — or any error
    // that is not a RecorderException — leaves the window hidden with no way to
    // bring it back, which is indistinguishable from a crash.
    bool started = false;
    try {
      _currentDisplay = await _recorder.getCurrentDisplay().timeout(
        platformCallTimeout,
      );
      await _recorder
          .prepare(
            RecordingConfiguration(
              source: source,
              recordingId: recordingId,
              outputDirectoryPath: _store.directory.path,
              quality: s.quality,
              frameRate: s.frameRate,
              cameraEnabled: camera,
              microphoneEnabled: microphone,
              systemAudioEnabled: systemAudio,
              showCursor: s.showCursor,
            ),
          )
          .timeout(platformCallTimeout);

      await _overlays.showControlStrip().timeout(platformCallTimeout);
      if (camera) {
        await _showCameraPreview();
      }
      await _overlays.setMainWindowVisible(false).timeout(platformCallTimeout);

      await _recorder.start().timeout(platformCallTimeout);
      started = true;

      _dispatch(
        RecordingStarted(
          source: source,
          microphoneEnabled: microphone,
          cameraEnabled: camera,
          systemAudioEnabled: systemAudio,
          microphoneAvailable: microphoneAvailable,
          cameraAvailable: cameraAvailable,
          systemAudioAvailable: systemAudioAvailable,
        ),
      );
      if (!microphone && s.microphoneEnabled) {
        _dispatch(
          const InputBecameUnavailable(RecorderErrorCode.microphoneUnavailable),
        );
      }
      if (!camera && s.cameraEnabled) {
        _dispatch(
          const InputBecameUnavailable(RecorderErrorCode.cameraUnavailable),
        );
      }
      if (!systemAudio && s.systemAudioEnabled) {
        _dispatch(
          const InputBecameUnavailable(
            RecorderErrorCode.systemAudioUnavailable,
          ),
        );
      }
      await _pushOverlayState();
    } on Object catch (e) {
      _logger.error(
        'recording_start_failed',
        fields: <String, Object?>{
          'error': e.runtimeType.toString(),
          'code': e is RecorderException ? e.code.name : null,
        },
      );
      // Nothing was finalized, so the partial artefact stays on disk (§18).
      await _abortQuietly();
      _dispatch(
        CaptureFailed(
          code: e is RecorderException
              ? e.code
              : RecorderErrorCode.captureFailed,
          message: e is RecorderException
              ? e.message
              : 'The recording could not be started.',
          retainedArtifactPath: null,
        ),
      );
    } finally {
      if (!started) {
        await _teardownOverlays();
      }
    }
  }

  /// Best-effort abort. Never throws: it runs on the failure path, where a
  /// second exception would replace the real one.
  Future<void> _abortQuietly() async {
    try {
      await _recorder.abort().timeout(platformCallTimeout);
    } on Object catch (e) {
      _logger.warn(
        'abort_failed',
        fields: <String, Object?>{'error': e.runtimeType.toString()},
      );
    }
  }

  Future<void> _showCameraPreview() async {
    final DisplayGeometry? display = _currentDisplay;
    final CaptureSource? source = _catalog.selected;
    if (display == null || source == null) {
      return;
    }
    await _overlays.showCameraPreview(
      sourceType: source.type,
      display: display,
      configuration: const CameraOverlayConfiguration(),
    );
  }

  /// Runs one control's command: guarded against a double click, bounded by a
  /// deadline, and unable to end a healthy session by accident.
  ///
  /// The strip fires these from a click, and a platform round trip is long
  /// enough to click through twice — hence the latch. Every other platform
  /// call in this class already carries [platformCallTimeout]; these four were
  /// the exception, and they are the ones behind a button floating over
  /// someone else's work, where a control that has silently stopped answering
  /// is indistinguishable from a broken application.
  ///
  /// Neither a deadline nor a refusal is fatal. A refusal means the platform
  /// is already in the state that was asked for, and a deadline means we do
  /// not know — either way the recording underneath is still healthy, so the
  /// strip is resynced from the state the application still believes in and
  /// the session carries on. [onFailed] decides only what an *unexpected*
  /// failure means for that particular control.
  Future<void> _runStripCommand(
    StripControl control,
    Future<void> Function() body, {
    required void Function(RecorderException error) onFailed,
  }) async {
    if (!_inFlight.add(control)) {
      return;
    }
    try {
      await body();
    } on TimeoutException {
      _logger.warn(
        'strip_command_timed_out',
        fields: <String, Object?>{
          'control': control.name,
          'phase': _state.phase.name,
        },
      );
      await _pushOverlayState();
    } on RecorderException catch (e) {
      if (e.code == RecorderErrorCode.invalidState) {
        _logger.warn(
          'strip_command_refused',
          fields: <String, Object?>{
            'control': control.name,
            'phase': _state.phase.name,
          },
        );
        await _pushOverlayState();
      } else {
        onFailed(e);
        // Resynced whatever [onFailed] decided. A control that failed must
        // stop showing the change it did not make; the push is dropped when
        // the failure ended the session, because there is no strip left.
        await _pushOverlayState();
      }
    } on Object catch (e) {
      // These run from `unawaited`, so anything that escapes here is a silent
      // error nobody ever sees. A control that misbehaves must still leave a
      // record and a strip that shows the truth.
      _logger.error(
        'strip_command_failed',
        fields: <String, Object?>{
          'control': control.name,
          'error': e.runtimeType.toString(),
        },
      );
      await _pushOverlayState();
    } finally {
      _inFlight.remove(control);
    }
  }

  Future<void> pauseOrResume() async {
    final SessionState current = _state;
    if (current is! SessionActive || current.isStopping) {
      return;
    }
    await _runStripCommand(
      StripControl.pauseOrResume,
      () async {
        if (current.isPaused) {
          await _recorder.resume().timeout(platformCallTimeout);
          _dispatch(const RecordingResumed());
        } else {
          await _recorder.pause().timeout(platformCallTimeout);
          _dispatch(const RecordingPaused());
        }
        await _pushOverlayState();
      },
      // Pause and Resume speak for the session itself, so a failure that is
      // not a refusal is a capture failure (§9).
      onFailed: (RecorderException e) =>
          _dispatch(CaptureFailed(code: e.code, message: e.message)),
    );
  }

  Future<void> stop() async {
    final SessionState current = _state;
    if (current is! SessionActive || current.isStopping) {
      return;
    }
    _dispatch(const StopRequested());
    await _pushOverlayState();

    // Finalization can take a while on a long recording, so it gets a longer
    // deadline than an ordinary call — but it still gets one, and the panel is
    // restored either way.
    try {
      _dispatch(const FinalizationStarted());
      final RecordingFile recording = await _recorder.stop().timeout(
        finalizationTimeout,
      );
      // A successful stop consumed its own .part; re-scan so the recovery
      // list does not keep offering an artefact that no longer exists.
      await _recovery.scan();
      _dispatch(
        RecordingFinalized(recording, RecordingNaming.defaultName(_clock())),
      );
      await _adoptFinalizedName();
    } on Object catch (e) {
      _logger.error(
        'finalization_failed',
        fields: <String, Object?>{
          'error': e.runtimeType.toString(),
          'code': e is RecorderException ? e.code.name : null,
        },
      );
      _dispatch(
        CaptureFailed(
          code: e is RecorderException
              ? e.code
              : RecorderErrorCode.finalizationFailed,
          message: e is RecorderException
              ? e.message
              : 'The recording could not be written out. The partial file was '
                    'kept.',
          retainedArtifactPath: _activeRecordingId == null
              ? null
              : '${_store.directory.path}/recording-$_activeRecordingId${RecordingStore.partSuffix}',
        ),
      );
    } finally {
      await _teardownOverlays();
    }
  }

  /// Moves the finalized `recording-<id>.mp4` onto its user-facing name.
  Future<void> _adoptFinalizedName() async {
    final SessionState current = _state;
    if (current is! SessionReady) {
      return;
    }
    try {
      final RecordingFile renamed = await _store.rename(
        current.recording,
        current.name,
      );
      _dispatch(RecordingRenamed(current.name, recording: renamed));
    } on RecorderException catch (e) {
      _logger.warn(
        'initial_rename_failed',
        fields: <String, Object?>{'code': e.code.name},
      );
    }
  }

  /// Restores the panel and removes the overlays. Every step is independent so
  /// one failure cannot leave the window hidden.
  Future<void> _teardownOverlays() async {
    for (final Future<void> Function() step in <Future<void> Function()>[
      _overlays.hideCameraPreview,
      _overlays.hideControlStrip,
      () => _overlays.setMainWindowVisible(true),
    ]) {
      try {
        await step().timeout(platformCallTimeout);
      } on Object catch (e) {
        _logger.warn(
          'overlay_teardown_failed',
          fields: <String, Object?>{'error': e.runtimeType.toString()},
        );
      }
    }
  }

  // ── runtime input toggles ─────────────────────────────────────────────────

  /// An input that refuses to change is not the same as an input that has gone
  /// away, and only the platform knows which happened: it emits a non-fatal
  /// error event of its own when a source is genuinely lost, and that is what
  /// degrades the session (`InputBecameUnavailable`). Guessing here would mute
  /// a microphone that is still working, so a failed toggle only resyncs the
  /// strip and leaves the recording exactly as it was.
  void _keepInputAsItWas(RecorderException error) => _logger.warn(
    'input_toggle_failed',
    fields: <String, Object?>{'code': error.code.name},
  );

  Future<void> toggleMicrophone() async {
    final SessionState current = _state;
    if (current is! SessionActive || !current.microphoneAvailable) {
      return;
    }
    await _runStripCommand(StripControl.microphone, () async {
      final bool next = !current.microphoneEnabled;
      await _recorder.setMicrophoneEnabled(next).timeout(platformCallTimeout);
      _dispatch(
        InputsChanged(
          microphoneEnabled: next,
          cameraEnabled: current.cameraEnabled,
          systemAudioEnabled: current.systemAudioEnabled,
        ),
      );
      await _pushOverlayState();
    }, onFailed: _keepInputAsItWas);
  }

  Future<void> toggleSystemAudio() async {
    final SessionState current = _state;
    if (current is! SessionActive || !current.systemAudioAvailable) {
      return;
    }
    await _runStripCommand(StripControl.systemAudio, () async {
      final bool next = !current.systemAudioEnabled;
      await _recorder.setSystemAudioEnabled(next).timeout(platformCallTimeout);
      _dispatch(
        InputsChanged(
          microphoneEnabled: current.microphoneEnabled,
          cameraEnabled: current.cameraEnabled,
          systemAudioEnabled: next,
        ),
      );
      await _pushOverlayState();
    }, onFailed: _keepInputAsItWas);
  }

  Future<void> toggleCamera() async {
    final SessionState current = _state;
    if (current is! SessionActive || !current.cameraAvailable) {
      return;
    }
    await _runStripCommand(StripControl.camera, () async {
      final bool next = !current.cameraEnabled;
      await _recorder.setCameraEnabled(next).timeout(platformCallTimeout);
      if (next) {
        await _showCameraPreview().timeout(platformCallTimeout);
      } else {
        await _overlays.hideCameraPreview().timeout(platformCallTimeout);
      }
      _dispatch(
        InputsChanged(
          microphoneEnabled: current.microphoneEnabled,
          cameraEnabled: next,
          systemAudioEnabled: current.systemAudioEnabled,
        ),
      );
      await _pushOverlayState();
    }, onFailed: _keepInputAsItWas);
  }

  // ── post recording ────────────────────────────────────────────────────────

  Future<void> renameRecording(String rawName) async {
    final SessionState current = _state;
    if (current is! SessionReady) {
      return;
    }
    final String? name = RecordingNaming.sanitize(rawName);
    if (name == null || name == current.name) {
      return;
    }
    try {
      final RecordingFile renamed = await _store.rename(
        current.recording,
        name,
      );
      _dispatch(RecordingRenamed(name, recording: renamed));
    } on RecorderException catch (e) {
      _logger.warn(
        'rename_failed',
        fields: <String, Object?>{'code': e.code.name},
      );
    }
  }

  /// Deletes the local recording on the user's explicit instruction.
  ///
  /// The confirmation dialog is a UI gate; this method is the guard against
  /// double invocation (`docs/adr/2026-08-22-delete-confirmation.md`).
  Future<void> deleteRecording() async {
    final RecordingFile? recording = _state.file;
    if (recording == null) {
      return;
    }
    _dispatch(const LocalDeletionStarted(DeletionReason.userRequested));
    if (_state is! SessionDeleting) {
      return;
    }
    await _performDeletion(recording, DeletionReason.userRequested);
  }

  Future<void> _performDeletion(
    RecordingFile recording,
    DeletionReason reason,
  ) async {
    try {
      await _store.delete(recording, reason);
      // Send and Delete are the other two ways out of the post-recording
      // screen, and they leave it just as finally as New recording does. Only
      // releasing on the third one left the platform still holding the finished
      // session on the two commonest paths.
      unawaited(_releaseSessionQuietly());
      _dispatch(const LocalDeletionCompleted());
      _activeRecordingId = null;
    } on Object catch (e) {
      _logger.error(
        'local_delete_failed',
        fields: <String, Object?>{
          'reason': reason.name,
          'error': e.runtimeType.toString(),
        },
      );
      _dispatch(
        const LocalDeletionFailed(
          'The recording could not be removed from disk.',
        ),
      );
    }
  }

  Future<void> send({String? destinationId}) async {
    final SessionState current = _state;
    final RecordingFile? recording = current.file;
    if (recording == null ||
        (current is! SessionReady && current is! SessionUploadFailed)) {
      return;
    }
    final String name = switch (current) {
      SessionReady(:final String name) => name,
      SessionUploadFailed(:final String name) => name,
      _ => recording.recordingId,
    };
    final String target =
        destinationId ?? _settings.settings.uploadDestinationId;

    _dispatch(UploadRequested(target));
    if (_state is! SessionUploading) {
      return;
    }
    await _uploads.start(
      destinationId: target,
      file: UploadFile(
        path: recording.path,
        sizeBytes: recording.sizeBytes,
        displayName: RecordingNaming.fileName(name),
        duration: recording.duration,
      ),
    );
  }

  Future<void> cancelUpload() async {
    if (_state is! SessionUploading) {
      return;
    }
    _dispatch(const UploadCancellationRequested());
    await _uploads.cancel();
  }

  /// "Keep the file and decide later" (design `1k`).
  void keepRecordingForLater() => _leaveFinishedRecording();

  void startNewSession() => _leaveFinishedRecording();

  /// Leaves the post-recording screen, releasing the session behind it.
  ///
  /// Returning to the recorder used to be a pure state transition, so the
  /// platform went on holding the finished session — a configured camera and
  /// microphone, and whatever a stop that did not go cleanly left behind —
  /// until the process exited. "The recording is over" has to be true of the
  /// hardware, not only of the screen.
  ///
  /// The release is not awaited: it touches nothing the next session needs, and
  /// leaving the post-recording screen must not wait on a platform round trip.
  /// It is ordered before the dispatch so a release and the next `prepare`
  /// cannot cross.
  void _leaveFinishedRecording() {
    unawaited(_releaseSessionQuietly());
    _dispatch(const SessionReset());
  }

  /// Best-effort release. Never throws: nothing the user did is undone by a
  /// platform that cannot answer, and the next `prepare` releases again.
  Future<void> _releaseSessionQuietly() async {
    try {
      await _recorder.releaseSession().timeout(platformCallTimeout);
    } on Object catch (e) {
      _logger.warn(
        'session_release_failed',
        fields: <String, Object?>{'error': e.runtimeType.toString()},
      );
    }
  }

  // ── startup recovery (§18) ────────────────────────────────────────────────

  Future<void> recoverArtifact(IncompleteRecordingArtifact artifact) async {
    _setBusy(true);
    try {
      final RecordingFile? recovered = await _recovery.finalize(artifact);
      if (recovered == null) {
        notifyListeners();
        return;
      }
      _dispatch(
        RecordingFinalized(recovered, RecordingNaming.defaultName(_clock())),
      );
      await _adoptFinalizedName();
    } finally {
      _setBusy(false);
    }
  }

  /// Leaves the artefact exactly where it is.
  void keepArtifacts() {
    _recovery.dismiss();
    notifyListeners();
  }

  Future<void> discardArtifact(IncompleteRecordingArtifact artifact) async {
    await _recovery.discard(artifact);
    notifyListeners();
  }

  // ── event plumbing ────────────────────────────────────────────────────────

  void _onRecorderEvent(RecorderEvent event) {
    switch (event) {
      case RecorderTickEvent(:final Duration elapsed):
        _dispatch(RecordingTicked(elapsed));
        unawaited(_pushOverlayState());
      case RecorderInputChangedEvent(
        :final bool microphoneEnabled,
        :final bool cameraEnabled,
        :final bool systemAudioEnabled,
      ):
        _dispatch(
          InputsChanged(
            microphoneEnabled: microphoneEnabled,
            cameraEnabled: cameraEnabled,
            systemAudioEnabled: systemAudioEnabled,
          ),
        );
        unawaited(_pushOverlayState());
      case RecorderErrorEvent(
        :final RecorderErrorCode code,
        :final String message,
        :final bool fatal,
      ):
        if (fatal) {
          // The platform is expected to release its own capture on a fatal
          // error, but "expected to" is not a guarantee the application can
          // rely on: an abort here is idempotent on both platforms and is the
          // difference between a failed session and a camera light that stays
          // on for the life of the process.
          unawaited(_abortQuietly());
          unawaited(_teardownOverlays());
          _dispatch(CaptureFailed(code: code, message: message));
        } else {
          _dispatch(InputBecameUnavailable(code));
          unawaited(_pushOverlayState());
        }
      case RecorderStatsEvent():
        _logger.debug(
          'recorder_stats',
          fields: <String, Object?>{
            'droppedFrames': event.droppedFrames,
            'encodedFrames': event.encodedFrames,
            'avDriftMs': event.avDriftMs,
            'encoder': event.encoderName,
            'hardwareEncoding': event.hardwareEncoding,
          },
        );
      case RecorderStateEvent():
        _logger.debug(
          'platform_state',
          fields: <String, Object?>{'state': event.state.name},
        );
    }
  }

  void _onOverlayCommand(OverlayCommand command) {
    switch (command) {
      case OverlayCommand.toggleMicrophone:
        unawaited(toggleMicrophone());
      case OverlayCommand.toggleCamera:
        unawaited(toggleCamera());
      case OverlayCommand.toggleSystemAudio:
        unawaited(toggleSystemAudio());
      case OverlayCommand.pauseOrResume:
        unawaited(pauseOrResume());
      case OverlayCommand.stop:
        unawaited(stop());
    }
  }

  void _onUploadEvent(UploadEvent event) {
    final SessionEvent? mapped = sessionEventForUpload(event);
    if (mapped == null) {
      return;
    }
    // Read before dispatching: a confirmed success moves the session into
    // `deleting`, and the file it is about to remove is the one the *previous*
    // state was holding.
    final RecordingFile? recording = _state.file;
    _dispatch(mapped);

    // The only deletion the upload side may cause, and only after the remote
    // object exists (§13, §18). Everything else about an upload is a state
    // change; this is the one that touches the user's disk.
    if (event is UploadSucceeded &&
        recording != null &&
        _state is SessionDeleting) {
      unawaited(
        _performDeletion(recording, DeletionReason.confirmedUploadSuccess),
      );
    }
  }

  Future<void> _pushOverlayState() async {
    final SessionState current = _state;
    if (current is! SessionActive) {
      return;
    }
    await _overlays.push(
      RecordingOverlayState(
        isPaused: current.isPaused,
        elapsed: current.elapsed,
        microphoneEnabled: current.microphoneEnabled,
        cameraEnabled: current.cameraEnabled,
        systemAudioEnabled: current.systemAudioEnabled,
        microphoneAvailable: current.microphoneAvailable,
        cameraAvailable: current.cameraAvailable,
        systemAudioAvailable: current.systemAudioAvailable,
        isStopping: current.isStopping,
      ),
    );
  }

  void _dispatch(SessionEvent event) {
    final SessionTransition transition = _machine.apply(_state, event);
    if (transition.rejected) {
      _logger.debug(
        'session_event_rejected',
        fields: <String, Object?>{
          'event': event.runtimeType.toString(),
          'phase': _state.phase.name,
          'reason': transition.reason,
        },
      );
      return;
    }
    final SessionPhase before = _state.phase;
    _state = transition.state;
    if (before != _state.phase) {
      _logger.info(
        'session_phase',
        fields: <String, Object?>{'from': before.name, 'to': _state.phase.name},
      );
    }
    notifyListeners();
  }

  void _setBusy(bool value) {
    if (_busy == value) {
      return;
    }
    _busy = value;
    notifyListeners();
  }

  /// The destination the next Send would use.
  String get activeDestinationId => _settings.settings.uploadDestinationId;

  /// Where recordings are written when Settings has no override.
  String get defaultRecordingsDirectoryPath => _store.directory.path;

  DestinationRegistry get destinations => _destinations;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_recorderEvents?.cancel());
    unawaited(_overlayCommands?.cancel());
    unawaited(_uploadEvents?.cancel());
    // The platform session outlives this object unless it is told not to.
    // Cancelling the event subscriptions above only stops us hearing from a
    // capture that is still running.
    unawaited(_disposeRecorderQuietly());
    super.dispose();
  }

  Future<void> _disposeRecorderQuietly() async {
    try {
      await _recorder.dispose().timeout(platformCallTimeout);
    } on Object catch (e) {
      _logger.warn(
        'recorder_dispose_failed',
        fields: <String, Object?>{'error': e.runtimeType.toString()},
      );
    }
  }
}
