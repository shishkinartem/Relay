/// The platform-agnostic recorder contract.
///
/// Application and feature code depends on this package only; it must never
/// reach for ScreenCaptureKit, Windows.Graphics.Capture, WASAPI or any other
/// platform type (`docs/architecture/platform-abstraction.md`).
library;

export 'src/method_channel/channels.dart';
export 'src/method_channel/method_channel_recorder.dart';
export 'src/method_channel/overlay_view_client.dart';
export 'src/models/camera_overlay_configuration.dart';
export 'src/models/capture_source.dart';
export 'src/models/overlay.dart';
export 'src/models/permissions.dart';
export 'src/models/recorder_capabilities.dart';
export 'src/models/recorder_error.dart';
export 'src/models/recorder_event.dart';
export 'src/models/recording_configuration.dart';
export 'src/models/recording_file.dart';
export 'src/models/recording_quality.dart';
export 'src/models/video_composition_configuration.dart';
export 'src/recorder.dart';
export 'src/unsupported_recorder_platform.dart';
