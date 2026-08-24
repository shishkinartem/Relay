import 'dart:async';

import 'package:flutter/services.dart';

import '../models/camera_overlay_configuration.dart';
import '../models/capture_source.dart';
import '../models/overlay.dart';
import '../models/permissions.dart';
import '../models/recorder_capabilities.dart';
import '../models/recorder_error.dart';
import '../models/recorder_event.dart';
import '../models/recording_configuration.dart';
import '../models/recording_file.dart';
import '../recorder.dart';
import 'channels.dart';

/// Turns a [PlatformException] into the typed capture error it stands for.
///
/// Native code sets `PlatformException.code` to a [RecorderErrorCode] name, so
/// no string matching on messages happens anywhere in the application.
Never _rethrowAsRecorderException(PlatformException e) {
  throw RecorderException(
    RecorderErrorCode.fromName(e.code),
    e.message ?? 'Native recorder failure (${e.code})',
    details: e.details?.toString(),
  );
}

Future<T> _guard<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on PlatformException catch (e) {
    _rethrowAsRecorderException(e);
  } on MissingPluginException catch (e) {
    throw RecorderException(
      RecorderErrorCode.unsupported,
      'No recorder implementation is registered for this platform.',
      details: e.message,
    );
  }
}

/// The channel-backed [Recorder] shared by every native implementation.
///
/// macOS and Windows speak the same contract, so the Dart side exists once.
class MethodChannelRecorder implements Recorder {
  MethodChannelRecorder({MethodChannel? channel, EventChannel? eventChannel})
    : _channel = channel ?? const MethodChannel(RecorderChannels.recorder),
      _eventChannel =
          eventChannel ?? const EventChannel(RecorderChannels.recorderEvents);

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  Stream<RecorderEvent>? _events;

  @override
  Future<List<CaptureSource>> getAvailableSources({
    bool refreshThumbnails = true,
  }) => _guard(() async {
    final List<Object?>? raw = await _channel.invokeMethod<List<Object?>>(
      'getAvailableSources',
      <String, Object?>{'refreshThumbnails': refreshThumbnails},
    );
    return <CaptureSource>[
      for (final Object? entry in raw ?? const <Object?>[])
        _sourceFromMap(
          (entry! as Map<Object?, Object?>).cast<String, Object?>(),
        ),
    ];
  });

  @override
  Future<RecorderCapabilities> getCapabilities() => _guard(() async {
    final Map<Object?, Object?>? raw = await _channel
        .invokeMethod<Map<Object?, Object?>>('getCapabilities');
    if (raw == null) {
      return const RecorderCapabilities.unsupported(
        'The platform returned no capabilities.',
      );
    }
    return RecorderCapabilities.fromMap(raw.cast<String, Object?>());
  });

  @override
  Future<DisplayGeometry> getCurrentDisplay() => _guard(() async {
    final Map<Object?, Object?>? raw = await _channel
        .invokeMethod<Map<Object?, Object?>>('getCurrentDisplay');
    final DisplayGeometry? geometry = raw == null
        ? null
        : DisplayGeometry.tryFromMap(raw.cast<String, Object?>());
    if (geometry == null) {
      // A 0 × 0 display is not a display. Returning one made overlay placement
      // resolve against an empty rectangle and put the control strip nowhere,
      // silently — a typed failure is the only way a caller finds out.
      throw const RecorderException(
        RecorderErrorCode.captureFailed,
        'The platform did not report a usable display.',
      );
    }
    return geometry;
  });

  @override
  Future<void> prepare(RecordingConfiguration configuration) => _guard(
    () => _channel.invokeMethod<void>('prepare', configuration.toMap()),
  );

  @override
  Future<void> start() => _guard(() => _channel.invokeMethod<void>('start'));

  @override
  Future<void> pause() => _guard(() => _channel.invokeMethod<void>('pause'));

  @override
  Future<void> resume() => _guard(() => _channel.invokeMethod<void>('resume'));

  @override
  Future<RecordingFile> stop() => _guard(() async {
    final Map<Object?, Object?>? raw = await _channel
        .invokeMethod<Map<Object?, Object?>>('stop');
    if (raw == null) {
      throw const RecorderException(
        RecorderErrorCode.finalizationFailed,
        'The platform finalized the recording but returned no file.',
      );
    }
    return RecordingFile.fromMap(raw.cast<String, Object?>());
  });

  @override
  Future<void> abort() => _guard(() => _channel.invokeMethod<void>('abort'));

  @override
  Future<void> setMicrophoneEnabled(bool enabled) => _guard(
    () => _channel.invokeMethod<void>('setMicrophoneEnabled', <String, Object?>{
      'enabled': enabled,
    }),
  );

  @override
  Future<void> setCameraEnabled(bool enabled) => _guard(
    () => _channel.invokeMethod<void>('setCameraEnabled', <String, Object?>{
      'enabled': enabled,
    }),
  );

  @override
  Future<void> setSystemAudioEnabled(bool enabled) => _guard(
    () => _channel.invokeMethod<void>(
      'setSystemAudioEnabled',
      <String, Object?>{'enabled': enabled},
    ),
  );

  @override
  Future<RecordingFile?> recoverArtifact(String artifactPath) =>
      _guard(() async {
        final Map<Object?, Object?>? raw = await _channel
            .invokeMethod<Map<Object?, Object?>>(
              'recoverArtifact',
              <String, Object?>{'path': artifactPath},
            );
        if (raw == null) {
          return null;
        }
        return RecordingFile.fromMap(raw.cast<String, Object?>());
      });

