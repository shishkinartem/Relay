import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../core/logging/app_logger.dart';

/// The live level of an input, and whether it is hearing anything (§33.2).
///
/// Exists so the launch screen can answer "is this microphone hearing me?"
/// before a recording rather than after it. It holds a measurement, never
/// audio: §3 keeps raw buffers native, and what crosses the boundary is a
/// peak-and-RMS pair.
abstract interface class InputMeter {
  /// The most recent sample for [kind], or silence when nothing is running.
  InputLevel levelFor(MediaDeviceKind kind);

  bool isRunningFor(MediaDeviceKind kind);

  /// Whether the platform said it can meter [kind].
  ///
  /// The UI reads the same capability to decide whether to draw a bar at all;
  /// this is what keeps a caller that asks anyway from opening a tap that can
  /// only ever report silence.
  bool canMeter(MediaDeviceKind kind);

  /// Which kinds the platform can meter, set once capabilities are read.
  set meterableKinds(Set<MediaDeviceKind> kinds);

  /// True when the meter has been running long enough to have heard something
  /// and has heard nothing.
  ///
  /// A finding, not a blank control: a flat bar on an enabled input is
  /// something the user needs told about, and it is indistinguishable from "the
  /// meter has not started yet" unless someone counts (§33.7).
  bool isSilentFor(MediaDeviceKind kind);

  /// The device this kind is currently metering, or null for the default.
  String? meteredDeviceFor(MediaDeviceKind kind);

  /// Opens the tap on [deviceId], or on the platform default when it is null.
  ///
  /// Idempotent per kind, and a no-op for a kind the platform cannot meter.
  /// Calling it again with a *different* device re-points the tap, which is
  /// what makes the bar follow the row the user just chose.
  Future<void> start(MediaDeviceKind kind, {String? deviceId});

  Future<void> stop(MediaDeviceKind kind);

  /// Closes every tap. Called when the screen holding the meters goes away, so
  /// no device stays open for a bar nobody is looking at.
  Future<void> stopAll();

  /// Feeds a sample in. Called by whoever owns the platform event stream.
  void accept(MediaDeviceKind kind, InputLevel level);

  /// Forgets what [kind] has heard so far.
  ///
  /// Called when the device changes: the silence counted against the old
  /// microphone says nothing about the new one, and carrying it over would
  /// accuse a working device of being deaf.
  void reset(MediaDeviceKind kind);
}

/// [InputMeter] against the platform contract.
///
/// Silence is counted in samples rather than measured against a clock. The
/// platform emits at a known rate while a tap is open, so a count is the same
/// thing without a clock to inject, and a test can prove the threshold by
/// feeding it samples instead of by waiting three seconds.
class PlatformInputMeter implements InputMeter {
  PlatformInputMeter({
    required this._provider,
    required this._logger,
    Set<MediaDeviceKind> meterableKinds = const <MediaDeviceKind>{},
    this.silenceThreshold = defaultSilenceThreshold,
  }) : _meterable = meterableKinds;

  /// Roughly three seconds at the ~20 Hz the contract asks for.
  static const int defaultSilenceThreshold = 60;

  final MediaDeviceProvider _provider;
  final Logger _logger;
  Set<MediaDeviceKind> _meterable;

  /// Consecutive silent samples before an input is called silent.
  final int silenceThreshold;

  final Map<MediaDeviceKind, InputLevel> _levels =
      <MediaDeviceKind, InputLevel>{};
  final Map<MediaDeviceKind, int> _silentSamples = <MediaDeviceKind, int>{};
  final Set<MediaDeviceKind> _running = <MediaDeviceKind>{};

  /// Which device each open tap is on. Absent from the map means the platform
  /// default, which is a value in its own right and not "unknown".
  final Map<MediaDeviceKind, String?> _metered = <MediaDeviceKind, String?>{};

  /// Which kinds the platform said it can meter.
  ///
  /// Set after capabilities are read, so a meter is never started for a kind
  /// the platform would answer with silence. The UI reads the same capability
  /// to decide whether to draw a bar at all — this is the second line of
  /// defence, not the first.
  @override
  set meterableKinds(Set<MediaDeviceKind> kinds) => _meterable = kinds;

  @override
  bool canMeter(MediaDeviceKind kind) => _meterable.contains(kind);

  @override
  InputLevel levelFor(MediaDeviceKind kind) =>
      _levels[kind] ?? InputLevel.silent;

  @override
  bool isRunningFor(MediaDeviceKind kind) => _running.contains(kind);

  @override
  String? meteredDeviceFor(MediaDeviceKind kind) => _metered[kind];

  @override
  bool isSilentFor(MediaDeviceKind kind) =>
      _running.contains(kind) &&
      (_silentSamples[kind] ?? 0) >= silenceThreshold;

  @override
  Future<void> start(MediaDeviceKind kind, {String? deviceId}) async {
    if (!canMeter(kind)) {
      return;
    }
    if (_running.contains(kind)) {
      if (_metered[kind] == deviceId) {
        return;
      }
      // Re-pointing is a stop and a start, never a second start. Both
      // platforms count references on `startInputMetering`, so a start that no
      // stop ever matches leaves the count above zero — and the microphone open
      // for a meter nobody is watching, with the operating system's in-use
      // indicator lit, for the life of the process (§33.7).
      await stop(kind);
    }
    // Marked running before the await, so an immediate second call is a no-op
    // rather than a second tap on the same device.
    _running.add(kind);
    _metered[kind] = deviceId;
    // Whatever the previous device was heard to be says nothing about this one.
    reset(kind);
    try {
      await _provider.startInputMetering(kind, deviceId: deviceId);
    } on RecorderException catch (e) {
      _running.remove(kind);
      _metered.remove(kind);
      _logger.warn(
        'input_metering_failed',
        fields: <String, Object?>{'kind': kind.name, 'code': e.code.name},
      );
    }
  }

  @override
  Future<void> stop(MediaDeviceKind kind) async {
    if (!_running.remove(kind)) {
      return;
    }
    _metered.remove(kind);
    reset(kind);
    try {
      await _provider.stopInputMetering(kind);
    } on RecorderException catch (e) {
      // A tap that will not close is a leak on the platform side, and there is
      // nothing this layer can do about it beyond saying so. It is not worth a
      // screen: the recording is unaffected.
      _logger.warn(
        'input_metering_stop_failed',
        fields: <String, Object?>{'kind': kind.name, 'code': e.code.name},
      );
    }
  }

  @override
  Future<void> stopAll() async {
    for (final MediaDeviceKind kind in _running.toList(growable: false)) {
      await stop(kind);
    }
  }

  @override
  void accept(MediaDeviceKind kind, InputLevel level) {
    if (!_running.contains(kind)) {
      // A sample that arrives after the tap was closed is the tail of a stopped
      // stream, not a level to draw.
      return;
    }
    _levels[kind] = level;
    _silentSamples[kind] = level.isSilent ? (_silentSamples[kind] ?? 0) + 1 : 0;
  }

  @override
  void reset(MediaDeviceKind kind) {
    _levels[kind] = InputLevel.silent;
    _silentSamples[kind] = 0;
  }
}
