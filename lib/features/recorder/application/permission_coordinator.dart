import 'dart:async';

import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../core/logging/app_logger.dart';

/// The permission answers the session works from (§23).
///
/// Declared next to its consumer, like every other role interface in this
/// layer: the application decides what it needs from permissions, and the
/// implementation below satisfies it.
///
/// Deliberately returns values and dispatches nothing. What a denial *means*
/// differs by caller — a refused microphone degrades the session, a refused
/// screen recording blocks it — so the decision stays where that context is.
abstract interface class SessionPermissions {
  /// The last report read. Empty until [refresh] has run once.
  PermissionReport get report;

  /// True when the last [refresh] could not reach the platform at all.
  ///
  /// An unreachable platform and a first run are indistinguishable in the
  /// report itself — both read `notDetermined` for every kind — and they need
  /// opposite screens, so the difference is carried here.
  bool get lastCheckFailed;

  /// Re-reads every permission. Never throws.
  Future<PermissionReport> refresh();

  /// Shows the operating system's prompt for [kind]. Never throws.
  Future<void> prompt(PermissionKind kind);

  /// Prompts, then re-reads.
  Future<PermissionReport> requestAndRefresh(PermissionKind kind);

  /// Prompts only for an input that has never been asked about.
  Future<void> requestQuietly(PermissionKind kind);

  /// Opens the operating system's privacy pane for [kind].
  Future<void> openSettings(PermissionKind kind);

  /// Quits and reopens the application, so a permission the platform applies
  /// only to a fresh process takes effect. Never throws.
  Future<void> relaunchApplication();

  /// Quits the application through the ordinary exit path. Never throws.
  Future<void> quitApplication();
}

/// [SessionPermissions] against the platform contract.
///
/// Split out of `RecorderViewModel` because reading a permission, asking for
/// one and opening the privacy pane are one concern with one failure rule, and
/// the capture lifecycle only ever wants the answer.
class PermissionCoordinator implements SessionPermissions {
  PermissionCoordinator({
    required this._permissions,
    required this._logger,
    required this._checkTimeout,
    required this._promptTimeout,
  });

  final RecorderPermissions _permissions;
  final Logger _logger;

  /// A check is a question the platform can answer immediately.
  final Duration _checkTimeout;

  /// A prompt is a question *the user* answers, and they may be reading it.
  /// The same eight-second deadline that keeps a hung platform call from
  /// freezing the application would cancel a dialog someone is still looking
  /// at.
  final Duration _promptTimeout;

  PermissionReport _report = const PermissionReport(
    <PermissionKind, PermissionStatus>{},
  );
  bool _lastCheckFailed = false;

  /// Reads run one at a time, in the order they were asked for.
  ///
  /// Two overlapping checks publish in completion order, not request order, so
  /// a read that started before the user answered a prompt could overwrite the
  /// one that started after it — and the screen would then offer an action for
  /// an answer that no longer holds.
  Future<void> _queue = Future<void>.value();

  @override
  PermissionReport get report => _report;

  @override
  bool get lastCheckFailed => _lastCheckFailed;

  /// Re-reads every permission.
  ///
  /// Never throws and never leaves a stale answer in place: a check that fails
  /// or times out empties the report, so nothing reads as usable and the
  /// session degrades rather than starting on an assumption. An empty report
  /// reads back as `notDetermined`, which is indistinguishable from a first
  /// run — [lastCheckFailed] is what tells the two apart.
  @override
  Future<PermissionReport> refresh() {
    final Future<PermissionReport> result = _queue.then((_) => _read());
    _queue = result.then((_) {}, onError: (_, _) {});
    return result;
  }

  Future<PermissionReport> _read() async {
    try {
      _report = await _permissions.check().timeout(_checkTimeout);
      _lastCheckFailed = false;
    } on Object catch (e) {
      _logger.warn(
        'permission_check_failed',
        fields: <String, Object?>{'error': e.runtimeType.toString()},
      );
      _report = const PermissionReport(<PermissionKind, PermissionStatus>{});
      _lastCheckFailed = true;
    }
    return _report;
  }

  /// Shows the operating system's prompt for [kind]. Never throws.
  @override
  Future<void> prompt(PermissionKind kind) async {
    try {
      await _permissions.request(kind).timeout(_promptTimeout);
    } on Object catch (e) {
      _logger.warn(
        'permission_request_failed',
        fields: <String, Object?>{
          'kind': kind.name,
          'error': e.runtimeType.toString(),
        },
      );
    }
  }

  /// Prompts, then re-reads.
  ///
  /// The re-read is the point: the prompt's own answer says what the user
  /// tapped, and the report says what the system now permits. On macOS those
  /// differ for screen recording, which is granted to the signed binary and
  /// only takes effect on the next launch.
  @override
  Future<PermissionReport> requestAndRefresh(PermissionKind kind) async {
    await prompt(kind);
    return refresh();
  }

  /// Prompts only for an input that has never been asked about.
  ///
  /// The prompt happens at the moment the input is actually needed. Sending a
  /// user to a privacy list that does not yet contain this application would
  /// be useless — macOS lists an app under a category only once it has asked.
  /// A refusal degrades the session later; it must not interrupt the start
  /// they just asked for, so nothing is re-read here.
  @override
  Future<void> requestQuietly(PermissionKind kind) async {
    if (_report[kind] != PermissionStatus.notDetermined) {
      return;
    }
    await prompt(kind);
  }

  /// Opens the operating system's privacy pane for [kind].
  ///
  /// Some permissions cannot be prompted for twice, so this is the only
  /// remaining path once one has been denied (design `1d`).
  @override
  Future<void> openSettings(PermissionKind kind) async {
    try {
      await _permissions.openSystemSettings(kind).timeout(_checkTimeout);
    } on Object catch (e) {
      _logger.warn(
        'open_permission_settings_failed',
        fields: <String, Object?>{
          'kind': kind.name,
          'error': e.runtimeType.toString(),
        },
      );
    }
  }

  /// Quits and reopens the application.
  ///
  /// A failure must leave the application running rather than half-closed, so
  /// a refusal is logged and swallowed like every other platform call here.
  @override
  Future<void> relaunchApplication() async {
    try {
      await _permissions.relaunchApplication().timeout(_checkTimeout);
    } on Object catch (e) {
      _logger.warn(
        'relaunch_failed',
        fields: <String, Object?>{'error': e.runtimeType.toString()},
      );
    }
  }

  @override
  Future<void> quitApplication() async {
    try {
      await _permissions.quitApplication().timeout(_checkTimeout);
    } on Object catch (e) {
      _logger.warn(
        'quit_failed',
        fields: <String, Object?>{'error': e.runtimeType.toString()},
      );
    }
  }
}
