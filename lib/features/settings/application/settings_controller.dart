import 'package:flutter/foundation.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/settings/app_settings.dart';
import '../../../core/settings/settings_repository.dart';

/// The persisted settings, as everything above them sees them.
///
/// A [Listenable] rather than a `ChangeNotifier`: a substitute has to be
/// observable, and does not have to inherit an implementation to be so.
abstract interface class SettingsGateway implements Listenable {
  AppSettings get settings;

  bool get isLoaded;

  Future<void> load();

  Future<void> update(AppSettings next);

  Future<void> setQuality(RecordingQuality quality);

  Future<void> setFrameRate(int frameRate);

  Future<void> setMicrophoneEnabled(bool enabled);

  Future<void> setSystemAudioEnabled(bool enabled);

  Future<void> setCameraEnabled(bool enabled);

  Future<void> setShowCursor(bool enabled);

  Future<void> setPreferredSourceType(CaptureSourceType type);

  Future<void> setUploadDestination(String destinationId);

  Future<void> setLocalRecordingsDirectory(String? path);
}

/// Holds the persisted settings and the last-used session values.
///
/// Settings hold what outlives a session — destination, storage. Quality,
/// frame rate and cursor are per-session choices made on the launch screen,
/// which persists its last values through the same document (design `1m`).
class SettingsController extends ChangeNotifier implements SettingsGateway {
  SettingsController({required this._repository, required this._logger});

  final SettingsRepository _repository;
  final Logger _logger;

  AppSettings _settings = const AppSettings();
  bool _loaded = false;

  @override
  AppSettings get settings => _settings;

  @override
  bool get isLoaded => _loaded;

  @override
  Future<void> load() async {
    _settings = await _repository.load();
    _loaded = true;
    _logger.info(
      'settings_loaded',
      fields: <String, Object?>{
        'destination': _settings.uploadDestinationId,
        'quality': _settings.quality.name,
        'frameRate': _settings.frameRate,
      },
    );
    notifyListeners();
  }

  @override
  Future<void> update(AppSettings next) async {
    if (next == _settings) {
      return;
    }
    _settings = next;
    notifyListeners();
    await _repository.save(next);
  }

  @override
  Future<void> setQuality(RecordingQuality quality) =>
      update(_settings.copyWith(quality: quality));

  @override
  Future<void> setFrameRate(int frameRate) =>
      update(_settings.copyWith(frameRate: frameRate));

  @override
  Future<void> setMicrophoneEnabled(bool enabled) =>
      update(_settings.copyWith(microphoneEnabled: enabled));

  @override
  Future<void> setSystemAudioEnabled(bool enabled) =>
      update(_settings.copyWith(systemAudioEnabled: enabled));

  @override
  Future<void> setCameraEnabled(bool enabled) =>
      update(_settings.copyWith(cameraEnabled: enabled));

  @override
  Future<void> setShowCursor(bool enabled) =>
      update(_settings.copyWith(showCursor: enabled));

  @override
  Future<void> setPreferredSourceType(CaptureSourceType type) =>
      update(_settings.copyWith(preferredSourceType: type));

  @override
  Future<void> setUploadDestination(String destinationId) =>
      update(_settings.copyWith(uploadDestinationId: destinationId));

  @override
  Future<void> setLocalRecordingsDirectory(String? path) =>
      update(_settings.copyWith(localRecordingsDirectory: path));
}
