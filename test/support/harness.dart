import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:relay/app/app_scope.dart';
import 'package:relay/core/environment/app_environment.dart';
import 'package:relay/core/logging/app_logger.dart';
import 'package:relay/core/settings/app_settings.dart';
import 'package:relay/core/settings/settings_repository.dart';
import 'package:relay/design_system/design_system.dart';
import 'package:relay/features/recorder/application/overlay_presenter.dart';
import 'package:relay/features/recorder/application/recorder_view_model.dart';
import 'package:relay/features/recorder/domain/local_recording_store.dart';
import 'package:relay/features/settings/application/settings_controller.dart';
import 'package:relay/upload/application/upload_coordinator.dart';
import 'package:relay/upload/application/upload_destination_registry.dart';
import 'package:upload_core/upload_core.dart';

import 'fakes.dart';

/// Everything a screen needs, wired to fakes.
class TestHarness {
  TestHarness._({
    required this.recorder,
    required this.permissions,
    required this.overlays,
    required this.settings,
    required this.destinations,
    required this.uploads,
    required this.viewModel,
    required this.logger,
    required this.directory,
  });

  final FakeRecorder recorder;
  final FakeRecorderPermissions permissions;
  final FakeOverlayWindowController overlays;
  final SettingsController settings;
  final UploadDestinationRegistry destinations;
  final UploadCoordinator uploads;
  final RecorderViewModel viewModel;
  final AppLogger logger;
  final Directory directory;

  static Future<TestHarness> create({
    FakeRecorder? recorder,
    FakeRecorderPermissions? permissions,
    List<UploadDestination>? destinations,
    AppSettings settings = const AppSettings(),
    Directory? directory,
    DateTime Function()? clock,
  }) async {
    // The view model observes the app lifecycle to re-read permissions, which
    // needs a binding even in a non-widget test.
    TestWidgetsFlutterBinding.ensureInitialized();
    final FakeRecorder fakeRecorder = recorder ?? FakeRecorder();
    final FakeRecorderPermissions fakePermissions =
        permissions ?? FakeRecorderPermissions();
    final FakeOverlayWindowController fakeOverlays =
        FakeOverlayWindowController();
    final AppLogger logger = AppLogger(sinks: <LogSink>[MemoryLogSink()]);
    final SettingsController settingsController = SettingsController(
      repository: InMemorySettingsRepository(settings),
      logger: logger,
    );
    await settingsController.load();

    final UploadDestinationRegistry registry = UploadDestinationRegistry(
      destinations ??
          <UploadDestination>[
            FakeUploadDestination(
              id: 'telegram',
              displayName: 'Telegram',
              capabilities: const UploadCapabilities(
                maxFileSizeBytes: 50 * 1024 * 1024,
                transportSummary: 'Hosted Bot API',
              ),
              account: 'Hosted Bot API',
            ),
            FakeUploadDestination(
              id: 'webdav',
              displayName: 'WebDAV',
              capabilities: const UploadCapabilities(
                requiresAuthentication: true,
                transportSummary: 'Single upload · no size limit',
              ),
              account: 'app.koofr.net · recorder@example.com · /Relay',
            ),
          ],
    );
    final UploadCoordinator uploads = UploadCoordinator(
      registry: registry,
      logger: logger,
    );
    final Directory recordings =
        directory ?? Directory.systemTemp.createTempSync('relay_harness_');

    final RecorderViewModel viewModel = RecorderViewModel(
      recorder: fakeRecorder,
      permissions: fakePermissions,
      overlays: OverlayPresenter(overlays: fakeOverlays),
      store: LocalRecordingStore(directory: recordings, logger: logger),
      settings: settingsController,
      uploads: uploads,
      destinations: registry,
      logger: logger,
      clock: clock ?? () => DateTime.utc(2026, 8, 22, 14, 22),
    );

    return TestHarness._(
      recorder: fakeRecorder,
      permissions: fakePermissions,
      overlays: fakeOverlays,
      settings: settingsController,
      destinations: registry,
      uploads: uploads,
      viewModel: viewModel,
      logger: logger,
      directory: recordings,
    );
  }

  Future<void> initialize() => viewModel.initialize();

  Widget wrap(Widget child) => RelayTheme(
    child: AppScope(
      recorder: viewModel,
      settings: settings,
      destinations: destinations,
      environment: const AppEnvironment(<String, String>{}),
      logger: logger,
      child: _TestApp(child: child),
    ),
  );

  Future<void> dispose() async {
    await overlays.dispose();
    await uploads.dispose();
    viewModel.dispose();
    if (directory.existsSync()) {
      directory.deleteSync(recursive: true);
    }
  }
}

/// A minimal app shell: a `Navigator` so routes and dialogs work, an `Overlay`
/// so tooltips work, and nothing from Material.
class _TestApp extends StatelessWidget {
  const _TestApp({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => WidgetsApp(
    color: AppColors.accent,
    debugShowCheckedModeBanner: false,
    pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
        PageRouteBuilder<T>(
          settings: settings,
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (BuildContext context, _, _) => builder(context),
        ),
    home: RelayTheme(child: child),
  );
}

bool _fontsLoaded = false;

/// Loads the vendored Barlow faces so tests measure and render text the way the
/// application does. Without this every glyph is a placeholder box.
///
/// Must be called from inside a test body: `rootBundle` is served by the test
/// binding's message loop, which is not running during `setUpAll`.
Future<void> loadDesignFonts() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (_fontsLoaded) {
    return;
  }
  _fontsLoaded = true;
  for (final MapEntry<String, List<String>> family in <String, List<String>>{
    'Barlow': <String>[
      'assets/fonts/Barlow-Regular.ttf',
      'assets/fonts/Barlow-Medium.ttf',
      'assets/fonts/Barlow-Bold.ttf',
    ],
    'Barlow Condensed': <String>[
      'assets/fonts/BarlowCondensed-Regular.ttf',
      'assets/fonts/BarlowCondensed-SemiBold.ttf',
    ],
    'RelayMono': <String>['assets/fonts/IBMPlexMono-Regular.ttf'],
  }.entries) {
    final FontLoader loader = FontLoader(family.key);
    for (final String asset in family.value) {
      loader.addFont(rootBundle.load(asset));
    }
    await loader.load();
  }
}

/// The main panel's size, so a screen is laid out exactly as it ships.
const Size panelSize = Size(AppSpacing.panelWidth, AppSpacing.panelMaxHeight);
