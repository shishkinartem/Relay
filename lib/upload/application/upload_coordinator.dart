import 'dart:async';

import 'package:upload_core/upload_core.dart';

import '../../core/ids.dart';
import '../../core/logging/app_logger.dart';
import 'upload_destination_registry.dart';

/// One upload at a time, as the session sees it (§14).
///
/// Deliberately without any way to delete: removal lives behind
/// `RecordingStore` and needs a stated reason, so nothing on the upload side
/// can remove a recording even by mistake.
abstract interface class Uploads {
  Stream<UploadEvent> get events;

  bool get isActive;

  String? get activeDestinationId;

  /// Returns the upload id, or null when pre-flight rejected the file.
  Future<String?> start({
    required UploadFile file,
    required String destinationId,
    String? caption,
  });

  Future<void> cancel();

  /// Releases the event stream and any in-flight subscription. Idempotent.
  Future<void> dispose();
}

/// Drives one upload at a time and normalizes what destinations report
/// (§14, `docs/architecture/uploads.md`).
///
/// It deliberately does **not** delete anything. Success is reported here; the
/// deletion happens in the recorder feature through `LocalRecordingStore`,
/// which requires a stated [DeletionReason]. Keeping the two apart is what
/// makes "never delete before confirmed remote success" a property of the code
/// rather than of a comment.
class UploadCoordinator implements Uploads {
  UploadCoordinator({required this._registry, required this._logger});

  final DestinationRegistry _registry;
  final Logger _logger;

  final StreamController<UploadEvent> _events =
      StreamController<UploadEvent>.broadcast();
  StreamSubscription<UploadEvent>? _subscription;

  String? _activeUploadId;
  String? _activeDestinationId;

  @override
  Stream<UploadEvent> get events => _events.stream;

  @override
  bool get isActive => _activeUploadId != null;

  @override
  String? get activeDestinationId => _activeDestinationId;

  /// Validates, then uploads. Returns the upload id, or null when validation
  /// rejected the file — in which case a terminal [UploadFailed] was emitted
  /// and no bytes were sent.
  @override
  Future<String?> start({
    required UploadFile file,
    required String destinationId,
    String? caption,
  }) async {
    if (isActive) {
      _logger.warn(
        'upload_start_ignored',
        fields: <String, Object?>{
          'reason': 'an upload is already running',
          'destinationId': destinationId,
        },
      );
      return null;
    }

    final UploadDestination destination = _registry.resolve(destinationId);
    final String uploadId = newId(6);
    _activeUploadId = uploadId;
    _activeDestinationId = destination.id;

    _events.add(UploadValidating(uploadId));
    final UploadValidationResult validation = await destination.validate(file);
    if (!validation.isValid) {
      _logger.warn(
        'upload_rejected',
        fields: <String, Object?>{
          'uploadId': uploadId,
          'destinationId': destination.id,
          'kind': validation.error!.kind.name,
        },
      );
      _finish();
      _events.add(UploadFailed(uploadId, validation.error!));
      return null;
    }

    _logger.info(
      'upload_started',
      fields: <String, Object?>{
        'uploadId': uploadId,
        'destinationId': destination.id,
        'sizeBytes': file.sizeBytes,
      },
    );

    final Completer<void> done = Completer<void>();
    _subscription = destination
        .upload(file, UploadContext(uploadId: uploadId, caption: caption))
        .listen(
          (UploadEvent event) {
            _events.add(event);
            if (event is UploadSucceeded ||
                event is UploadFailed ||
                event is UploadCancelled) {
              _logTerminal(event, destination.id);
              _finish();
              if (!done.isCompleted) {
                done.complete();
              }
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            final UploadError mapped = error is UploadError
                ? error
                : UploadError(
                    UploadErrorKind.unknown,
                    'The upload ended unexpectedly.',
                    details: error.runtimeType.toString(),
                  );
            _logger.error(
              'upload_stream_error',
              fields: <String, Object?>{
                'uploadId': uploadId,
                'destinationId': destination.id,
                'kind': mapped.kind.name,
              },
            );
            _finish();
            _events.add(UploadFailed(uploadId, mapped));
            if (!done.isCompleted) {
              done.complete();
            }
          },
          onDone: () {
            // A destination that closes without a terminal event would leave
            // the session stuck in `uploading`; treat it as a failure so the
            // local file is preserved and the user can retry.
            if (_activeUploadId == uploadId) {
              _finish();
              _events.add(
                UploadFailed(
                  uploadId,
                  const UploadError(
                    UploadErrorKind.unknown,
                    'The upload ended without a result.',
                  ),
                ),
              );
            }
            if (!done.isCompleted) {
              done.complete();
            }
          },
          cancelOnError: true,
        );

    return uploadId;
  }

  /// Cancels the active upload. Idempotent and safe when nothing is running.
  @override
  Future<void> cancel() async {
    final String? uploadId = _activeUploadId;
    final String? destinationId = _activeDestinationId;
    if (uploadId == null || destinationId == null) {
      return;
    }
    await _registry.resolve(destinationId).cancel(uploadId);
  }

  void _logTerminal(UploadEvent event, String destinationId) {
    switch (event) {
      case UploadSucceeded(:final RemoteUploadResult result):
        _logger.info(
          'upload_succeeded',
          fields: <String, Object?>{
            'uploadId': event.uploadId,
            'destinationId': destinationId,
            'remoteFileId': result.remoteFileId,
          },
        );
      case UploadFailed(:final UploadError error):
        _logger.warn(
          'upload_failed',
          fields: <String, Object?>{
            'uploadId': event.uploadId,
            'destinationId': destinationId,
            'kind': error.kind.name,
          },
        );
      case UploadCancelled():
        _logger.info(
          'upload_cancelled',
          fields: <String, Object?>{
            'uploadId': event.uploadId,
            'destinationId': destinationId,
          },
        );
      default:
        break;
    }
  }

  void _finish() {
    _activeUploadId = null;
    _activeDestinationId = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    if (!_events.isClosed) {
      await _events.close();
    }
  }
}
