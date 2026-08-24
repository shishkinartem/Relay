import 'package:flutter/widgets.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../app/app_scope.dart';
import '../../../app/panel_route.dart';
import '../../../design_system/design_system.dart';
import '../../settings/presentation/settings_screen.dart';
import '../application/recorder_view_model.dart';
import '../domain/session_state.dart';

/// Permission preflight (design `1d`, §23).
///
/// Two screens, not one, because the two states have nothing in common but the
/// permission vocabulary.
///
/// *Blocking* — screen recording is not usable, so there is nothing to record.
/// It shows the one permission that is in the way and the one action that can
/// change it. Listing the optional inputs beside it, as this screen used to,
/// made three failures out of one and left the only blocking row as the only
/// row without a fix.
///
/// *Degraded* — the recording is possible, an input the user switched on is
/// not. This is the screen the design draws: three rows, and a Start that says
/// what it will do.
class PreflightScreen extends StatelessWidget {
  const PreflightScreen({super.key, required this.state});

  final SessionPreflight state;

  @override
  Widget build(BuildContext context) => state.canStart
      ? _DegradedPreflight(state: state)
      : _BlockingPreflight(state: state);
}

/// What is standing between the user and a recording, in the order the screen
/// has to resolve it.
///
/// Ordered by how much the user can do about it, not by likelihood: a state
/// nobody can fix must never be presented as one button away.
enum _Blocker {
  /// No platform implementation at all — a permission is not the problem.
  unsupported,

  /// The platform could not be asked. Indistinguishable from a first run in
  /// the report itself, which is why it is asked about separately.
  checkFailed,

  /// A policy on the device forbids it. No prompt, no relaunch, no remedy.
  restricted,

  /// Asked and answered; the platform applies the answer to a fresh process.
  pendingRelaunch,

  /// The process was not started by the platform's own launcher, so the
  /// permission belongs to whatever started it.
  notLaunchedByApp,

  /// Never asked. The system prompt is the remedy, and the privacy pane is
  /// not: the application is not in that list until it has asked.
  notAsked,

  /// Asked in an earlier run and refused. Only the privacy pane can change it.
  refused,
}

_Blocker _resolve(RecorderViewModel vm, SessionPreflight state) {
  final PermissionStatus status = state.report[PermissionKind.screenRecording];
  if (!vm.capabilities.isSupported) {
    return _Blocker.unsupported;
  }
  if (vm.permissionCheckFailed) {
    return _Blocker.checkFailed;
  }
  if (status == PermissionStatus.restricted) {
    return _Blocker.restricted;
  }
  // Before the launcher check: an answer already given is applied by reopening,
  // which is also what repairs a mis-attributed launch.
  if (status == PermissionStatus.pendingRelaunch) {
    return _Blocker.pendingRelaunch;
  }
  if (!vm.capabilities.screenRecordingLaunchedByThisApp) {
    return _Blocker.notLaunchedByApp;
  }
  return status == PermissionStatus.denied
      ? _Blocker.refused
      : _Blocker.notAsked;
}

class _BlockingPreflight extends StatelessWidget {
  const _BlockingPreflight({required this.state});

  final SessionPreflight state;

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    final _Blocker blocker = _resolve(vm, state);

