import 'dart:ui' show FlutterView;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../../design_system/design_system.dart';

/// The always-on-top control strip, rendered in its own Flutter engine
/// (design `1f`, `1g`).
///
/// It receives a [RecordingOverlayState] and sends back [OverlayCommand]s. No
/// recording state lives here, so the strip cannot drift out of step with the
/// session, and the same component renders identically in a widget test.
class ControlStripWindow extends StatefulWidget {
  const ControlStripWindow({super.key, this.client});

  final OverlayViewClient? client;

  @override
  State<ControlStripWindow> createState() => _ControlStripWindowState();
}

class _ControlStripWindowState extends State<ControlStripWindow>
    with WidgetsBindingObserver {
  late final OverlayViewClient _client = widget.client ?? OverlayViewClient();
  final GlobalKey _stripKey = GlobalKey();
  RecordingOverlayState _state = const RecordingOverlayState();
  Size? _reportedSize;
  Size? _reportedForWindow;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client.controlStripStates.listen((RecordingOverlayState state) {
      if (mounted) {
        setState(() => _state = state);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback(_reportSize);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.client == null) {
      _client.dispose();
    }
    super.dispose();
  }

  /// The host resized the window. Nothing in this tree depends on that size, so
  /// without this the strip would never notice that the window stopped fitting
  /// it — which is exactly what happens when a second session re-applies the
  /// placement's requested size.
  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback(_reportSize);
  }

  /// The host window is sized to the strip's intrinsic size, so the strip is
  /// never clipped and never surrounded by dead space.
  ///
  /// The measurement is repeated whenever the *window* stops matching it, not
  /// only when the strip's own size changes. This engine outlives a session,
  /// and showing the strip again re-applies the host's requested placement
  /// size: with a size-only guard the strip would have nothing new to report,
  /// the window would stay at that request — narrower than the strip — and the
  /// trailing controls would render outside it, where a click never lands.
  void _reportSize(Duration _) {
    final RenderObject? render = _stripKey.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.hasSize) {
      return;
    }
    final Size size = render.size;
    final Size? window = _windowSize();
    if (_reportedSize == size && _reportedForWindow == window) {
      return;
    }
    _reportedSize = size;
    _reportedForWindow = window;
    _client.reportContentSize(size.width, size.height);
  }

  /// The host window's logical size, or null before this engine has a view.
  Size? _windowSize() {
    if (!mounted) {
      return null;
    }
    final FlutterView? view = View.maybeOf(context);
    if (view == null || view.devicePixelRatio <= 0) {
      return null;
    }
    return view.physicalSize / view.devicePixelRatio;
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback(_reportSize);
    return RelayTheme(
      // No ground. The strip paints its own frame, and its window is never
      // shrunk (see `OverlayWindows.apply`), so any surplus has to be the
      // user's screen rather than a pale rectangle beside the strip.
      ground: null,
      child: _NudgeShortcuts(
        onNudge: _client.send,
        child: Align(
          alignment: Alignment.topLeft,
          // The host window is sized from what `_reportSize` measures, so the
          // strip must be measured at its *natural* width, not at the width of
          // the window it is already in. Without this the two clamp each other:
          // pausing widens the strip (a `Paused` tag and a labelled `Resume`
          // button replace the pause icon), the measurement comes back clipped to
          // the window that is already too small, no resize is ever requested,
          // and Resume and Stop end up outside the window — the recording can no
          // longer be paused or stopped from the strip.
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: 0,
            maxWidth: double.infinity,
            minHeight: 0,
            maxHeight: double.infinity,
            child: RecordingControlStrip(
              key: _stripKey,
              elapsed: _state.elapsed,
              isPaused: _state.isPaused,
              microphoneEnabled: _state.microphoneEnabled,
              cameraEnabled: _state.cameraEnabled,
              systemAudioEnabled: _state.systemAudioEnabled,
              microphoneAvailable: _state.microphoneAvailable,
              cameraAvailable: _state.cameraAvailable,
              systemAudioAvailable: _state.systemAudioAvailable,
              isStopping: _state.isStopping,
              // The gesture reaches the host as one call and the operating
              // system's own drag loop takes it from there (§33.3).
              onMoveRequested: _client.beginMove,
              // A caret is drawn only for an input this platform lets the user
              // choose between. The snapshot carries that, so the strip never has
              // to ask which operating system it is on (§28, §33.4).
              onOpenMicrophoneMenu: _state.microphoneHasMenu
                  ? (double x) => _client.send(
                      OverlayCommand.openMicrophoneMenu,
                      anchorX: x,
                    )
                  : null,
              onOpenCameraMenu: _state.cameraHasMenu
                  ? (double x) =>
                        _client.send(OverlayCommand.openCameraMenu, anchorX: x)
                  : null,
              onOpenSystemAudioMenu: _state.systemAudioHasMenu
                  ? (double x) => _client.send(
                      OverlayCommand.openSystemAudioMenu,
                      anchorX: x,
                    )
                  : null,
              onToggleMicrophone: () =>
                  _client.send(OverlayCommand.toggleMicrophone),
              onToggleCamera: () => _client.send(OverlayCommand.toggleCamera),
              onToggleSystemAudio: () =>
                  _client.send(OverlayCommand.toggleSystemAudio),
              onPauseOrResume: () => _client.send(OverlayCommand.pauseOrResume),
              onStop: () => _client.send(OverlayCommand.stop),
            ),
          ),
        ),
      ),
    );
  }
}

