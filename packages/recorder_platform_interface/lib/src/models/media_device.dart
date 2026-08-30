import 'package:flutter/foundation.dart';

/// Which input a device provides (§33.2).
///
/// A value object rather than three booleans, so a fourth input kind is a
/// member rather than a rewrite (§28). Not every kind is selectable on every
/// platform: `RecorderCapabilities.selectableDeviceKinds` is what the UI reads,
/// never the operating-system name.
enum MediaDeviceKind {
  camera,
  microphone,

  /// The endpoint whose output is captured. Selectable only where the platform
  /// captures a specific render endpoint — Windows loops back one, macOS
  /// delivers the system mix and has nothing to choose.
  systemAudio;

  /// Null for a name this build does not know.
  ///
  /// Deliberately not a fallback: a decoding mismatch that resolved to any
  /// member would file a camera under `microphone` and show it in the wrong
  /// list.
  static MediaDeviceKind? fromName(String? name) {
    for (final MediaDeviceKind kind in values) {
      if (kind.name == name) {
        return kind;
      }
    }
    return null;
  }
}

/// One selectable input, as the platform enumerates it (§33.2).
@immutable
class MediaDevice {
  const MediaDevice({
    required this.id,
    required this.kind,
    required this.label,
    this.isSystemDefault = false,
    this.isAvailable = true,
  });

  /// Opaque, platform-owned identifier. Never parsed by application code.
  ///
  /// Persisted alongside [label], because an id can stop resolving between
  /// launches — a device that was unplugged — and a name is what the user is
  /// told went missing.
  final String id;

  final MediaDeviceKind kind;

  /// What the user reads. Never empty: a platform that reports no name for a
  /// device is decoded as the kind's own word rather than as a blank row.
  final String label;

  /// The device the platform would use if nothing were chosen. The `null`
  /// device id on `RecordingConfiguration` means exactly this one.
  final bool isSystemDefault;

  /// False for a device the platform lists but cannot open right now — in use
  /// elsewhere, or connected but not ready. Shown, and not selectable, so its
  /// absence is legible (§33.7).
  final bool isAvailable;

  static MediaDevice? tryFromMap(Map<String, Object?> map) {
    final MediaDeviceKind? kind = MediaDeviceKind.fromName(
      map['kind'] as String?,
    );
    final String? id = map['id'] as String?;
    if (kind == null || id == null || id.isEmpty) {
      // A device with no kind or no id cannot be selected or persisted, so it
      // is not a device. Dropping it keeps one unrecognized entry from
      // poisoning a whole list.
      return null;
    }
    final String label = (map['label'] as String? ?? '').trim();
    return MediaDevice(
      id: id,
      kind: kind,
      label: label.isEmpty ? _fallbackLabel(kind) : label,
      isSystemDefault: map['isSystemDefault'] as bool? ?? false,
      isAvailable: map['isAvailable'] as bool? ?? true,
    );
  }

  static String _fallbackLabel(MediaDeviceKind kind) => switch (kind) {
    MediaDeviceKind.camera => 'Camera',
    MediaDeviceKind.microphone => 'Microphone',
    MediaDeviceKind.systemAudio => 'System audio',
  };

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'kind': kind.name,
    'label': label,
    'isSystemDefault': isSystemDefault,
    'isAvailable': isAvailable,
  };

  /// Identity is `(id, kind)`, as `CaptureSource`'s is `(id, type)`: the same
  /// device re-enumerated with a fresh availability flag is the same device.
  @override
  bool operator ==(Object other) =>
      other is MediaDevice && other.id == id && other.kind == kind;

  @override
  int get hashCode => Object.hash(id, kind);

  @override
  String toString() => 'MediaDevice($kind, $id, $label)';
}

/// A metering sample for one input (§33.2).
///
/// Linear amplitude in `[0, 1]`, not decibels: the bar is drawn from it and the
/// conversion belongs wherever a scale is chosen, not on the wire.
///
/// This is a *measurement*, never audio. §3 keeps raw buffers native, and a
/// peak-and-RMS pair at ~20 Hz is what a level meter needs.
@immutable
class InputLevel {
  const InputLevel({required this.peak, required this.rms});

  static const InputLevel silent = InputLevel(peak: 0, rms: 0);

  final double peak;
  final double rms;

  /// True when nothing measurable arrived. The UI turns a run of these into
  /// "nothing has reached this microphone" rather than leaving a blank bar
  /// (§33.7).
  bool get isSilent => peak <= 0.0001;

  static InputLevel fromMap(Map<String, Object?> map) =>
      InputLevel(peak: _unit(map['peak']), rms: _unit(map['rms']));

  /// Clamped on the way in. A platform that reports a level above full scale is
  /// reporting clipping, and the bar has nowhere to draw it past the end.
  static double _unit(Object? value) =>
      (value as num? ?? 0).toDouble().clamp(0.0, 1.0);

  Map<String, Object?> toMap() => <String, Object?>{'peak': peak, 'rms': rms};

  @override
  bool operator ==(Object other) =>
      other is InputLevel && other.peak == peak && other.rms == rms;

  @override
  int get hashCode => Object.hash(peak, rms);

  @override
  String toString() =>
      'InputLevel(peak: ${peak.toStringAsFixed(3)}, rms: ${rms.toStringAsFixed(3)})';
}
