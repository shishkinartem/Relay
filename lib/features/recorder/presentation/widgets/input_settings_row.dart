import 'package:flutter/widgets.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../../app/app_scope.dart';
import '../../../../design_system/design_system.dart';
import '../../application/recorder_view_model.dart';

/// One input on the launch screen: On / Off on the row, everything else behind
/// a disclosure (§33.2).
///
/// Closed, this is the row that shipped. Open, it names the device the input
/// will actually open, lets the user pick another one, and — for the microphone
/// — proves it is hearing something before the recording rather than after it.
class InputSettingsRow extends StatefulWidget {
  const InputSettingsRow({
    super.key,
    required this.kind,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onEnabledChanged,
    this.fixedDeviceLabel,
  });

  final MediaDeviceKind kind;
  final AppIconData icon;
  final String label;

  /// What to call the one thing this input records when the platform offers no
  /// choice and enumerates no device — macOS's system mix, which is a real
  /// input with no endpoint behind it (§33.8).
  final String? fixedDeviceLabel;

  /// The input's On / Off state, which is not a device concern.
  final bool enabled;

  /// Null when the platform does not support this input at all.
  final ValueChanged<bool>? onEnabledChanged;

  @override
  State<InputSettingsRow> createState() => _InputSettingsRowState();
}

class _InputSettingsRowState extends State<InputSettingsRow> {
  /// Whether the device list is unrolled. Local, and deliberately not
  /// persisted: a list left open from a previous launch is a list the user has
  /// to close before they can read the row under it.
  bool _picking = false;

  /// The last metering state this row asked for, so a rebuild that changes
  /// nothing does not restart a tap.
  bool _metering = false;

  /// Held rather than looked up on demand: [dispose] has to close the tap this
  /// row opened, and by then the element is deactivated and an inherited-widget
  /// lookup is an error.
  RecorderViewModel? _vm;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _vm = AppScope.of(context).recorder;
    _syncMetering();
  }

  @override
  void dispose() {
    // The row is going away; whatever it opened has to close with it, or a
    // device stays open for a bar nobody is looking at (§33.7).
    if (_metering) {
      _metering = false;
      _vm?.stopMetering(widget.kind);
    }
    super.dispose();
  }

  /// Meters only while there is a meter on screen and something to meter.
  ///
  /// Scheduled rather than called inline: this runs from
  /// [didChangeDependencies], the view model notifies its listeners when
  /// metering starts, and notifying during a build is an error.
  void _syncMetering() {
    final RecorderViewModel? vm = _vm;
    if (vm == null) {
      return;
    }
    final bool wanted =
        vm.canMeter(widget.kind) &&
        vm.isInputExpanded(widget.kind) &&
        widget.enabled;
    if (wanted == _metering) {
      return;
    }
    _metering = wanted;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (wanted) {
        vm.startMetering(widget.kind);
      } else {
        vm.stopMetering(widget.kind);
      }
    });
  }

  @override
  void didUpdateWidget(InputSettingsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled != widget.enabled) {
      _syncMetering();
    }
  }

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    final bool expanded = vm.isInputExpanded(widget.kind);

    return AppDisclosure(
      semanticLabel: '${widget.label} settings',
      expanded: expanded,
      onToggle: (bool next) {
        if (!next) {
          setState(() => _picking = false);
        }
        vm.setInputExpanded(widget.kind, next);
      },
      header: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppIcon(widget.icon, size: 15),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.bodySmall,
            ),
          ),
        ],
      ),
      headerTrailing: AppOnOffControl(
        semanticLabel: widget.label,
        value: widget.enabled,
        onChanged: widget.onEnabledChanged,
      ),
      child: _Details(
        kind: widget.kind,
        label: widget.label,
        fixedDeviceLabel: widget.fixedDeviceLabel,
        inputEnabled: widget.enabled,
        picking: _picking,
        onPickingChanged: (bool next) => setState(() => _picking = next),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({
    required this.kind,
    required this.label,
    required this.fixedDeviceLabel,
    required this.inputEnabled,
    required this.picking,
    required this.onPickingChanged,
  });

  final MediaDeviceKind kind;
  final String label;
  final String? fixedDeviceLabel;
  final bool inputEnabled;
  final bool picking;
  final ValueChanged<bool> onPickingChanged;

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    final bool choosable = vm.canChooseDevice(kind);
    final List<MediaDevice> devices = vm.devicesFor(kind);
    final MediaDevice? selection = vm.deviceSelectionFor(kind);
    final MediaDevice? effective = vm.effectiveDeviceFor(kind);
    final String? unresolved = vm.unresolvedDevices[kind];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppSelectField(
          semanticLabel: '$label device',
          label: effective?.label ?? fixedDeviceLabel ?? _nothingFound,
          meta: _fieldMeta(choosable, selection, effective),
          expanded: picking,
          onPressed: choosable && devices.isNotEmpty
              ? () => onPickingChanged(!picking)
              : null,
        ),
        if (picking && choosable) ...<Widget>[
          const SizedBox(height: 4),
          _DeviceList(
            kind: kind,
            devices: devices,
            selection: selection,
            onChosen: (MediaDevice? device) {
              vm.selectInputDevice(kind, device);
              onPickingChanged(false);
            },
          ),
        ],
        if (unresolved != null) ...<Widget>[
          const SizedBox(height: 7),
          AppMonoText('“$unresolved” was not found · using the default'),
        ],
        if (kind == MediaDeviceKind.camera) ...<Widget>[
          const SizedBox(height: 9),
          const _CameraPresets(),
          const SizedBox(height: 9),
          const _CameraPosition(),
        ],
        if (vm.canMeter(kind)) ...<Widget>[
          const SizedBox(height: 9),
          _Meter(kind: kind, label: label, inputEnabled: inputEnabled),
        ],
      ],
    );
  }

  static const String _nothingFound = 'No device found';

  /// The word beside the device name. It answers a different question in each
  /// case, so it is never a decoration: whether the choice is the platform's,
  /// whether there is a choice at all, and whether the device can be opened.
  String? _fieldMeta(
    bool choosable,
    MediaDevice? selection,
    MediaDevice? effective,
  ) {
    if (!choosable) {
      // There is nothing to pick, so the word says why rather than describing
      // a choice that does not exist.
      return 'not selectable here';
    }
    if (effective == null) {
      return null;
    }
    if (!effective.isAvailable) {
      return 'in use';
    }
    return selection == null ? 'default' : null;
  }
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({
    required this.kind,
    required this.devices,
    required this.selection,
    required this.onChosen,
  });

  final MediaDeviceKind kind;
  final List<MediaDevice> devices;
  final MediaDevice? selection;
  final ValueChanged<MediaDevice?> onChosen;

  @override
  Widget build(BuildContext context) {
    final MediaDevice? systemDefault = devices
        .where((MediaDevice d) => d.isSystemDefault)
        .firstOrNull;
    return BlueprintFrame(
      showCorners: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // Its own row, because "follow whatever the system defaults to" is a
          // different answer from naming the device that is the default today.
          AppOptionTile(
            label: 'System default',
            meta: systemDefault?.label,
            selected: selection == null,
            onPressed: () => onChosen(null),
          ),
          for (final MediaDevice device in devices)
            AppOptionTile(
              label: device.label,
              meta: device.isAvailable ? null : 'in use',
              selected: selection?.id == device.id,
              enabled: device.isAvailable,
              onPressed: () => onChosen(device),
            ),
        ],
      ),
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter({
    required this.kind,
    required this.label,
    required this.inputEnabled,
  });

  final MediaDeviceKind kind;
  final String label;
  final bool inputEnabled;

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    final InputLevel level = vm.levelFor(kind);
    final bool running = vm.isMeterRunningFor(kind);
    final bool silent = vm.isInputSilent(kind);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppKicker(_caption(running, silent)),
        const SizedBox(height: 5),
        AppLevelMeter(
          level: level.rms,
          peak: level.peak,
          enabled: running,
          semanticLabel: '$label level',
        ),
        if (silent) ...<Widget>[
          const SizedBox(height: 6),
          const AppMonoText(
            'nothing has reached this input · check its hardware switch',
          ),
        ],
      ],
    );
  }

  String _caption(bool running, bool silent) {
    if (!inputEnabled) {
      return 'Test — input is off';
    }
    if (!running) {
      return 'Test — unavailable';
    }
    return silent ? 'Test — no sound' : 'Test — speak now';
  }
}