  @override
  Stream<RecorderEvent> get events => _events ??= _eventChannel
      .receiveBroadcastStream()
      .map(
        (Object? event) => RecorderEvent.fromMap(
          (event! as Map<Object?, Object?>).cast<String, Object?>(),
        ),
      )
      .asBroadcastStream();

  @override
  Future<void> releaseSession() =>
      _guard(() => _channel.invokeMethod<void>('releaseSession'));

  @override
  Future<void> dispose() =>
      _guard(() => _channel.invokeMethod<void>('dispose'));

  static CaptureSource _sourceFromMap(Map<String, Object?> map) =>
      CaptureSource(
        id: map['id']! as String,
        type: CaptureSourceType.values.firstWhere(
          (CaptureSourceType t) => t.name == map['type'],
          orElse: () => CaptureSourceType.window,
        ),
        title: map['title'] as String? ?? '',
        subtitle: map['subtitle'] as String? ?? '',
        pixelWidth: (map['pixelWidth'] as num? ?? 0).toInt(),
        pixelHeight: (map['pixelHeight'] as num? ?? 0).toInt(),
        isCurrentDisplay: map['isCurrentDisplay'] as bool? ?? false,
        thumbnail: map['thumbnail'] as Uint8List?,
      );
}

/// Channel-backed permissions gateway.
class MethodChannelRecorderPermissions implements RecorderPermissions {
  MethodChannelRecorderPermissions({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(RecorderChannels.recorder);

  final MethodChannel _channel;

  @override
  Future<PermissionReport> check() => _guard(() async {
    final Map<Object?, Object?>? raw = await _channel
        .invokeMethod<Map<Object?, Object?>>('checkPermissions');
    return PermissionReport.fromMap(
      (raw ?? const <Object?, Object?>{}).cast<String, Object?>(),
    );
  });

  @override
  Future<PermissionStatus> request(PermissionKind kind) => _guard(() async {
    final String? raw = await _channel.invokeMethod<String>(
      'requestPermission',
      <String, Object?>{'kind': kind.name},
    );
    return PermissionStatus.fromName(raw);
  });

  @override
  Future<void> openSystemSettings(PermissionKind kind) => _guard(
    () => _channel.invokeMethod<void>(
      'openPermissionSettings',
      <String, Object?>{'kind': kind.name},
    ),
  );

  @override
  Future<void> relaunchApplication() =>
      _guard(() => _channel.invokeMethod<void>('relaunchApplication'));

  @override
  Future<void> quitApplication() =>
      _guard(() => _channel.invokeMethod<void>('quitApplication'));
}

/// Channel-backed overlay window controller.
class MethodChannelOverlayWindowController implements OverlayWindowController {
  MethodChannelOverlayWindowController({
    MethodChannel? channel,
    EventChannel? eventChannel,
  }) : _channel = channel ?? const MethodChannel(RecorderChannels.overlay),
       _eventChannel =
           eventChannel ?? const EventChannel(RecorderChannels.overlayEvents);

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  Stream<OverlayCommand>? _commands;

  @override
  Future<void> showControlStrip(OverlayPlacement placement) => _guard(
    () => _channel.invokeMethod<void>('showControlStrip', placement.toMap()),
  );

  @override
  Future<void> hideControlStrip() =>
      _guard(() => _channel.invokeMethod<void>('hideControlStrip'));

  @override
  Future<void> showCameraPreview(
    OverlayPlacement placement, {
    required bool matchesCompositedPip,
    CameraOverlayConfiguration? cameraOverlay,
  }) => _guard(
    () => _channel.invokeMethod<void>('showCameraPreview', <String, Object?>{
      ...placement.toMap(),
      'matchesCompositedPip': matchesCompositedPip,
      if (cameraOverlay != null) 'cameraOverlay': cameraOverlay.toMap(),
    }),
  );

  @override
  Future<void> hideCameraPreview() =>
      _guard(() => _channel.invokeMethod<void>('hideCameraPreview'));

  @override
  Future<void> updateControlStrip(RecordingOverlayState state) => _guard(
    () => _channel.invokeMethod<void>('updateControlStrip', state.toMap()),
  );

  @override
  Future<void> setMainWindowVisible(bool visible) => _guard(
    () => _channel.invokeMethod<void>('setMainWindowVisible', <String, Object?>{
      'visible': visible,
    }),
  );

  @override
  Future<List<String>> excludedWindowIds() => _guard(() async {
    final List<Object?>? raw = await _channel.invokeMethod<List<Object?>>(
      'excludedWindowIds',
    );
    return <String>[
      for (final Object? id in raw ?? const <Object?>[]) id.toString(),
    ];
  });

  @override
  Stream<OverlayCommand> get commands => _commands ??= _eventChannel
      .receiveBroadcastStream()
      .map((Object? event) => OverlayCommand.fromName(event as String?))
      .where((OverlayCommand? command) => command != null)
      .cast<OverlayCommand>()
      .asBroadcastStream();
}

/// The default composition root: every native implementation registers this.
class MethodChannelRecorderPlatform extends RecorderPlatform {
  MethodChannelRecorderPlatform();

  @override
  late final Recorder recorder = MethodChannelRecorder();

  @override
  late final RecorderPermissions permissions =
      MethodChannelRecorderPermissions();

  @override
  late final OverlayWindowController overlays =
      MethodChannelOverlayWindowController();
}
