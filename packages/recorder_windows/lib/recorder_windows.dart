/// The Windows implementation of the recorder platform interface.
///
/// This package ships the native half of the contract
/// (`docs/architecture/platform-channel-contract.md`); the Dart half lives once
/// in `recorder_platform_interface` and is reused verbatim here.
library;

import 'package:recorder_platform_interface/recorder_platform_interface.dart';

/// Windows composition root.
///
/// Adds no Dart behaviour: macOS and Windows speak the same channel contract,
/// so [MethodChannelRecorderPlatform] already provides the recorder, the
/// permission gateway and the overlay controller.
class RecorderWindows extends MethodChannelRecorderPlatform {
  RecorderWindows();

  /// Installs this implementation as the registered recorder platform.
  ///
  /// Called by the generated plugin registrant on Windows only. Idempotent:
  /// repeated registration keeps the first instance, so the channel-backed
  /// event streams are not rebuilt underneath live listeners.
  static void registerWith() {
    if (RecorderPlatform.instance is! RecorderWindows) {
      RecorderPlatform.instance = RecorderWindows();
    }
  }
}
