import 'package:flutter/foundation.dart';

import 'capture_source.dart';
import 'media_device.dart';
import 'recording_quality.dart';

/// What the running platform implementation can actually do.
///
/// The UI derives availability from this, never from the operating-system name
/// (§20, `docs/ARCHITECTURE.md`). 120 FPS arrives as another member of
/// [supportedFrameRates], not as a `highFrameRate` boolean (§10, §28).
@immutable
class RecorderCapabilities {
  const RecorderCapabilities({
    required this.qualities,
    required this.supportedFrameRates,
    required this.supportedSourceTypes,
    this.selectableDeviceKinds = const <MediaDeviceKind>{},
    this.meterableDeviceKinds = const <MediaDeviceKind>{},
    required this.supportsCamera,
    required this.supportsMicrophone,
    required this.supportsSystemAudio,
    required this.supportsPause,
    required this.supportsCursorCapture,
    required this.supportsHardwareEncoding,
    this.platformName = 'unknown',
    this.platformVersion = '',
    this.screenRecordingNeedsRelaunch = false,
    this.screenRecordingLaunchedByThisApp = true,
    this.unsupportedReason,
  });

  /// Nothing is available — no platform implementation is registered.
  const RecorderCapabilities.unsupported(String reason)
    : qualities = const <RecordingQuality>{},
      supportedFrameRates = const <int>{},
      supportedSourceTypes = const <CaptureSourceType>{},
      selectableDeviceKinds = const <MediaDeviceKind>{},
      meterableDeviceKinds = const <MediaDeviceKind>{},
      supportsCamera = false,
      supportsMicrophone = false,
      supportsSystemAudio = false,
      supportsPause = false,
      supportsCursorCapture = false,
      supportsHardwareEncoding = false,
      platformName = 'unsupported',
      platformVersion = '',
      screenRecordingNeedsRelaunch = false,
      screenRecordingLaunchedByThisApp = true,
      unsupportedReason = reason;

  final Set<RecordingQuality> qualities;
  final Set<int> supportedFrameRates;
  final Set<CaptureSourceType> supportedSourceTypes;

  /// Which inputs offer a *choice* of device (§33.2).
  ///
  /// A kind absent from this set is still recorded; it simply has one device,
  /// so the UI names it instead of offering a list of one. macOS reports
  /// `{camera, microphone}` — ScreenCaptureKit delivers the system mix and
  /// there is no endpoint to pick. This is the capability the UI reads; it must
  /// never ask which operating system it is running on (§28).
  final Set<MediaDeviceKind> selectableDeviceKinds;

  /// Which inputs can report a live level (§33.2).
  ///
  /// System audio is deliberately absent on both platforms: a level the user
  /// can act on is worth showing, and they can change neither the endpoint on
  /// macOS nor what the machine is playing from inside this application.
  final Set<MediaDeviceKind> meterableDeviceKinds;

  final bool supportsCamera;
  final bool supportsMicrophone;
  final bool supportsSystemAudio;
  final bool supportsPause;
  final bool supportsCursorCapture;
  final bool supportsHardwareEncoding;
  final String platformName;
  final String platformVersion;

  /// The platform applies a screen-recording answer only to a fresh process,
  /// so the application has to be able to offer a relaunch (§23).
  final bool screenRecordingNeedsRelaunch;

  /// False when the process was not started by the platform's own launcher, so
  /// the operating system attributes screen recording to whatever started it
  /// rather than to this application.
  ///
  /// A capability rather than a process check in `lib/`: the UI must not ask
  /// which operating system it is running on.
  final bool screenRecordingLaunchedByThisApp;

  /// Non-null only when recording is not possible at all on this platform.
  final String? unsupportedReason;

  bool get isSupported => unsupportedReason == null;

  /// Frame rates in ascending order, for stable presentation.
  List<int> get sortedFrameRates => supportedFrameRates.toList()..sort();

  List<RecordingQuality> get sortedQualities => qualities.toList()
    ..sort(
      (RecordingQuality a, RecordingQuality b) =>
          a.targetHeight.compareTo(b.targetHeight),
    );

  /// Unknown members are dropped rather than defaulted: a kind this build does
  /// not know is not a kind it can offer.
  static Set<MediaDeviceKind> _deviceKinds(Object? raw) => <MediaDeviceKind>{
    for (final Object? entry in (raw as List<Object?>? ?? const <Object?>[]))
      ?MediaDeviceKind.fromName(entry as String?),
  };

  static RecorderCapabilities fromMap(Map<String, Object?> map) {
    return RecorderCapabilities(
      qualities: <RecordingQuality>{
        for (final Object? q
            in (map['qualities'] as List<Object?>? ?? const <Object?>[]))
          RecordingQuality.fromName(q! as String),
      },
      supportedFrameRates: <int>{
        for (final Object? f
            in (map['frameRates'] as List<Object?>? ?? const <Object?>[]))
          (f! as num).toInt(),
      },
      supportedSourceTypes: <CaptureSourceType>{
        for (final Object? t
            in (map['sourceTypes'] as List<Object?>? ?? const <Object?>[]))
          CaptureSourceType.values.firstWhere(
            (CaptureSourceType v) => v.name == t,
            orElse: () => CaptureSourceType.display,
          ),
      },
      selectableDeviceKinds: _deviceKinds(map['selectableDeviceKinds']),
      meterableDeviceKinds: _deviceKinds(map['meterableDeviceKinds']),
      supportsCamera: map['supportsCamera'] as bool? ?? false,
      supportsMicrophone: map['supportsMicrophone'] as bool? ?? false,
      supportsSystemAudio: map['supportsSystemAudio'] as bool? ?? false,
      supportsPause: map['supportsPause'] as bool? ?? false,
      supportsCursorCapture: map['supportsCursorCapture'] as bool? ?? false,
      supportsHardwareEncoding:
          map['supportsHardwareEncoding'] as bool? ?? false,
      platformName: map['platformName'] as String? ?? 'unknown',
      platformVersion: map['platformVersion'] as String? ?? '',
      screenRecordingNeedsRelaunch:
          map['screenRecordingNeedsRelaunch'] as bool? ?? false,
      screenRecordingLaunchedByThisApp:
          map['screenRecordingLaunchedByThisApp'] as bool? ?? true,
      unsupportedReason: map['unsupportedReason'] as String?,
    );
  }
}
