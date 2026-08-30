import 'dart:async';

import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/settings/app_settings.dart';

/// What one device enumeration produced.
///
/// Mirrors [SourceLoadResult] because the two enumerations have the same three
/// outcomes and the same reason for reporting rather than deciding: only the
/// caller knows whether a refusal is worth a screen.
enum DeviceLoadResult { loaded, skipped, failed }

/// The inputs a recording can open, and which one each is set to (§33.2).
///
/// Declared next to its consumer. Everything here is about *which* device;
/// nothing here opens, records or meters anything.
abstract interface class DeviceCatalog {
  /// Every device of [kind] the platform reported, system default first.
  List<MediaDevice> devicesFor(MediaDeviceKind kind);

  /// The device the user explicitly chose, or null for "the system default".
  ///
  /// Null is not "nothing": it is a live reference to whatever the platform
  /// currently defaults to. `System default` and "the device that happens to be
  /// the default today" are different choices and the picker offers both, so
  /// naming a device stores that device even when it is currently the default.
  MediaDevice? selectionFor(MediaDeviceKind kind);

  /// The device that will actually be opened — the explicit choice, else the
  /// platform default. Null when the platform reported no device of this kind.
  MediaDevice? effectiveDeviceFor(MediaDeviceKind kind);

  /// What travels in `RecordingConfiguration`: null means the platform default.
  String? deviceIdFor(MediaDeviceKind kind);

  bool get isLoading;

  RecorderErrorCode? get lastFailure;

  /// Remembered choices whose device was not in the last enumeration, by kind,
  /// carrying the label the choice was stored with.
  ///
  /// The launch screen says which device it could not find rather than
  /// silently recording with another one (§33.2).
  Map<MediaDeviceKind, String> get unresolved;

  /// Re-reads the device lists for [kinds].
  ///
  /// [isLoading] is true before the returned future's first suspension, so a
  /// caller may notify its own listeners immediately after calling this and
  /// again after awaiting it.
  Future<DeviceLoadResult> load(Set<MediaDeviceKind> kinds);

  /// Records an explicit choice. [device] null means "the system default".
  void select(MediaDeviceKind kind, MediaDevice? device);

  /// Applies the choices persisted from a previous launch.
  ///
  /// Held until the next [load] resolves them against real devices, so a
  /// remembered id survives being restored before the platform has answered.
  void restore(Map<MediaDeviceKind, InputDeviceChoice> remembered);
}

/// [DeviceCatalog] against the platform contract.
///
/// It reaches the platform through [MediaDeviceProvider] rather than the whole
/// [Recorder] contract, for the reason `PlatformSourceCatalog` takes
/// [CaptureSourceProvider]: enumerating is all it does, and the narrower
/// dependency is the one a substitute is easiest to satisfy.
class PlatformDeviceCatalog implements DeviceCatalog {
  PlatformDeviceCatalog({
    required this._provider,
    required this._logger,
    required this._timeout,
  });

  final MediaDeviceProvider _provider;
  final Logger _logger;
  final Duration _timeout;

  final Map<MediaDeviceKind, List<MediaDevice>> _devices =
      <MediaDeviceKind, List<MediaDevice>>{};
  final Map<MediaDeviceKind, MediaDevice> _selected =
      <MediaDeviceKind, MediaDevice>{};
  final Map<MediaDeviceKind, InputDeviceChoice> _remembered =
      <MediaDeviceKind, InputDeviceChoice>{};
  final Map<MediaDeviceKind, String> _unresolved = <MediaDeviceKind, String>{};

  bool _loading = false;
  RecorderErrorCode? _lastFailure;

  @override
  List<MediaDevice> devicesFor(MediaDeviceKind kind) =>
      _devices[kind] ?? const <MediaDevice>[];

  @override
  MediaDevice? selectionFor(MediaDeviceKind kind) => _selected[kind];

  @override
  MediaDevice? effectiveDeviceFor(MediaDeviceKind kind) =>
      _selected[kind] ?? _defaultFor(kind);

  @override
  String? deviceIdFor(MediaDeviceKind kind) => _selected[kind]?.id;

  @override
  bool get isLoading => _loading;

  @override
  RecorderErrorCode? get lastFailure => _lastFailure;

  @override
  Map<MediaDeviceKind, String> get unresolved =>
      Map<MediaDeviceKind, String>.unmodifiable(_unresolved);

  @override
  Future<DeviceLoadResult> load(Set<MediaDeviceKind> kinds) async {
    if (_loading) {
      return DeviceLoadResult.skipped;
    }
    if (kinds.isEmpty) {
      return DeviceLoadResult.loaded;
    }
    _loading = true;
    _lastFailure = null;
    try {
      bool anyFailed = false;
      // Per kind rather than one try around the loop: a camera enumeration
      // blocked behind a permission prompt must not cost the user the
      // microphone list that had already come back.
      for (final MediaDeviceKind kind in kinds) {
        anyFailed = !await _loadKind(kind) || anyFailed;
      }
      return anyFailed ? DeviceLoadResult.failed : DeviceLoadResult.loaded;
    } finally {
      // Released on every path. Left set, the first enumeration is the only one
      // that ever runs and a microphone plugged in afterwards never appears.
      _loading = false;
    }
  }

