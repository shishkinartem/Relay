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
import 'device_catalog.dart';
import 'input_meter.dart';
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
    DeviceCatalog? deviceCatalog,
    InputMeter? inputMeter,
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
       _devices =
           deviceCatalog ??
           PlatformDeviceCatalog(
             provider: recorder,
             logger: _logger,
             timeout: platformCallTimeout,
           ),
       _meter =
           inputMeter ??
           PlatformInputMeter(provider: recorder, logger: _logger),
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
  final DeviceCatalog _devices;
  final InputMeter _meter;
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
  StreamSubscription<InputMenuSelection>? _menuSelections;
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
  bool _disposed = false;

  SessionState get state => _state;
  RecorderCapabilities get capabilities => _capabilities;
  DisplayGeometry? get currentDisplay => _currentDisplay;
  List<CaptureSource> get sources => _catalog.sources;
  CaptureSource? get selectedSource => _catalog.selected;

  // ── inputs: which device, and is it hearing anything (§33.2) ─────────────

  /// Every device of [kind], system default first.
  List<MediaDevice> devicesFor(MediaDeviceKind kind) =>
      _devices.devicesFor(kind);

  /// The explicit choice, or null for "whatever the system defaults to".
  MediaDevice? deviceSelectionFor(MediaDeviceKind kind) =>
      _devices.selectionFor(kind);

  /// The device that will actually be opened — what the screen names.
  MediaDevice? effectiveDeviceFor(MediaDeviceKind kind) =>
      _devices.effectiveDeviceFor(kind);

  /// Kinds whose remembered device was not found, and the name it had.
  Map<MediaDeviceKind, String> get unresolvedDevices => _devices.unresolved;

  bool get isDiscoveringDevices => _devices.isLoading;

  RecorderErrorCode? get deviceLoadFailure => _devices.lastFailure;

  bool canChooseDevice(MediaDeviceKind kind) =>
      _capabilities.selectableDeviceKinds.contains(kind);

  bool canMeter(MediaDeviceKind kind) => _meter.canMeter(kind);

  InputLevel levelFor(MediaDeviceKind kind) => _meter.levelFor(kind);

  bool isMeterRunningFor(MediaDeviceKind kind) => _meter.isRunningFor(kind);

  bool isInputSilent(MediaDeviceKind kind) => _meter.isSilentFor(kind);

  /// Whether [kind]'s detail section is open on the launch screen.
  bool isInputExpanded(MediaDeviceKind kind) =>
      settings.expandedInputs.contains(kind);

  // ── the camera tile: three presets and a place to put it (§33.5) ─────────

  CameraPipPreset get cameraPreset => settings.cameraPipPreset;

  /// The tile as the compositor and the preview both resolve it.
  ///
  /// Built from the preset every time rather than stored: the preset *is* the
  /// size and the shape, and a stored configuration would be a second copy of
  /// the same answer that could disagree with it.
  CameraOverlayConfiguration get cameraOverlay =>
      CameraOverlayConfiguration.forPreset(
        settings.cameraPipPreset,
        position: settings.cameraPipPosition,
        corner: settings.cameraPipCorner,
      );

  /// Chooses the tile's shape and size. Applied to a live recording between
  /// frames; the encoder's canvas never changes (§33.5).
  Future<void> setCameraPreset(CameraPipPreset preset) async {
    if (preset == settings.cameraPipPreset) {
      return;
    }
    await _settings.update(settings.copyWith(cameraPipPreset: preset));
    notifyListeners();
    await _pushCameraOverlay();
  }

  /// Puts the tile in a named corner (§33.5).
  ///
  /// The window-mode answer to the drag: there the preview is a separate
  /// captioned object rather than the tile (design `1e`), so there is nothing
  /// on screen to drag and nothing that would show where a drag had put it. A
  /// named corner is legible without a preview, which is why it is the choice
  /// offered instead of a free position.
  ///
  /// Choosing one clears any free position: the two are alternative answers to
  /// the same question, and a stored fraction would silently win over the
  /// corner the user just picked.
  Future<void> setCameraCorner(CameraOverlayCorner corner) async {
    if (corner == settings.cameraPipCorner &&
        settings.cameraPipPosition == null) {
      return;
    }
    await _settings.update(
      settings.copyWith(cameraPipCorner: corner, cameraPipPosition: null),
    );
    notifyListeners();
    await _pushCameraOverlay();
  }

  /// Puts the tile back in its corner (§33.5).
  Future<void> resetCameraPipPosition() async {
    if (settings.cameraPipPosition == null) {
      return;
    }
    await _settings.update(settings.copyWith(cameraPipPosition: null));
    notifyListeners();
    await _pushCameraOverlay();
  }

  /// Best-effort: a tile that could not be re-pointed keeps drawing where it
  /// was, which is wrong but harmless, and is not worth ending a recording for.
  Future<void> _pushCameraOverlay() async {
    if (_state is! SessionActive) {
      return;
    }
    try {
      await _recorder
          .setCameraOverlay(cameraOverlay)
          .timeout(platformCallTimeout);
    } on Object catch (e) {
      _logger.warn(
        'camera_overlay_not_applied',
        fields: <String, Object?>{'error': e.runtimeType.toString()},
      );
    }
  }

  /// Persists where the user dragged the tile.
  ///
  /// Read at teardown, like the strip's position and for the same reason: a
  /// mid-session experiment that ends in a crash does not become the next
  /// recording's default (§33.5). Null in window mode, where the preview is not
  /// the tile — there is nothing to remember from a drag that moved a captioned
  /// object.
  Future<void> _rememberCameraPipPosition() async {
    try {
      final Offset? position = await _recorder.cameraPreviewPosition().timeout(
        platformCallTimeout,
      );
      if (position == null || position == settings.cameraPipPosition) {
        return;
      }
      await _settings.update(settings.copyWith(cameraPipPosition: position));
    } on Object catch (e) {
      _logger.warn(
        'camera_pip_position_not_read',
        fields: <String, Object?>{'error': e.runtimeType.toString()},
      );
    }
  }

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
    _menuSelections = _overlays.menuSelections.listen(_onMenuSelection);
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

    _meter.meterableKinds = _capabilities.meterableDeviceKinds;
    // Restored before the first enumeration, so a remembered id is resolved by
    // the same pass that reads the list rather than by a second one.
    _devices.restore(settings.inputDevices);

    await _recovery.scan();

    await _permissions.refresh();
    await _loadSources(refreshThumbnails: false, silent: true);
    // Every kind, not only the selectable ones: the launch screen names the
    // device even where it cannot offer a choice.
    await _devices.load(MediaDeviceKind.values.toSet());
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

  /// The kinds this platform lets the user choose between.
  ///
  /// Read from capabilities, never from an operating-system name (§28).
  Set<MediaDeviceKind> get _selectableKinds =>
      _capabilities.selectableDeviceKinds;

  /// Re-reads the device lists.
  ///
  /// Defaults to every selectable kind. A kind the platform cannot choose
  /// between is still enumerated on demand — the launch screen names the one
  /// device it will use — but it is not refreshed on every change event.
  Future<void> loadInputDevices({Set<MediaDeviceKind>? kinds}) async {
    final Set<MediaDeviceKind> targets = kinds ?? _selectableKinds;
    if (targets.isEmpty) {
      return;
    }
    notifyListeners();
    await _devices.load(targets);
    notifyListeners();
    if (_openMenu != null && targets.contains(_openMenu)) {
      await refreshInputMenu();
    }
  }

  /// Chooses the device an input will open. Null means the system default.
  ///
  /// Persisted immediately: the choice outlives the session, and a user who
  /// picks a microphone and then quits without recording still expects it to be
  /// there next time.
  Future<void> selectInputDevice(
    MediaDeviceKind kind,
    MediaDevice? device,
  ) async {
    _devices.select(kind, device);
    // What was heard from the previous device says nothing about this one.
    _meter.reset(kind);
    notifyListeners();
    if (_meter.isRunningFor(kind)) {
      // The bar has to move to the device the user just chose, or picking
      // between two microphones by speaking does not work.
      await startMetering(kind);
    }
    await _persistDeviceChoices();
  }

  /// Opens or closes an input's detail section, and remembers which.
  Future<void> setInputExpanded(MediaDeviceKind kind, bool expanded) async {
    final Set<MediaDeviceKind> next = <MediaDeviceKind>{
      ...settings.expandedInputs,
    };
    if (expanded) {
      next.add(kind);
    } else {
      next.remove(kind);
    }
    await _settings.update(settings.copyWith(expandedInputs: next));
    // A closed section has no meter to feed.
    if (!expanded) {
      await stopMetering(kind);
    }
    notifyListeners();
  }

  /// Starts the level meter for [kind], if the platform can meter it.
  ///
  /// Always on the device that input is set to, so the bar under a device row
  /// is that device. A meter showing the system default while the user picks
  /// between two microphones answers a question nobody asked.
  Future<void> startMetering(MediaDeviceKind kind) async {
    await _meter.start(kind, deviceId: _devices.deviceIdFor(kind));
    _notifyIfAlive();
  }

  Future<void> stopMetering(MediaDeviceKind kind) async {
    await _meter.stop(kind);
    _notifyIfAlive();
  }

  // ── the input menu on the strip (§33.4) ─────────────────────────────────

  /// The kind whose menu is open, or null. One at a time, by construction.
  MediaDeviceKind? get openMenuKind => _openMenu;

  MediaDeviceKind? _openMenu;

  /// Opens the device list for [kind] beside the chevron that asked for it.
  ///
  /// The placement is the host's: only it knows where the strip ended up and
  /// where the chevron is inside it. What travels from here is the content.
  Future<void> openInputMenu(MediaDeviceKind kind) async {
    if (_openMenu == kind) {
      // A second press on the same chevron closes it, which is what a menu
      // does everywhere else.
      await closeInputMenu();
      return;
    }
    _openMenu = kind;
    notifyListeners();
    await _overlays.showInputMenu(kind, menuStateFor(kind));
    // Enumerating can take a moment, and the menu is already on screen saying
    // so; the refresh below replaces the loading row in place.
    await loadInputDevices(kinds: <MediaDeviceKind>{kind});
    if (_openMenu != kind) {
      return;
    }
    await startMetering(kind);
    await refreshInputMenu();
  }

  /// Re-renders an open menu. A device that appears or disappears must not
  /// close it under the user's cursor (§33.7).
  Future<void> refreshInputMenu() async {
    final MediaDeviceKind? kind = _openMenu;
    if (kind == null) {
      return;
    }
    await _overlays.updateInputMenu(menuStateFor(kind));
  }

  /// Drops the application's belief in a menu the host has already closed.
  ///
  /// Everything [closeInputMenu] does except asking the host to close a window
  /// that is not there.
  Future<void> _forgetInputMenu(MediaDeviceKind kind) async {
    if (_openMenu != kind) {
      return;
    }
    _openMenu = null;
    notifyListeners();
    await stopMetering(kind);
  }

  Future<void> closeInputMenu() async {
    final MediaDeviceKind? kind = _openMenu;
    if (kind == null) {
      return;
    }
    _openMenu = null;
    notifyListeners();
    // The meter the menu opened closes with it, unless a launch-screen section
    // is still showing one — `stop` is reference-free here, so this is the one
    // place the two could fight. They cannot: the strip's menu only exists
    // while the main window is hidden.
    await stopMetering(kind);
    await _overlays.hideInputMenu();
  }

  /// What the menu window draws for [kind] (§33.4).
  ///
  /// Built here rather than in the menu's own engine for the reason every
  /// overlay is: the window owns no state, so it cannot drift out of step with
  /// the session that feeds it.
  InputMenuOverlayState menuStateFor(MediaDeviceKind kind) {
    final List<MediaDevice> devices = _devices.devicesFor(kind);
    final MediaDevice? selection = _devices.selectionFor(kind);
    final MediaDevice? fallback = _devices.effectiveDeviceFor(kind);
    final bool choosable = canChooseDevice(kind);
    final String? unresolved = _devices.unresolved[kind];

    return InputMenuOverlayState(
      kind: kind,
      title: _menuTitle(kind),
      loading: _devices.isLoading && devices.isEmpty,
      emptyMessage: devices.isEmpty && !_devices.isLoading
          ? _nothingFound(kind)
          : null,
      notice: unresolved == null
          ? null
          : '“$unresolved” was not found · using the default',
      level: canMeter(kind) && isMeterRunningFor(kind) ? levelFor(kind) : null,
      // The camera sheet's own control, where the microphone has its meter
      // (§33.4). Without it a preset could only be chosen before recording
      // started, which is the half of §33.5 that matters least: the shape is
      // worth changing precisely when you can see it over what you are
      // recording.
      presets: kind == MediaDeviceKind.camera
          ? CameraPipPreset.values
          : const <CameraPipPreset>[],
      selectedPreset: kind == MediaDeviceKind.camera ? cameraPreset : null,
      // Offered only once there is something to undo. The tile starts in its
      // corner, so before a drag this row would put it where it already is.
      canResetPosition:
          kind == MediaDeviceKind.camera && settings.cameraPipPosition != null,
      // Window mode only: with a display source the tile is dragged, and the
      // preview *is* the tile, so a corner list would be a second, worse answer
      // to a question already answered better (design `1e` vs `1p`, §33.5).
      corners: kind == MediaDeviceKind.camera && !_tileIsDraggable
          ? CameraOverlayCorner.values
          : const <CameraOverlayCorner>[],
      selectedCorner: kind == MediaDeviceKind.camera
          ? settings.cameraPipCorner
          : null,
      items: <InputMenuItem>[
        if (choosable && devices.isNotEmpty)
          InputMenuItem(
            label: 'System default',
            meta: fallback?.label,
            selected: selection == null,
          ),
        for (final MediaDevice device in devices)
          InputMenuItem(
            id: device.id,
            label: device.label,
            meta: device.isAvailable ? null : 'in use',
            selected: selection?.id == device.id,
            enabled: device.isAvailable && choosable,
          ),
        InputMenuItem(
          label: '${_menuTitle(kind)} off',
          selected: false,
          // The `Off` row is the strip's own toggle, reached from the menu so
          // the two are never two different answers.
          id: null,
        ),
      ],
    );
  }

  /// Whether the tile can be dragged, which is the same question as whether the
  /// preview stands for it (design `1p`).
  ///
  /// A window source composites the tile over a captured window while the
  /// preview sits somewhere else on screen entirely, so nothing on screen is
  /// the tile and there is nothing to drag.
  bool get _tileIsDraggable => selectedSource?.type != CaptureSourceType.window;

  static String _menuTitle(MediaDeviceKind kind) => switch (kind) {
    MediaDeviceKind.camera => 'Camera',
    MediaDeviceKind.microphone => 'Microphone',
    MediaDeviceKind.systemAudio => 'System audio',
  };

  static String _nothingFound(MediaDeviceKind kind) => switch (kind) {
    MediaDeviceKind.camera => 'No camera found',
    MediaDeviceKind.microphone => 'No microphone found',
    MediaDeviceKind.systemAudio => 'System mix',
  };

  /// Puts the strip back at its default dock (§33.3).
  Future<void> resetStripPosition() async {
    await _settings.update(settings.copyWith(stripPosition: null));
    notifyListeners();
    if (_state is SessionActive) {
      await _overlays.showControlStrip();
    }
  }

  /// One arrow-key step, in logical points (§33.3).
  ///
  /// Large enough that a press visibly moves the strip, small enough that
  /// landing it on a particular spot does not take a minute of holding a key.
  static const double stripNudgeStep = 8;

  /// The same, held with Shift — a coarse step for crossing a display.
  static const double stripCoarseNudgeStep = 32;

  /// Moves the strip by one step, the keyboard's half of §33.3.
  ///
  /// The host clamps and snaps exactly as it does at the end of a drag, so the
  /// two paths cannot put the strip in different places, and the arrow keys can
  /// never walk it off a display.
  Future<void> nudgeStrip(double dx, double dy) async {
    if (_state is! SessionActive) {
      return;
    }
    await _overlays.nudgeControlStrip(dx, dy);
  }

  /// Closes every meter. Called when the screen holding them goes away, so no
  /// device is left open for a bar nobody is looking at (§33.7).
  Future<void> stopAllMetering() async {
    await _meter.stopAll();
    _notifyIfAlive();
  }

  /// Notifies unless this object is already gone.
  ///
  /// Only the metering calls need it, and they need it because of the order a
  /// teardown happens in: the widget that opened a tap closes it from its own
  /// `dispose`, that call crosses the platform boundary, and by the time it
  /// returns this view model may have been disposed too. Notifying a disposed
  /// [ChangeNotifier] throws, and the throw would land in a teardown where
  /// nothing can act on it — while the thing that mattered, closing the tap,
  /// has already happened.
  void _notifyIfAlive() {
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  Future<void> _persistDeviceChoices() async {
    final Map<MediaDeviceKind, InputDeviceChoice> choices =
        <MediaDeviceKind, InputDeviceChoice>{};
    for (final MediaDeviceKind kind in MediaDeviceKind.values) {
      final MediaDevice? device = _devices.selectionFor(kind);
      if (device != null) {
        choices[kind] = InputDeviceChoice.of(device);
      }
    }
    await _settings.update(settings.copyWith(inputDevices: choices));
  }

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
              // Null for any input the user never chose, which is the platform
              // default and exactly what this application recorded before
              // devices could be chosen at all (§33.2).
              cameraDeviceId: _devices.deviceIdFor(MediaDeviceKind.camera),
              microphoneDeviceId: _devices.deviceIdFor(
                MediaDeviceKind.microphone,
              ),
              systemAudioDeviceId: _devices.deviceIdFor(
                MediaDeviceKind.systemAudio,
              ),
              // The tile the user chose, so the compositor and the preview
              // start from the same geometry rather than from the default
              // (§33.5).
              cameraOverlay: cameraOverlay,
            ),
          )
          .timeout(platformCallTimeout);

      await _overlays
          .showControlStrip(position: settings.stripPosition)
          .timeout(platformCallTimeout);
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
      configuration: cameraOverlay,
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

  /// Persists where the user left the strip, so the next session opens it
  /// there (§33.7).
  ///
  /// Best-effort and never fatal: this runs on the teardown path, including the
  /// failure one, and a position that could not be read is not worth a second
  /// exception on top of whatever ended the session.
  Future<void> _rememberStripPosition() async {
    try {
      final OverlayStripPosition? position = await _overlays
          .controlStripPosition()
          .timeout(platformCallTimeout);
      if (position == null || position == settings.stripPosition) {
        return;
      }
      await _settings.update(settings.copyWith(stripPosition: position));
    } on Object catch (e) {
      _logger.warn(
        'strip_position_not_read',
        fields: <String, Object?>{'error': e.runtimeType.toString()},
      );
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
    // Read before the strip is hidden, because a hidden window has no position
    // to report. Failing to read one keeps whatever was stored: not being able
    // to ask is not the user having dragged it back (§33.3).
    await _rememberStripPosition();
    await _rememberCameraPipPosition();
    await closeInputMenu();
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
      case RecorderInputLevelEvent(
        :final MediaDeviceKind kind,
        :final InputLevel level,
      ):
        _meter.accept(kind, level);
        // Twenty of these arrive a second. Notifying on each is what makes the
        // bar move, and it is cheap because only the meter widget rebuilds —
        // but nothing else in this class may start doing work per sample.
        notifyListeners();
      case RecorderDevicesChangedEvent(:final MediaDeviceKind? kind):
        // Something was plugged in or pulled out. Re-reading is the only way to
        // find out what, and a null kind means the platform could not say.
        unawaited(
          loadInputDevices(
            kinds: kind == null
                ? _selectableKinds
                : <MediaDeviceKind>{kind}.intersection(_selectableKinds),
          ),
        );
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
      case OverlayCommand.openMicrophoneMenu:
        unawaited(openInputMenu(MediaDeviceKind.microphone));
      case OverlayCommand.openCameraMenu:
        unawaited(openInputMenu(MediaDeviceKind.camera));
      case OverlayCommand.openSystemAudioMenu:
        unawaited(openInputMenu(MediaDeviceKind.systemAudio));
      case OverlayCommand.resetStripPosition:
        unawaited(resetStripPosition());
      case OverlayCommand.nudgeStripLeft:
        unawaited(nudgeStrip(-stripNudgeStep, 0));
      case OverlayCommand.nudgeStripRight:
        unawaited(nudgeStrip(stripNudgeStep, 0));
      case OverlayCommand.nudgeStripUp:
        unawaited(nudgeStrip(0, -stripNudgeStep));
      case OverlayCommand.nudgeStripDown:
        unawaited(nudgeStrip(0, stripNudgeStep));
      case OverlayCommand.nudgeStripLeftFar:
        unawaited(nudgeStrip(-stripCoarseNudgeStep, 0));
      case OverlayCommand.nudgeStripRightFar:
        unawaited(nudgeStrip(stripCoarseNudgeStep, 0));
      case OverlayCommand.nudgeStripUpFar:
        unawaited(nudgeStrip(0, -stripCoarseNudgeStep));
      case OverlayCommand.nudgeStripDownFar:
        unawaited(nudgeStrip(0, stripCoarseNudgeStep));
    }
  }

  /// A row of the input menu was chosen (§33.4).
  void _onMenuSelection(InputMenuSelection selection) {
    unawaited(_applyMenuSelection(selection));
  }

  Future<void> _applyMenuSelection(InputMenuSelection selection) async {
    final CameraPipPreset? preset = selection.preset;
    if (preset != null) {
      // Deliberately without closing the sheet: the tile changes shape on
      // screen under it, and comparing the three should not cost a reopen each
      // time (§33.5). The sheet is re-rendered so the new one reads selected.
      await setCameraPreset(preset);
      await refreshInputMenu();
      return;
    }
    final CameraOverlayCorner? corner = selection.corner;
    if (corner != null) {
      await setCameraCorner(corner);
      await refreshInputMenu();
      return;
    }
    if (selection.resetPosition) {
      await resetCameraPipPosition();
      await refreshInputMenu();
      return;
    }
    if (selection.dismissed) {
      // The window is already gone — the host closed it. Nothing is applied;
      // this only stops the application believing it is still there, which is
      // what made the chevron need two presses to reopen it.
      await _forgetInputMenu(selection.kind);
      return;
    }
    // The menu closes on a choice, whatever the choice turns out to cost.
    await closeInputMenu();
    if (selection.off) {
      await _setInputEnabled(selection.kind, false);
      return;
    }
    final MediaDevice? device = selection.deviceId == null
        ? null
        : _devices
              .devicesFor(selection.kind)
              .where((MediaDevice d) => d.id == selection.deviceId)
              .firstOrNull;
    if (selection.deviceId != null && device == null) {
      // Chosen and gone between the menu opening and the click landing. The
      // list the user was reading is the stale thing, so re-read it rather than
      // acting on a row that no longer names anything.
      await loadInputDevices(kinds: <MediaDeviceKind>{selection.kind});
      return;
    }
    await selectInputDevice(selection.kind, device);
    // The choice is only half applied until the *running* capture is using it.
    await _swapLiveDevice(selection.kind);
  }

  /// Points a live capture at the device the user just chose (§33.2).
  ///
  /// Guarded per control like every other strip command: a swap issued while
  /// another is in flight is dropped rather than queued, because two of them
  /// would both read the session state before either wrote it.
  Future<void> _swapLiveDevice(MediaDeviceKind kind) async {
    if (_state is! SessionActive) {
      return;
    }
    final StripControl? control = _controlFor(kind);
    if (control == null || !_inFlight.add(control)) {
      return;
    }
    try {
      await _recorder
          .selectInputDevice(kind, deviceId: _devices.deviceIdFor(kind))
          .timeout(platformCallTimeout);
    } on Object catch (e) {
      // Degrades, never stops: the previous device keeps running and the user
      // is told through the ordinary non-fatal path (§33.2).
      _logger.warn(
        'live_device_swap_failed',
        fields: <String, Object?>{
          'kind': kind.name,
          'error': e.runtimeType.toString(),
        },
      );
    } finally {
      _inFlight.remove(control);
    }
  }

  static StripControl? _controlFor(MediaDeviceKind kind) => switch (kind) {
    MediaDeviceKind.camera => StripControl.camera,
    MediaDeviceKind.microphone => StripControl.microphone,
    MediaDeviceKind.systemAudio => StripControl.systemAudio,
  };

  /// The menu's `Off` row is the strip's own toggle, reached from another
  /// place. It goes through the same guarded command so the two can never be
  /// two different answers — and it does nothing when the input is already in
  /// the state asked for, because a toggle that fired anyway would turn it back
  /// on.
  Future<void> _setInputEnabled(MediaDeviceKind kind, bool enabled) async {
    final SessionState current = _state;
    if (current is! SessionActive) {
      return;
    }
    final bool isOn = switch (kind) {
      MediaDeviceKind.microphone => current.microphoneEnabled,
      MediaDeviceKind.camera => current.cameraEnabled,
      MediaDeviceKind.systemAudio => current.systemAudioEnabled,
    };
    if (isOn == enabled) {
      return;
    }
    switch (kind) {
      case MediaDeviceKind.microphone:
        await toggleMicrophone();
      case MediaDeviceKind.camera:
        await toggleCamera();
      case MediaDeviceKind.systemAudio:
        await toggleSystemAudio();
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
        microphoneHasMenu: canChooseDevice(MediaDeviceKind.microphone),
        cameraHasMenu: canChooseDevice(MediaDeviceKind.camera),
        systemAudioHasMenu: canChooseDevice(MediaDeviceKind.systemAudio),
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
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_recorderEvents?.cancel());
    unawaited(_overlayCommands?.cancel());
    unawaited(_menuSelections?.cancel());
    unawaited(_uploadEvents?.cancel());
    // A metering tap outlives this object too, and it holds a real device.
    unawaited(_meter.stopAll());
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
