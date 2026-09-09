/// The macOS implementation of the recorder platform interface.
///
/// This package ships the ScreenCaptureKit / AVFoundation / VideoToolbox half
/// of the contract in `docs/architecture/platform-channel-contract.md`; the
/// Dart half lives once in `recorder_platform_interface`.
library;

import 'package:recorder_platform_interface/recorder_platform_interface.dart';

/// macOS composition root.
class RecorderMacos extends MethodChannelRecorderPlatform {
  RecorderMacos();

  /// `macos/Runner/MainFlutterWindow.swift` makes the window's title bar
  /// full-size, transparent and untitled, so the traffic lights are drawn on
  /// top of the Flutter view rather than above it.
  @override
  WindowChrome get windowChrome => WindowChrome.overlaidWindowButtons;

  /// Called by the generated plugin registrant on macOS only. Idempotent.
  static void registerWith() {
    if (RecorderPlatform.instance is! RecorderMacos) {
      RecorderPlatform.instance = RecorderMacos();
    }
  }
}
