import 'dart:async';

import 'package:flutter/services.dart';

import '../models/camera_overlay_configuration.dart';
import '../models/media_device.dart';
import '../models/overlay.dart';
import 'channels.dart';

/// The overlay side of the bridge, used inside a secondary Flutter engine.
///
/// An overlay window renders a snapshot pushed by the application engine and
/// sends back [OverlayCommand]s. It owns no recording state, so it cannot drift
/// out of step with the session.
class OverlayViewClient {
  OverlayViewClient({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(RecorderChannels.overlayView) {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  final StreamController<RecordingOverlayState> _stripStates =
      StreamController<RecordingOverlayState>.broadcast();
  final StreamController<CameraPreviewOverlayState> _previewStates =
      StreamController<CameraPreviewOverlayState>.broadcast();
  final StreamController<InputMenuOverlayState> _menuStates =
      StreamController<InputMenuOverlayState>.broadcast();

  Stream<RecordingOverlayState> get controlStripStates => _stripStates.stream;

  Stream<CameraPreviewOverlayState> get cameraPreviewStates =>
      _previewStates.stream;

  Stream<InputMenuOverlayState> get inputMenuStates => _menuStates.stream;

  /// Raises a command, optionally naming where in this window it came from.
  ///
  /// [anchorX] is the pressed control's centre in the *overlay window's own*
  /// coordinates, and it exists for the chevrons: only Flutter knows where a
  /// control ended up, and the host has to put the menu under the one that was
  /// pressed. It travels on this call rather than on the event channel so that
  /// channel keeps emitting bare names (§33.4).
  Future<void> send(OverlayCommand command, {double? anchorX}) =>
      _channel.invokeMethod<void>('command', <String, Object?>{
        'command': command.name,
        'anchorX': anchorX,
      });

  /// Asks the host to run its own window drag, from the pointer that is
  /// currently down (§33.3).
  ///
  /// One call, not a stream of deltas: the operating system already has a drag
  /// loop that tracks the pointer at the display's refresh rate and stops on
  /// mouse-up, and handing the gesture to it is both smoother and quieter than
  /// sending a message per pointer move over a channel meant for commands (§3).
  /// The host clamps the result to the display's usable area.
  Future<void> beginMove() => _channel.invokeMethod<void>('beginMove');

  /// A row of the input menu was chosen. The host closes the menu and forwards
  /// the choice to the application (§33.4).
  Future<void> chooseInputDevice(
    MediaDeviceKind kind, {
    String? deviceId,
    bool off = false,
  }) => _channel.invokeMethod<void>('chooseInputDevice', <String, Object?>{
    'kind': kind.name,
    'deviceId': deviceId,
    'off': off,
  });

  /// A shape preset in the camera sheet (§33.5).
  ///
  /// The same call a device choice takes, because the host's job is identical:
  /// forward it and get out of the way. Unlike a device choice it does not
  /// close the sheet — the tile changes under it, and trying the other two
  /// should not cost a reopen each time.
  Future<void> chooseCameraPreset(
    MediaDeviceKind kind,
    CameraPipPreset preset,
  ) => _channel.invokeMethod<void>('chooseInputDevice', <String, Object?>{
    'kind': kind.name,
    'preset': preset.name,
  });

  /// A corner in the camera sheet's window-mode placement row (§33.5).
  Future<void> chooseCameraCorner(
    MediaDeviceKind kind,
    CameraOverlayCorner corner,
  ) => _channel.invokeMethod<void>('chooseInputDevice', <String, Object?>{
    'kind': kind.name,
    'corner': corner.name,
  });

  /// `Reset position` in the camera sheet: put the tile back in its corner.
  Future<void> resetCameraPipPosition(MediaDeviceKind kind) =>
      _channel.invokeMethod<void>('chooseInputDevice', <String, Object?>{
        'kind': kind.name,
        'resetPosition': true,
      });

  /// Esc while this window happens to hold focus. The host closes the menu and
  /// reports the dismissal itself, so nothing is sent from here twice.
  Future<void> dismissInputMenu() =>
      _channel.invokeMethod<void>('dismissInputMenu');

  /// Tells the host the overlay content measured this size, so the window can
  /// be resized to fit exactly.
  Future<void> reportContentSize(double width, double height) =>
      _channel.invokeMethod<void>('contentSize', <String, Object?>{
        'width': width,
        'height': height,
      });

  Future<void> _handle(MethodCall call) async {
    final Map<String, Object?> args =
        (call.arguments as Map<Object?, Object?>? ?? const <Object?, Object?>{})
            .cast<String, Object?>();
    switch (call.method) {
      case 'controlStripState':
        _stripStates.add(RecordingOverlayState.fromMap(args));
      case 'cameraPreviewState':
        _previewStates.add(CameraPreviewOverlayState.fromMap(args));
      case 'inputMenuState':
        _menuStates.add(InputMenuOverlayState.fromMap(args));
    }
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _stripStates.close();
    await _previewStates.close();
    await _menuStates.close();
  }
}
