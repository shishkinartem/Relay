import 'dart:ui' show FlutterView;

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
    );
  }
}