/// The arrow keys, the keyboard's half of §33.3.
///
/// The drag is a sustained pointer gesture on a small window that is
/// deliberately hard to hit by accident; this is the path for anyone that gesture
/// does not serve. The host clamps and snaps a nudge exactly as it does the end
/// of a drag, so the two cannot disagree about where the strip may sit.
///
/// It only fires while this window holds key focus. That is a real limit — the
/// strip is a non-activating panel, so it is focused after it is clicked, not
/// while the recorded application is in front.
class _NudgeShortcuts extends StatelessWidget {
  const _NudgeShortcuts({required this.onNudge, required this.child});

  final void Function(OverlayCommand command) onNudge;
  final Widget child;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const <ShortcutActivator, Intent>{
      SingleActivator(LogicalKeyboardKey.arrowLeft): _NudgeIntent(
        OverlayCommand.nudgeStripLeft,
      ),
      SingleActivator(LogicalKeyboardKey.arrowRight): _NudgeIntent(
        OverlayCommand.nudgeStripRight,
      ),
      SingleActivator(LogicalKeyboardKey.arrowUp): _NudgeIntent(
        OverlayCommand.nudgeStripUp,
      ),
      SingleActivator(LogicalKeyboardKey.arrowDown): _NudgeIntent(
        OverlayCommand.nudgeStripDown,
      ),
      SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): _NudgeIntent(
        OverlayCommand.nudgeStripLeftFar,
      ),
      SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): _NudgeIntent(
        OverlayCommand.nudgeStripRightFar,
      ),
      SingleActivator(LogicalKeyboardKey.arrowUp, shift: true): _NudgeIntent(
        OverlayCommand.nudgeStripUpFar,
      ),
      SingleActivator(LogicalKeyboardKey.arrowDown, shift: true): _NudgeIntent(
        OverlayCommand.nudgeStripDownFar,
      ),
    },
    child: Actions(
      actions: <Type, Action<Intent>>{
        _NudgeIntent: CallbackAction<_NudgeIntent>(
          onInvoke: (_NudgeIntent intent) {
            onNudge(intent.command);
            return null;
          },
        ),
      },
      // The strip's own controls are the focusable things in this window; this
      // holds focus when none of them does, so an arrow key works whether or
      // not the user has tabbed into a button.
      child: Focus(autofocus: true, child: child),
    ),
  );
}

class _NudgeIntent extends Intent {
  const _NudgeIntent(this.command);

  final OverlayCommand command;
}
