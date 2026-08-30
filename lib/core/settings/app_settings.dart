import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

/// User settings persisted between launches (§10, §15).
///
/// Values here are session *defaults*: the launch screen may override quality,
/// fps and the input toggles for one session without writing them back.
@immutable
class AppSettings {
  const AppSettings({
    this.uploadDestinationId = defaultUploadDestinationId,
    this.localRecordingsDirectory,
    this.quality = RecordingQuality.hd720,
    this.frameRate = defaultFrameRate,
    this.microphoneEnabled = true,
    this.systemAudioEnabled = true,
    this.cameraEnabled = false,
    this.showCursor = true,
    this.preferredSourceType = CaptureSourceType.display,
    this.inputDevices = const <MediaDeviceKind, InputDeviceChoice>{},
    this.expandedInputs = const <MediaDeviceKind>{},
    this.stripPosition,
    this.cameraPipPreset = CameraPipPreset.camera,
    this.cameraPipPosition,
    this.cameraPipCorner = CameraOverlayCorner.bottomRight,
  });

  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
    uploadDestinationId:
        _string(json, keyUploadDestinationId) ?? defaultUploadDestinationId,
    localRecordingsDirectory: _string(json, keyLocalRecordingsDirectory),
    quality: _quality(json[keyQuality]),
    frameRate: _frameRate(json[keyFrameRate]),
    microphoneEnabled: _bool(json, keyMicrophoneEnabled, true),
    systemAudioEnabled: _bool(json, keySystemAudioEnabled, true),
    cameraEnabled: _bool(json, keyCameraEnabled, false),
    showCursor: _bool(json, keyShowCursor, true),
    preferredSourceType: _sourceType(json[keyPreferredSourceType]),
    inputDevices: _inputDevices(json[keyInputDevices]),
    expandedInputs: _expandedInputs(json[keyExpandedInputs]),
    stripPosition: _stripPosition(json[keyStripPosition]),
    cameraPipPreset: CameraPipPreset.fromName(
      json[keyCameraPipPreset] as String?,
    ),
    cameraPipPosition: _offset(json[keyCameraPipPosition]),
    cameraPipCorner: CameraOverlayCorner.fromName(
      json[keyCameraPipCorner] as String?,
    ),
  );

  /// Schema version of the document [toJson] writes.
  static const int currentSchemaVersion = 3;

  /// Telegram is the only destination this build ships (§15, §16, and
  /// `docs/adr/2026-08-23-telegram-only-destination.md`).
  static const String defaultUploadDestinationId = 'telegram';

  static const int defaultFrameRate = 30;

  static const String keySchemaVersion = 'schemaVersion';
  static const String keyUploadDestinationId = 'uploadDestinationId';
  static const String keyLocalRecordingsDirectory = 'localRecordingsDirectory';
  static const String keyQuality = 'quality';
  static const String keyFrameRate = 'frameRate';
  static const String keyMicrophoneEnabled = 'microphoneEnabled';
  static const String keySystemAudioEnabled = 'systemAudioEnabled';
  static const String keyCameraEnabled = 'cameraEnabled';
  static const String keyShowCursor = 'showCursor';
  static const String keyPreferredSourceType = 'preferredSourceType';
  static const String keyInputDevices = 'inputDevices';
  static const String keyExpandedInputs = 'expandedInputs';
  static const String keyStripPosition = 'stripPosition';
  static const String keyCameraPipPreset = 'cameraPipPreset';
  static const String keyCameraPipPosition = 'cameraPipPosition';
  static const String keyCameraPipCorner = 'cameraPipCorner';

  /// Identifier of the single active upload destination (§15).
  final String uploadDestinationId;

  /// Null means "the platform default directory", resolved at use time.
  final String? localRecordingsDirectory;

  final RecordingQuality quality;
  final int frameRate;
  final bool microphoneEnabled;
  final bool systemAudioEnabled;
  final bool cameraEnabled;
  final bool showCursor;
  final CaptureSourceType preferredSourceType;

  /// The device each input should reopen next time, by kind (§33.2).
  ///
  /// A kind absent from the map means "the platform's own default", which is
  /// what an unconfigured install records. The label rides along with the id
  /// because an id can stop resolving between launches — a microphone that was
  /// unplugged — and the name is what the user has to be told went missing.
  final Map<MediaDeviceKind, InputDeviceChoice> inputDevices;

  /// Which inputs have their detail section open on the launch screen (§33.2).
  ///
  /// Closed is the default, and closed is the screen that shipped. Remembered
  /// because a user who opened the microphone's details once is usually the
  /// user who cares about them every time.
  final Set<MediaDeviceKind> expandedInputs;

  /// Where the control strip was left, as a fraction of its display's usable
  /// area (§33.3).
  ///
  /// Null is the default dock — top centre of the current display — and is what
  /// an install that never moved the strip stores. A position whose display is
  /// gone resolves back to that dock rather than to a rectangle nobody can
  /// point at.
  final OverlayStripPosition? stripPosition;

  /// Which shape and size the camera tile takes (§33.5). `camera` is the
  /// default and the only one that never crops.
  final CameraPipPreset cameraPipPreset;

  /// The tile's top-left as a fraction of the canvas, or null for the corner.
  ///
  /// Null is a live reference to the corner rather than an absence: a canvas
  /// that changes shape keeps the tile in the corner instead of at whatever
  /// fraction that corner used to be.
  final Offset? cameraPipPosition;

  /// Which corner the tile sits in when [cameraPipPosition] is null (§33.5).
  ///
  /// Chosen in the camera sheet, and only reachable in window mode: with a
  /// display source the tile is dragged instead, because there the preview *is*
  /// the tile and a corner is a poorer answer than putting it where you want it.
  final CameraOverlayCorner cameraPipCorner;

  AppSettings copyWith({
    String? uploadDestinationId,
    Object? localRecordingsDirectory = _unset,
    RecordingQuality? quality,
    int? frameRate,
    bool? microphoneEnabled,
    bool? systemAudioEnabled,
    bool? cameraEnabled,
    bool? showCursor,
    CaptureSourceType? preferredSourceType,
    Map<MediaDeviceKind, InputDeviceChoice>? inputDevices,
    Set<MediaDeviceKind>? expandedInputs,
    Object? stripPosition = _unset,
    CameraPipPreset? cameraPipPreset,
    Object? cameraPipPosition = _unset,
    CameraOverlayCorner? cameraPipCorner,
  }) => AppSettings(
    uploadDestinationId: uploadDestinationId ?? this.uploadDestinationId,
    localRecordingsDirectory: identical(localRecordingsDirectory, _unset)
        ? this.localRecordingsDirectory
        : localRecordingsDirectory as String?,
    quality: quality ?? this.quality,
    frameRate: frameRate ?? this.frameRate,
    microphoneEnabled: microphoneEnabled ?? this.microphoneEnabled,
    systemAudioEnabled: systemAudioEnabled ?? this.systemAudioEnabled,
    cameraEnabled: cameraEnabled ?? this.cameraEnabled,
    showCursor: showCursor ?? this.showCursor,
    preferredSourceType: preferredSourceType ?? this.preferredSourceType,
    inputDevices: inputDevices ?? this.inputDevices,
    expandedInputs: expandedInputs ?? this.expandedInputs,
    stripPosition: identical(stripPosition, _unset)
        ? this.stripPosition
        : stripPosition as OverlayStripPosition?,
    cameraPipPreset: cameraPipPreset ?? this.cameraPipPreset,
    cameraPipPosition: identical(cameraPipPosition, _unset)
        ? this.cameraPipPosition
        : cameraPipPosition as Offset?,
    cameraPipCorner: cameraPipCorner ?? this.cameraPipCorner,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    keySchemaVersion: currentSchemaVersion,
    keyUploadDestinationId: uploadDestinationId,
    keyLocalRecordingsDirectory: localRecordingsDirectory,
    keyQuality: quality.name,
    keyFrameRate: frameRate,
    keyMicrophoneEnabled: microphoneEnabled,
    keySystemAudioEnabled: systemAudioEnabled,
    keyCameraEnabled: cameraEnabled,
    keyShowCursor: showCursor,
    keyPreferredSourceType: preferredSourceType.name,
    keyInputDevices: <String, Object?>{
      for (final MapEntry<MediaDeviceKind, InputDeviceChoice> entry
          in inputDevices.entries)
        entry.key.name: entry.value.toJson(),
    },
    keyStripPosition: stripPosition?.toMap(),
    keyCameraPipPreset: cameraPipPreset.name,
    keyCameraPipCorner: cameraPipCorner.name,
    keyCameraPipPosition: cameraPipPosition == null
        ? null
        : <String, Object?>{
            'x': cameraPipPosition!.dx,
            'y': cameraPipPosition!.dy,
          },
    keyExpandedInputs: <String>[
      // Written in enum order rather than set order, so two settings documents
      // that mean the same thing are the same bytes.
      for (final MediaDeviceKind kind in MediaDeviceKind.values)
        if (expandedInputs.contains(kind)) kind.name,
    ],
  };

  /// A kind this build does not know is dropped, not defaulted: a stored choice
  /// that cannot be attributed to an input is not a choice.
  static Map<MediaDeviceKind, InputDeviceChoice> _inputDevices(Object? value) {
    if (value is! Map<Object?, Object?>) {
      return const <MediaDeviceKind, InputDeviceChoice>{};
    }
    final Map<MediaDeviceKind, InputDeviceChoice> devices =
        <MediaDeviceKind, InputDeviceChoice>{};
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      final MediaDeviceKind? kind = MediaDeviceKind.fromName(
        entry.key as String?,
      );
      final Object? raw = entry.value;
      if (kind == null || raw is! Map<Object?, Object?>) {
        continue;
      }
      final InputDeviceChoice? choice = InputDeviceChoice.tryFromJson(
        raw.cast<String, Object?>(),
      );
      if (choice != null) {
        devices[kind] = choice;
      }
    }
    return devices;
  }

  /// Half a position is no position, the same rule the configuration decodes
  /// by: a tile placed on one axis and cornered on the other is a shape nobody
  /// asked for.
  static Offset? _offset(Object? value) {
    if (value is! Map<Object?, Object?>) {
      return null;
    }
    final Object? x = value['x'];
    final Object? y = value['y'];
    if (x is! num || y is! num || !x.isFinite || !y.isFinite) {
      return null;
    }
    return Offset(x.toDouble(), y.toDouble());
  }

  static OverlayStripPosition? _stripPosition(Object? value) =>
      value is Map<Object?, Object?>
      ? OverlayStripPosition.tryFromMap(value.cast<String, Object?>())
      : null;

  static Set<MediaDeviceKind> _expandedInputs(
    Object? value,
  ) => <MediaDeviceKind>{
    for (final Object? entry in (value as List<Object?>? ?? const <Object?>[]))
      ?MediaDeviceKind.fromName(entry as String?),
  };

  static const Object _unset = Object();

  static String? _string(Map<String, Object?> json, String key) {
    final Object? value = json[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  static bool _bool(Map<String, Object?> json, String key, bool fallback) {
    final Object? value = json[key];
    return value is bool ? value : fallback;
  }

  static RecordingQuality _quality(Object? value) => value is String
      ? RecordingQuality.fromName(value)
      : RecordingQuality.hd720;

  static int _frameRate(Object? value) =>
      value is int && value > 0 ? value : defaultFrameRate;

  static CaptureSourceType _sourceType(Object? value) => value is String
      ? CaptureSourceType.values.firstWhere(
          (CaptureSourceType type) => type.name == value,
          orElse: () => CaptureSourceType.display,
        )
      : CaptureSourceType.display;

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.uploadDestinationId == uploadDestinationId &&
      other.localRecordingsDirectory == localRecordingsDirectory &&
      other.quality == quality &&
      other.frameRate == frameRate &&
      other.microphoneEnabled == microphoneEnabled &&
      other.systemAudioEnabled == systemAudioEnabled &&
      other.cameraEnabled == cameraEnabled &&
      other.showCursor == showCursor &&
      other.preferredSourceType == preferredSourceType &&
      mapEquals(other.inputDevices, inputDevices) &&
      setEquals(other.expandedInputs, expandedInputs) &&
      other.stripPosition == stripPosition &&
      other.cameraPipPreset == cameraPipPreset &&
      other.cameraPipPosition == cameraPipPosition &&
      other.cameraPipCorner == cameraPipCorner;

  @override
  int get hashCode => Object.hash(
    uploadDestinationId,
    localRecordingsDirectory,
    quality,
    frameRate,
    microphoneEnabled,
    systemAudioEnabled,
    cameraEnabled,
    showCursor,
    preferredSourceType,
    // Hashed in enum order, so two equal settings hash equal whatever order
    // their map and set happen to iterate in.
    Object.hashAll(<Object?>[
      for (final MediaDeviceKind kind in MediaDeviceKind.values)
        inputDevices[kind],
      for (final MediaDeviceKind kind in MediaDeviceKind.values)
        expandedInputs.contains(kind),
      stripPosition,
      cameraPipPreset,
      cameraPipPosition,
      cameraPipCorner,
    ]),
  );

  @override
  String toString() =>
      'AppSettings(${quality.label}@$frameRate, $uploadDestinationId, '
      'mic: $microphoneEnabled, systemAudio: $systemAudioEnabled, '
      'camera: $cameraEnabled, cursor: $showCursor, '
      'source: ${preferredSourceType.name})';
}

/// A remembered device choice (§33.2).
///
/// Both halves are needed: the [id] is how the device is reopened, and the
/// [label] is how it is named on the screen that has to say it is gone.
@immutable
class InputDeviceChoice {
  const InputDeviceChoice({required this.id, required this.label});

  static const String _keyId = 'id';
  static const String _keyLabel = 'label';

  final String id;
  final String label;

  /// Null for a stored entry that cannot identify a device. An id is the only
  /// part that must be there; a missing label degrades to the id.
  static InputDeviceChoice? tryFromJson(Map<String, Object?> json) {
    final Object? id = json[_keyId];
    if (id is! String || id.isEmpty) {
      return null;
    }
    final Object? label = json[_keyLabel];
    return InputDeviceChoice(
      id: id,
      label: label is String && label.isNotEmpty ? label : id,
    );
  }

  static InputDeviceChoice of(MediaDevice device) =>
      InputDeviceChoice(id: device.id, label: device.label);

  Map<String, Object?> toJson() => <String, Object?>{
    _keyId: id,
    _keyLabel: label,
  };

  @override
  bool operator ==(Object other) =>
      other is InputDeviceChoice && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);

  @override
  String toString() => 'InputDeviceChoice($id, $label)';
}