    return AppPanel(
      title: 'Recorder',
      // Connecting a destination needs no permission from anyone, so it must
      // not sit behind one. Without this the screen is a room with no doors.
      titleBarTrailing: AppIconButton(
        icon: AppIcons.settings,
        semanticLabel: 'Settings',
        variant: AppButtonVariant.ghost,
        size: 24,
        onPressed: () =>
            Navigator.of(context)
                .push<void>(panelRoute(const SettingsScreen())),
      ),
      // The one action that can change anything is pinned, so it is never the
      // thing the user has to scroll to find.
      footer: _BlockingActions(blocker: blocker, vm: vm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const AppKicker('Screen recording'),
          const SizedBox(height: 10),
          for (final String paragraph in _body(blocker, vm)) ...<Widget>[
            Text(paragraph, style: AppTypography.bodySmall),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 2),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.divider),
            ),
            child: _PermissionRow(
              label: 'Screen & window recording',
              status: state.report[PermissionKind.screenRecording],
              marker: _marker(blocker),
              tag: _tag(blocker),
              tagTone: _tagTone(blocker),
              last: true,
            ),
          ),
        ],
      ),
    );
  }

  static List<String> _body(_Blocker blocker, RecorderViewModel vm) =>
      switch (blocker) {
        _Blocker.unsupported => <String>[
          vm.capabilities.unsupportedReason ??
              'Relay cannot record on this computer.',
        ],
        _Blocker.checkFailed => <String>[
          'Relay could not ask the system what it is allowed to record.',
          'This is a fault in Relay or in the system, not something you did.',
        ],
        _Blocker.restricted => <String>[
          'A policy on this computer blocks screen recording, so Relay cannot '
              'record.',
          'Whoever manages this computer can change it.',
        ],
        _Blocker.pendingRelaunch => <String>[
          'The system is handling your answer in its own window. Relay only '
              'sees it after opening again.',
          'Answer that window first, then reopen Relay.',
        ],
        _Blocker.notLaunchedByApp => <String>[
          'Relay was not opened the usual way, so the system is giving the '
              'screen-recording permission to whatever started it instead of '
              'to Relay.',
          'Reopening Relay through its own launcher fixes that.',
        ],
        _Blocker.notAsked => <String>[
          'Relay records your screen — or a single window you pick — to a '
              'video file on this computer. Nothing leaves it until you send '
              'the recording yourself.',
          'The system will not let any app see the screen without your '
              'permission.',
        ],
        _Blocker.refused => <String>[
          'The system is not letting Relay see the screen, so there is nothing '
              'to record yet.',
          'Switch Relay on under Privacy & Security, then open Relay again.',
        ],
      };

  static Widget _marker(_Blocker blocker) => switch (blocker) {
    // Nothing has failed yet — an unanswered question is not a refusal, and an
    // X beside it says it is.
    _Blocker.notAsked ||
    _Blocker.checkFailed ||
    _Blocker.pendingRelaunch => const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: StatusDot(active: false),
    ),
    _ => const AppIcon(AppIcons.close, size: 16, color: AppColors.neutral600),
  };

  static String _tag(_Blocker blocker) => switch (blocker) {
    _Blocker.unsupported => 'Unavailable',
    _Blocker.checkFailed => 'Unknown',
    _Blocker.restricted => 'Blocked by policy',
    _Blocker.pendingRelaunch => 'Restart to apply',
    _Blocker.notLaunchedByApp => 'Given to another app',
    _Blocker.notAsked => 'Not asked yet',
    _Blocker.refused => 'Not granted',
  };

  static AppTagTone _tagTone(_Blocker blocker) => switch (blocker) {
    _Blocker.pendingRelaunch => AppTagTone.accentSecondary,
    _Blocker.notAsked || _Blocker.checkFailed => AppTagTone.outline,
    _ => AppTagTone.neutral,
  };
}

/// The actions for each blocking state, plus the one line under them.
///
/// Every state that can be acted on offers both remedies it has: the stored
/// "already asked" flag can be wrong in either direction — a privacy-database
/// reset clears the system's answer but not Relay's memory of asking — and a
/// screen with the one button that cannot work is the dead end this flow keeps
/// producing.
class _BlockingActions extends StatelessWidget {
  const _BlockingActions({required this.blocker, required this.vm});

  final _Blocker blocker;
  final RecorderViewModel vm;