/// The tile's shape and size: three presets, not a number (§33.5).
///
/// `Camera` keeps the sensor's own shape and crops nothing — the default, and
/// the behaviour that shipped before presets existed. `Square` and `Circle` are
/// small and take the centre of the frame, which is the point of choosing them.
class _CameraPresets extends StatelessWidget {
  const _CameraPresets();

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const AppKicker('Shape and size'),
        const SizedBox(height: 7),
        // The same component the camera sheet draws during recording: one
        // choice, drawn once, so the two cannot disagree about what a preset
        // looks like (§33.5).
        CameraPresetTiles(
          selected: vm.cameraPreset,
          onChoose: vm.setCameraPreset,
        ),
      ],
    );
  }
}

/// Where the tile goes, chosen before recording (§33.5).
///
/// The shape could be chosen here and the place could not, in either mode: the
/// only placement control that existed was the camera sheet's, which the strip
/// opens during a recording and which offers corners in window mode alone. A
/// user who wanted the tile out of the lower right had to start a recording to
/// move it.
///
/// **Corners only, deliberately.** A free position is what a drag produces, and
/// a drag needs the live preview, which exists only inside a session. Offering
/// a free position here would need a canvas proxy the design does not have, and
/// inventing one is exactly what `CLAUDE.md` says not to do — so this offers
/// the four places that *are* nameable without a picture of the screen.
///
/// **design gap:** the connected design draws no camera placement control, and
/// no `Shape and size` block either; both post-date it. Recorded in
/// `design/README.md` rather than designed around here.
class _CameraPosition extends StatelessWidget {
  const _CameraPosition();

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        const AppKicker('Position'),
        const SizedBox(height: 7),
        // The same component the camera sheet draws during recording, for the
        // same reason the presets share one: two drawings of one choice drift.
        CameraCornerTiles(
          // Null while a dragged position is stored — the tile is in none of
          // the four, and drawing one as chosen would say it is.
          selected: vm.hasFreeCameraPipPosition ? null : vm.cameraCorner,
          onChoose: vm.setCameraCorner,
        ),
        if (vm.cameraTileIsDraggable) ...<Widget>[
          const SizedBox(height: 7),
          // With a display source the preview *is* the tile (design `1p`), so
          // the corner above is where it starts and a drag can put it anywhere.
          // Said in words because nothing on this screen shows it: the preview
          // only exists once recording has begun. With a window source there is
          // nothing to drag (design `1e`), so the corner is the whole answer
          // and this would be a promise the session does not keep.
          const AppMonoText(
            'the tile starts here · drag the preview to move it while recording',
          ),
        ],
      ],
    );
  }
}