  /// True when [kind] was read. A failure leaves the previous list in place —
  /// stale devices the user can still see beat an empty panel.
  Future<bool> _loadKind(MediaDeviceKind kind) async {
    try {
      _devices[kind] = await _provider.getInputDevices(kind).timeout(_timeout);
      _reconcile(kind);
      return true;
    } on RecorderException catch (e) {
      _lastFailure = e.code;
      _logger.warn(
        'device_enumeration_failed',
        fields: <String, Object?>{'kind': kind.name, 'code': e.code.name},
      );
      return false;
    } on TimeoutException {
      // A deadline, like the source catalogue's: enumerating a camera can block
      // behind the operating system's own permission prompt, which the user may
      // never answer, and a launch screen that never finishes loading is worse
      // than one that says it could not read the list. The code names the kind
      // that did not answer, so the screen can say which input is in trouble.
      _lastFailure = _unavailableCodeFor(kind);
      _logger.warn(
        'device_enumeration_timed_out',
        fields: <String, Object?>{'kind': kind.name},
      );
      return false;
    }
  }

  static RecorderErrorCode _unavailableCodeFor(MediaDeviceKind kind) =>
      switch (kind) {
        MediaDeviceKind.camera => RecorderErrorCode.cameraUnavailable,
        MediaDeviceKind.microphone => RecorderErrorCode.microphoneUnavailable,
        MediaDeviceKind.systemAudio => RecorderErrorCode.systemAudioUnavailable,
      };

  @override
  void select(MediaDeviceKind kind, MediaDevice? device) {
    _unresolved.remove(kind);
    _remembered.remove(kind);
    if (device == null) {
      // `System default` is its own row in the picker, and choosing it means
      // "follow whatever the system defaults to" — which is a different answer
      // from naming the device that is the default right now.
      _selected.remove(kind);
      return;
    }
    _selected[kind] = device;
  }

  @override
  void restore(Map<MediaDeviceKind, InputDeviceChoice> remembered) {
    _remembered
      ..clear()
      ..addAll(remembered);
    for (final MediaDeviceKind kind in remembered.keys) {
      _reconcile(kind);
    }
  }

  /// The platform's default device for [kind], or its first, or null.
  ///
  /// Falls back to the first entry because the contract promises the default
  /// comes first: a platform that forgot the flag but kept the order still
  /// names the right device.
  MediaDevice? _defaultFor(MediaDeviceKind kind) {
    final List<MediaDevice> devices = devicesFor(kind);
    for (final MediaDevice device in devices) {
      if (device.isSystemDefault) {
        return device;
      }
    }
    return devices.isEmpty ? null : devices.first;
  }

  /// Points the selection at a real device, or reports that it cannot.
  ///
  /// Three cases, and each has to be distinguishable: a remembered id that
  /// resolves becomes the selection; one that does not becomes an
  /// [unresolved] entry and the default is used; and a device that disappeared
  /// while it was selected does the same. Silently falling back would record
  /// the wrong microphone and tell nobody.
  void _reconcile(MediaDeviceKind kind) {
    final List<MediaDevice> devices = devicesFor(kind);
    if (devices.isEmpty) {
      // Nothing to resolve against. The choice becomes a remembered one rather
      // than being dropped, so replugging the device brings it back.
      _demote(kind);
      return;
    }

    final InputDeviceChoice? remembered = _remembered[kind];
    if (remembered != null) {
      final MediaDevice? match = _findById(devices, remembered.id);
      if (match != null) {
        _remembered.remove(kind);
        _unresolved.remove(kind);
        _selected[kind] = match;
      } else {
        _unresolved[kind] = remembered.label;
        _selected.remove(kind);
      }
      return;
    }

    final MediaDevice? current = _selected[kind];
    if (current == null) {
      return;
    }
    final MediaDevice? match = _findById(devices, current.id);
    if (match == null) {
      // Unplugged. Remembered rather than forgotten: plugging it back in should
      // return the user to the microphone they chose, not leave them on the
      // default with no way to notice.
      _demote(kind);
      return;
    }
    // Re-point at the fresh instance so a changed availability flag is picked
    // up, the way the source catalogue re-points at a fresh thumbnail.
    _selected[kind] = match;
  }

  /// Turns a live selection back into a remembered one.
  ///
  /// The device is gone; the *choice* is not. Keeping it as a remembered
  /// choice is what makes the next enumeration able to honour it, and what
  /// gives [unresolved] a name to show in the meantime.
  void _demote(MediaDeviceKind kind) {
    final MediaDevice? current = _selected.remove(kind);
    if (current == null) {
      return;
    }
    _remembered[kind] = InputDeviceChoice.of(current);
    _unresolved[kind] = current.label;
  }

  static MediaDevice? _findById(List<MediaDevice> devices, String id) {
    for (final MediaDevice device in devices) {
      if (device.id == id) {
        return device;
      }
    }
    return null;
  }
}