  @override
  Widget build(BuildContext context) {
    final List<Widget> actions = switch (blocker) {
      _Blocker.unsupported => <Widget>[],
      _Blocker.checkFailed => <Widget>[
        AppButton(
          label: 'Try again',
          variant: AppButtonVariant.primary,
          expand: true,
          height: 38,
          busy: vm.isRefreshingPermissions,
          onPressed: vm.refreshPermissionsAndSources,
        ),
        _note('Nothing is recording.'),
      ],
      _Blocker.restricted => <Widget>[
        AppButton(
          label: 'Open System Settings',
          expand: true,
          height: 38,
          onPressed: () =>
              vm.openPermissionSettings(PermissionKind.screenRecording),
        ),
        _note('A restart will not change this.'),
      ],
      _Blocker.pendingRelaunch => <Widget>[
        AppButton(
          label: 'Quit and reopen Relay',
          variant: AppButtonVariant.primary,
          expand: true,
          height: 38,
          busy: vm.isBusy,
          onPressed: vm.relaunchApplication,
        ),
        _note('Nothing is recording, so nothing is lost.'),
        const SizedBox(height: 10),
        AppButton(
          label: 'Open System Settings',
          expand: true,
          height: 38,
          onPressed: () =>
              vm.openPermissionSettings(PermissionKind.screenRecording),
        ),
      ],
      _Blocker.notLaunchedByApp => <Widget>[
        AppButton(
          label: 'Quit and reopen Relay',
          variant: AppButtonVariant.primary,
          expand: true,
          height: 38,
          busy: vm.isBusy,
          onPressed: vm.relaunchApplication,
        ),
        _note('Relay reopens itself through its own launcher.'),
        const SizedBox(height: 10),
        AppButton(
          label: 'Quit Relay',
          expand: true,
          height: 38,
          onPressed: vm.quitApplication,
        ),
      ],
      _Blocker.notAsked => <Widget>[
        AppButton(
          label: 'Allow screen recording…',
          variant: AppButtonVariant.primary,
          expand: true,
          height: 38,
          busy: vm.isBusy,
          onPressed: () => vm.requestPermission(PermissionKind.screenRecording),
        ),
        _note(
          'The system asks in its own window. Relay has to open again before '
          'the answer takes effect.',
        ),
        const SizedBox(height: 8),
        AppButton(
          label: 'Open System Settings',
          variant: AppButtonVariant.ghost,
          fontSize: 12,
          expand: true,
          onPressed: () =>
              vm.openPermissionSettings(PermissionKind.screenRecording),
        ),
      ],
      _Blocker.refused => <Widget>[
        AppButton(
          label: 'Open System Settings',
          variant: AppButtonVariant.primary,
          expand: true,
          height: 38,
          onPressed: () =>
              vm.openPermissionSettings(PermissionKind.screenRecording),
        ),
        // No relaunch button here, deliberately. This is the one blocking state
        // whose remedy lives in System Settings, and switching Relay on there
        // raises the operating system's own "Quit & Reopen" — so offering the
        // same thing again is the app asking to do what the user has already
        // been asked. The state is not a dead end without it: choosing "Later"
        // in that prompt leaves the permission granted and this process unable
        // to see it, and "Ask the system anyway" below moves to
        // `pendingRelaunch`, which is the state that does offer the relaunch.
        _note('macOS offers to quit and reopen Relay when you switch it on.'),
        const SizedBox(height: 8),
        AppButton(
          label: 'Ask the system anyway',
          variant: AppButtonVariant.ghost,
          fontSize: 12,
          expand: true,
          onPressed: () => vm.requestPermission(PermissionKind.screenRecording),
        ),
      ],
    };

    if (actions.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.panelPadding,
        4,
        AppSpacing.panelPadding,
        AppSpacing.panelPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: actions,
      ),
    );
  }

  static Widget _note(String text) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Center(child: AppMonoText(text, textAlign: TextAlign.center)),
  );
}

/// The screen the design draws (`1d`): recording is possible, an input the user
/// asked for is not available.
class _DegradedPreflight extends StatelessWidget {
  const _DegradedPreflight({required this.state});

  final SessionPreflight state;

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    final bool cameraRequested = vm.settings.cameraEnabled;
    final bool microphoneRequested = vm.settings.microphoneEnabled;

