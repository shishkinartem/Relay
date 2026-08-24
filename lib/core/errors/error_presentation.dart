import 'package:flutter/foundation.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';
import 'package:upload_core/upload_core.dart';

import '../logging/app_logger.dart';

/// User-facing copy for a typed failure.
///
/// The layout is fixed (design 1k): a short [title], one plain-language [body]
/// that always says what happened to the local file, and an optional mono
/// [technical] line carrying the typed cause.
@immutable
class ErrorPresentation {
  const ErrorPresentation({
    required this.title,
    required this.body,
    this.technical,
  });

  /// Capture-side failures (§19).
  factory ErrorPresentation.forRecorder(
    RecorderErrorCode code,
    String message,
  ) {
    // design gap: only permissionDenied has a screen (1d). sourceUnavailable,
    // sourceClosed, cameraUnavailable, microphoneUnavailable,
    // systemAudioUnavailable, captureFailed, encodingFailed, diskFull,
    // finalizationFailed, invalidState and unsupported are undesigned; the copy
    // below is deliberately plain and structurally identical to 1k.
    final (String title, String body) copy = switch (code) {
      RecorderErrorCode.permissionDenied => (
        'Permission needed',
        'Recording cannot start until this permission is granted. Open System '
            'Settings, allow access, then try again.',
      ),
      RecorderErrorCode.sourceUnavailable => (
        'Source unavailable',
        'The selected screen or window could not be opened. Pick another '
            'source and try again.',
      ),
      RecorderErrorCode.sourceClosed => (
        'Source closed',
        'The screen or window being recorded is gone, so recording stopped. '
            'Nothing was deleted.',
      ),
      RecorderErrorCode.cameraUnavailable => (
        'Camera unavailable',
        'The camera stopped responding. Recording continues without it.',
      ),
      RecorderErrorCode.microphoneUnavailable => (
        'Microphone unavailable',
        'The microphone stopped responding. Recording continues without it.',
      ),
      RecorderErrorCode.systemAudioUnavailable => (
        'System audio unavailable',
        'System audio stopped responding. Recording continues without it.',
      ),
      RecorderErrorCode.captureFailed => (
        'Capture stopped',
        'Screen capture ended unexpectedly, so recording stopped. Nothing was '
            'deleted.',
      ),
      RecorderErrorCode.encodingFailed => (
        'Encoding stopped',
        'The encoder failed, so recording stopped. Nothing was deleted.',
      ),
      RecorderErrorCode.diskFull => (
        'Not enough disk space',
        'The disk ran out of room, so recording stopped. Free some space, then '
            'record again. Nothing was deleted.',
      ),
      RecorderErrorCode.finalizationFailed => (
        'Recording not finalized',
        'The file could not be written out completely. The partial recording '
            'is still on this computer and can be recovered at next launch.',
      ),
      RecorderErrorCode.invalidState => (
        'Recorder is busy',
        'That action does not apply right now. Wait for the current step to '
            'finish, then try again.',
      ),
      RecorderErrorCode.unsupported => (
        'Not supported here',
        'This system cannot do what was asked. Try a different source or '
            'quality.',
      ),
      RecorderErrorCode.unknown => (
        'Recording failed',
        'Something went wrong during recording. Nothing was deleted.',
      ),
    };

    return ErrorPresentation(
      title: copy.$1,
      body: copy.$2,
      technical: _technical('RecorderError.${code.name}', <String?>[message]),
    );
  }

  /// Upload failures (§14, design 1k).
  factory ErrorPresentation.forUpload(UploadError error) {
    // design gap: 1k specifies network and fileTooLarge. The remaining kinds
    // reuse the same layout, which 1k generalizes, with plain copy.
    final (String title, String body) copy = switch (error.kind) {
      UploadErrorKind.network => (
        'Upload interrupted',
        'The network dropped. Your recording is still on this computer and the '
            'upload can be resumed.',
      ),
      UploadErrorKind.fileTooLarge => (
        'Too large for this destination',
        'This recording is over the size limit of the selected destination, so '
            'the upload was not started. Your recording is kept. Send it '
            'somewhere else.',
      ),
      UploadErrorKind.authentication => (
        'Sign in again',
        'The destination did not accept this account. Sign in again, then '
            'retry. Your recording is kept.',
      ),
      UploadErrorKind.notConfigured => (
        'Destination not set up',
        'This destination is missing its configuration. Finish setting it up '
            'or choose another one. Your recording is kept.',
      ),
      UploadErrorKind.sessionExpired => (
        'Upload session expired',
        'The upload could not be resumed and has to start over. Your recording '
            'is kept.',
      ),
      UploadErrorKind.destinationRejected => (
        'Destination refused the upload',
        'The destination declined this recording. Try another destination. '
            'Your recording is kept.',
      ),
      UploadErrorKind.rateLimited => (
        'Destination is busy',
        'The destination is rate limiting uploads right now. Retry in a '
            'moment. Your recording is kept.',
      ),
      UploadErrorKind.localFileUnavailable => (
        'Recording file not found',
        'The file could not be read from disk. It may have been moved, renamed '
            'or removed outside the app.',
      ),
      UploadErrorKind.cancelled => (
        'Upload cancelled',
        'Nothing was sent. Your recording is kept on this computer.',
      ),
      UploadErrorKind.unknown => (
        'Upload failed',
        'The upload did not complete. Your recording is kept on this computer.',
      ),
    };

    // The destination's own message is diagnostics, not a second copy of the
    // body: design `1k` keeps the mono line terse. Drop it when the generated
    // body already says the same thing.
    final bool messageEchoesBody = _echoes(error.message, copy.$2);
    return ErrorPresentation(
      title: copy.$1,
      body: copy.$2,
      technical: _technical('UploadError.${error.kind.name}', <String?>[
        if (!messageEchoesBody) error.message,
        error.details,
        if (error.retryAfter != null)
          'retry in ${error.retryAfter!.inSeconds}s',
      ]),
    );
  }

  final String title;

  final String body;

  /// Mono diagnostic line, safe to render: redacted as it is built.
  final String? technical;

  static const LogRedactor _redactor = LogRedactor();

  static bool _echoes(String message, String body) {
    String normalize(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    final String left = normalize(message);
    final String right = normalize(body);
    if (left.isEmpty) {
      return true;
    }
    return right.contains(left) || left.contains(right);
  }

  static String _technical(String typedCause, List<String?> parts) {
    final Iterable<String> segments = <String>[
      typedCause,
      ...parts.whereType<String>().where(
        (String part) => part.trim().isNotEmpty,
      ),
    ];
    return _redactor.redactText(segments.join(' · '));
  }

  @override
  String toString() => 'ErrorPresentation($title)';
}
