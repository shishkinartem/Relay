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