    return AppPanel(
      title: 'Recorder',
      // A preflight is a question, and "not now" is an answer. Closing the
      // window used to be the only way to give it.
      titleBarTrailing: AppButton(
        label: 'Back',
        variant: AppButtonVariant.ghost,
        fontSize: 12,
        onPressed: vm.cancelPreflight,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const AppKicker('Before recording'),
          const SizedBox(height: 10),
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.divider),
            ),
            child: Column(
              children: <Widget>[
                _PermissionRow(
                  label: 'Screen & window recording',
                  status: state.report[PermissionKind.screenRecording],
                  last: false,
                ),
                _PermissionRow(
                  kind: PermissionKind.microphone,
                  label: 'Microphone',
                  status: state.report[PermissionKind.microphone],
                  note: _inputNote(
                    state.report[PermissionKind.microphone],
                    requested: microphoneRequested,
                    missing: 'This recording will have no microphone audio.',
                  ),
                  offerFix: true,
                  last: false,
                ),
                _PermissionRow(
                  kind: PermissionKind.camera,
                  label: 'Camera',
                  status: state.report[PermissionKind.camera],
                  note: _inputNote(
                    state.report[PermissionKind.camera],
                    requested: cameraRequested,
                    missing: 'This recording will have no camera.',
                  ),
                  offerFix: true,
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          AppButton(
            label: _startLabel(state.degradedInputs),
            icon: AppIcons.record,
            variant: AppButtonVariant.primary,
            expand: true,
            height: 38,
            busy: vm.isBusy,
            onPressed: vm.confirmPreflight,
          ),
          const SizedBox(height: 8),
          const Center(
            child: AppMonoText(
              'Screen and system audio are recorded as usual.',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  /// The button says what pressing it does. "Start recording" on a screen
  /// reached *from* a button labelled "Start recording" says nothing at all.
  static String _startLabel(Set<PermissionKind> degraded) {
    final bool microphone = degraded.contains(PermissionKind.microphone);
    final bool camera = degraded.contains(PermissionKind.camera);
    if (microphone && camera) {
      return 'Record without microphone or camera';
    }
    if (microphone) {
      return 'Record without microphone';
    }
    if (camera) {
      return 'Record without camera';
    }
    return 'Start recording';
  }

  static String? _inputNote(
    PermissionStatus status, {
    required bool requested,
    required String missing,
  }) {
    if (status.isUsable) {
      return null;
    }
    if (!requested) {
      return 'Off for this recording.';
    }
    return status == PermissionStatus.restricted
        ? 'Blocked by a policy on this computer.'
        : missing;
  }
}

/// One permission, as the design draws it: marker, name, status tag, and — for
/// an input the operating system can still be asked about — the action that
/// asks.
class _PermissionRow extends StatelessWidget {
  const _PermissionRow({
    required this.label,
    required this.status,
    required this.last,
    this.kind,
    this.note,
    this.marker,
    this.tag,
    this.tagTone,
    this.offerFix = false,
  });

  final PermissionKind? kind;
  final String label;
  final PermissionStatus status;
  final String? note;
  final Widget? marker;
  final String? tag;
  final AppTagTone? tagTone;

  /// Whether the row carries its own remedy. Only the optional inputs do: the
  /// blocking permission's remedy is the whole screen.
  final bool offerFix;

  final bool last;

  @override
  Widget build(BuildContext context) {
    final RecorderViewModel vm = AppScope.of(context).recorder;
    final bool granted = status.isUsable;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              marker ??
                  AppIcon(
                    granted ? AppIcons.check : AppIcons.close,
                    size: 16,
                    color: granted ? AppColors.accent : AppColors.neutral600,
                  ),
              const SizedBox(width: 10),
              Expanded(child: Text(label, style: AppTypography.bodySmall)),
              AppTag(
                tag ?? (granted ? 'Granted' : 'Not granted'),
                tone:
                    tagTone ??
                    (granted ? AppTagTone.accent : AppTagTone.neutral),
              ),
            ],
          ),
          if (note != null) ...<Widget>[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: AppMonoText(note!),
            ),
          ],
          if (offerFix && !granted && kind != null) ...<Widget>[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AppButton(
                  label: status == PermissionStatus.notDetermined
                      ? 'Allow…'
                      : 'Open System Settings',
                  fontSize: 12,
                  // The operating system lists an application under a privacy
                  // category only once it has asked, so an unanswered
                  // permission gets the prompt and a refused one gets the pane.
                  onPressed: status == PermissionStatus.notDetermined
                      ? () => vm.requestPermission(kind!)
                      : () => vm.openPermissionSettings(kind!),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
