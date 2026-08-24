import 'package:flutter/foundation.dart';

import 'recorder_error.dart';

/// Where the platform session currently is.
///
/// This is the *platform* view. The application state machine in
/// `lib/features/recorder` is a superset that also covers upload and deletion.
enum PlatformRecorderState {
  idle,
  preparing,
  prepared,
  recording,
  paused,
  stopping,
  finalizing,
  finalized,
  failed;

  static PlatformRecorderState fromName(String? name) => values.firstWhere(
    (PlatformRecorderState s) => s.name == name,
    orElse: () => PlatformRecorderState.idle,
  );
}

/// Anything the native pipeline reports back (§20).
@immutable
sealed class RecorderEvent {
  const RecorderEvent();

  static RecorderEvent fromMap(Map<String, Object?> map) {
    switch (map['type'] as String?) {
      case 'state':
        return RecorderStateEvent(
          PlatformRecorderState.fromName(map['state'] as String?),
        );
      case 'tick':
        return RecorderTickEvent(
          Duration(milliseconds: (map['elapsedMs'] as num? ?? 0).toInt()),
        );
      case 'stats':
        return RecorderStatsEvent(
          capturedFrames: (map['capturedFrames'] as num? ?? 0).toInt(),
          encodedFrames: (map['encodedFrames'] as num? ?? 0).toInt(),
          droppedFrames: (map['droppedFrames'] as num? ?? 0).toInt(),
          audioDiscontinuities: (map['audioDiscontinuities'] as num? ?? 0)
              .toInt(),
          avDriftMs: (map['avDriftMs'] as num? ?? 0).toDouble(),
          encoderName: map['encoderName'] as String? ?? '',
          hardwareEncoding: map['hardwareEncoding'] as bool? ?? false,
        );
      case 'inputChanged':
        return RecorderInputChangedEvent(
          microphoneEnabled: map['microphoneEnabled'] as bool? ?? false,
          cameraEnabled: map['cameraEnabled'] as bool? ?? false,
          systemAudioEnabled: map['systemAudioEnabled'] as bool? ?? false,
        );
      case 'error':
        return RecorderErrorEvent(
          RecorderErrorCode.fromName(map['code'] as String?),
          map['message'] as String? ?? 'Unknown recorder error',
          details: map['details'] as String?,
          fatal: map['fatal'] as bool? ?? true,
        );
      default:
        return RecorderErrorEvent(
          RecorderErrorCode.unknown,
          'Unrecognized recorder event: ${map['type']}',
        );
    }
  }
}

class RecorderStateEvent extends RecorderEvent {
  const RecorderStateEvent(this.state);
  final PlatformRecorderState state;
}

/// Elapsed *recorded* time — paused intervals excluded, so the strip's timer
/// equals the final file duration (design `1g`).
class RecorderTickEvent extends RecorderEvent {
  const RecorderTickEvent(this.elapsed);
  final Duration elapsed;
}

class RecorderStatsEvent extends RecorderEvent {
  const RecorderStatsEvent({
    required this.capturedFrames,
    required this.encodedFrames,
    required this.droppedFrames,
    required this.audioDiscontinuities,
    required this.avDriftMs,
    required this.encoderName,
    required this.hardwareEncoding,
  });

  final int capturedFrames;
  final int encodedFrames;
  final int droppedFrames;
  final int audioDiscontinuities;
  final double avDriftMs;
  final String encoderName;
  final bool hardwareEncoding;
}

/// The native side confirming which inputs are contributing right now.
class RecorderInputChangedEvent extends RecorderEvent {
  const RecorderInputChangedEvent({
    required this.microphoneEnabled,
    required this.cameraEnabled,
    required this.systemAudioEnabled,
  });

  final bool microphoneEnabled;
  final bool cameraEnabled;
  final bool systemAudioEnabled;
}

class RecorderErrorEvent extends RecorderEvent {
  const RecorderErrorEvent(
    this.code,
    this.message, {
    this.details,
    this.fatal = true,
  });

  final RecorderErrorCode code;
  final String message;
  final String? details;

  /// A non-fatal error degrades the session (an optional input dropped out);
  /// a fatal one ends it.
  final bool fatal;
}
