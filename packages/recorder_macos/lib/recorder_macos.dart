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

  /// Called by the generated plugin registrant on macOS only. Idempotent.
  static void registerWith() {
    if (RecorderPlatform.instance is! RecorderMacos) {
      RecorderPlatform.instance = RecorderMacos();
    }
  }
}
