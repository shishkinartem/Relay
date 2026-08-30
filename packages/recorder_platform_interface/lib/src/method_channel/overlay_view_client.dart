import 'dart:async';

import 'package:flutter/services.dart';

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

  Stream<RecordingOverlayState> get controlStripStates => _stripStates.stream;

  Stream<CameraPreviewOverlayState> get cameraPreviewStates =>
      _previewStates.stream;

  Future<void> send(OverlayCommand command) => _channel.invokeMethod<void>(
    'command',
    <String, Object?>{'command': command.name},
  );

  /// Asks the host to run its own window drag, from the pointer that is
  /// currently down (§33.3).
  ///
  /// One call, not a stream of deltas: the operating system already has a drag
  /// loop that tracks the pointer at the display's refresh rate and stops on
  /// mouse-up, and handing the gesture to it is both smoother and quieter than
  /// sending a message per pointer move over a channel meant for commands (§3).
  /// The host clamps the result to the display's usable area.
  Future<void> beginMove() => _channel.invokeMethod<void>('beginMove');

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
    }
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    await _stripStates.close();
    await _previewStates.close();
  }
}
