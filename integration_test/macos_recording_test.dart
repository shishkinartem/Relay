@Tags(<String>['platform'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

/// Real capture on the host platform (`docs/development/testing.md`).
///
/// Run with `flutter test integration_test -d macos --run-skipped`.
///
/// `--run-skipped` is required: the `platform` tag above is configured to skip in
/// `dart_test.yaml`, so without it the command below runs none of these tests and
/// still exits 0. A second gate then applies — the recording test also skips when
/// `canRecordScreen` is false — but it reports that skip rather than passing
/// silently.
///
/// It records for a few
/// seconds against a real display source and asserts the file the pipeline
/// produced, including the §6 requirement that every application-owned overlay
/// reached the capture filter's exclusion list before capture started.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Recorder recorder;
  late RecorderPermissions permissions;
  late OverlayWindowController overlays;
  late Directory outputDirectory;

  setUpAll(() {
    final RecorderPlatform platform = RecorderPlatform.instance;
    recorder = platform.recorder;
    permissions = platform.permissions;
    overlays = platform.overlays;
    outputDirectory = Directory.systemTemp.createTempSync('relay_integration_');
  });

  tearDownAll(() {
    if (outputDirectory.existsSync()) {
      outputDirectory.deleteSync(recursive: true);
    }
  });

  testWidgets('a platform implementation is registered', (_) async {
    final RecorderCapabilities capabilities = await recorder.getCapabilities();
    expect(
      capabilities.isSupported,
      isTrue,
      reason: capabilities.unsupportedReason ?? 'no platform registered',
    );
    expect(capabilities.supportedFrameRates, contains(30));
    expect(
      capabilities.supportedSourceTypes,
      contains(CaptureSourceType.display),
    );
  });

  testWidgets('overlay windows are created and reach the exclusion list', (
    _,
  ) async {
    // Needs no permission: this is window management, and it is the surface
    // that keeps the strip out of the recording (§6).
    await overlays.showControlStrip(
      const OverlayPlacement.anchored(
        size: Size(360, 46),
        anchor: OverlayAnchor.topCenter,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await overlays.updateControlStrip(
      const RecordingOverlayState(elapsed: Duration(seconds: 3)),
    );

    await overlays.showCameraPreview(
      const OverlayPlacement.absolute(Rect.fromLTWH(40, 40, 150, 174)),
      matchesCompositedPip: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final List<String> excluded = await overlays.excludedWindowIds();
    expect(
      excluded.length,
      greaterThanOrEqualTo(2),
      reason: 'both overlay windows must reach the capture exclusion list',
    );

    await overlays.hideCameraPreview();
    await overlays.hideControlStrip();
  });

  testWidgets('sources are enumerated, displays before windows', (_) async {
    final PermissionReport report = await permissions.check();
    if (!report.canRecordScreen) {
      markTestSkipped(
        'Screen recording permission is not granted to this build. '
        'Grant it in System Settings and relaunch.',
      );
      return;
    }
    final List<CaptureSource> sources = await recorder.getAvailableSources();
    expect(sources, isNotEmpty);
    final int firstWindow = sources.indexWhere(
      (CaptureSource s) => s.type == CaptureSourceType.window,
    );
    final int lastDisplay = sources.lastIndexWhere(
      (CaptureSource s) => s.type == CaptureSourceType.display,
    );
    if (firstWindow >= 0) {
      expect(lastDisplay, lessThan(firstWindow));
    }
    expect(
      sources.where((CaptureSource s) => s.type == CaptureSourceType.display),
      isNotEmpty,
    );
  });

  testWidgets('records a display source to a playable MP4', (_) async {
    final PermissionReport report = await permissions.check();
    if (!report.canRecordScreen) {
      markTestSkipped('Screen recording permission is not granted.');
      return;
    }

    final List<CaptureSource> sources = await recorder.getAvailableSources(
      refreshThumbnails: false,
    );
    final CaptureSource display = sources.firstWhere(
      (CaptureSource s) => s.type == CaptureSourceType.display,
    );

    final List<RecorderEvent> events = <RecorderEvent>[];
    final Stream<RecorderEvent> stream = recorder.events;
    final StreamSubscription<RecorderEvent> subscription = stream.listen(
      events.add,
    );
    addTearDown(subscription.cancel);

    await recorder.prepare(
      RecordingConfiguration(
        source: display,
        recordingId: 'itest',
        outputDirectoryPath: outputDirectory.path,
        quality: RecordingQuality.hd720,
        frameRate: 30,
        microphoneEnabled: false,
        systemAudioEnabled: true,
        cameraEnabled: false,
      ),
    );

    await overlays.showControlStrip(
      const OverlayPlacement.anchored(
        size: Size(360, 46),
        anchor: OverlayAnchor.topCenter,
      ),
    );

    await recorder.start();
    await Future<void>.delayed(const Duration(seconds: 3));
    await recorder.pause();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await recorder.resume();
    await Future<void>.delayed(const Duration(seconds: 2));

    final RecordingFile file = await recorder.stop();
    await overlays.hideControlStrip();

    expect(File(file.path).existsSync(), isTrue);
    expect(file.sizeBytes, greaterThan(10 * 1024));
    expect(file.path, endsWith('.mp4'));
    expect(
      File('${outputDirectory.path}/recording-itest.part').existsSync(),
      isFalse,
      reason: 'the .part artefact is renamed on successful finalization',
    );
    // Paused time is excluded from the timeline, so the file is about the five
    // seconds that were actually recorded, not the 5.5 that elapsed.
    expect(file.duration.inMilliseconds, greaterThan(3000));
    expect(file.duration.inMilliseconds, lessThan(5400));

    final Iterable<RecorderErrorEvent> fatal = events
        .whereType<RecorderErrorEvent>()
        .where((RecorderErrorEvent e) => e.fatal);
    expect(
      fatal,
      isEmpty,
      reason: fatal.map((RecorderErrorEvent e) => e.message).join(', '),
    );
  });

  testWidgets('stop is idempotent', (_) async {
    final PermissionReport report = await permissions.check();
    if (!report.canRecordScreen) {
      markTestSkipped('Screen recording permission is not granted.');
      return;
    }
    final RecordingFile again = await recorder.stop();
    expect(File(again.path).existsSync(), isTrue);
  });
}
