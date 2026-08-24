import 'package:flutter/widgets.dart';

import '../core/environment/app_environment.dart';
import '../core/logging/app_logger.dart';
import '../features/recorder/application/recorder_view_model.dart';
import '../features/settings/application/settings_controller.dart';
import '../upload/application/upload_destination_registry.dart';

/// The composition root's handle, passed down the tree.
///
/// Screens read collaborators from here rather than constructing them, which
/// is what lets a widget test mount any screen against fakes.
///
/// An [InheritedNotifier] over both controllers, not a plain
/// [InheritedWidget]: every screen that reads the scope — including one pushed
/// onto the navigator — rebuilds when the session or the settings change.
/// Without that, a toggle updates the model and nothing on screen moves.
class AppScope extends InheritedNotifier<Listenable> {
  AppScope({
    super.key,
    required this.recorder,
    required this.settings,
    required this.destinations,
    required this.environment,
    required this.logger,
    required super.child,
  }) : super(notifier: Listenable.merge(<Listenable>[recorder, settings]));

  final RecorderViewModel recorder;
  final SettingsGateway settings;
  final DestinationRegistry destinations;
  final AppEnvironment environment;
  final Logger logger;

  static AppScope of(BuildContext context) {
    final AppScope? scope = context
        .dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope above this widget.');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      super.updateShouldNotify(oldWidget) ||
      oldWidget.recorder != recorder ||
      oldWidget.settings != settings ||
      oldWidget.destinations != destinations;
}
