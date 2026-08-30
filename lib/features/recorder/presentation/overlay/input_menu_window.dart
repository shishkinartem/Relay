import 'dart:ui' show FlutterView;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../../design_system/design_system.dart';

/// The device list a chevron opens, in its own Flutter engine (§33.4).
///
/// It renders a snapshot pushed by the application engine and sends back one
/// choice. No device state lives here, so the list cannot drift out of step
/// with the session that feeds it — the same rule the strip and the preview
/// follow.
///
/// Its window is non-activating: opening it must not take key focus from the
/// application being recorded. Esc is therefore handled only while this window
/// does have focus, and the host closes the menu on a click outside — which is
/// the path that actually fires.
class InputMenuWindow extends StatefulWidget {
  const InputMenuWindow({super.key, this.client});

  final OverlayViewClient? client;

  @override
  State<InputMenuWindow> createState() => _InputMenuWindowState();
}

class _InputMenuWindowState extends State<InputMenuWindow>
    with WidgetsBindingObserver {
  late final OverlayViewClient _client = widget.client ?? OverlayViewClient();
  final GlobalKey _menuKey = GlobalKey();
  InputMenuOverlayState _state = const InputMenuOverlayState(
    kind: MediaDeviceKind.microphone,
    title: '',
    loading: true,
  );
  Size? _reportedSize;
  Size? _reportedForWindow;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client.inputMenuStates.listen((InputMenuOverlayState state) {
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

  /// The host sized the window from an estimate; this is the correction.
  @override
  void didChangeMetrics() {
    WidgetsBinding.instance.addPostFrameCallback(_reportSize);
  }

  /// Reports the menu's intrinsic size so the window fits it exactly.
  ///
  /// The same measurement the control strip makes, for the same reason: the
  /// application can only guess a device list's height — it does not know the
  /// text metrics — and a window that is too short clips the last row, which is
  /// usually `Off`.
  void _reportSize(Duration _) {
    final RenderObject? render = _menuKey.currentContext?.findRenderObject();
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
      // No ground. The window is never shrunk — a panel driven back to a size it
      // has already rendered can be handed a surface of the wrong size and
      // crash the raster thread — so a short sheet leaves surplus below it. The
      // sheet paints its own box; everything around it is the user's screen.
      ground: null,
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                _client.dismissInputMenu();
                return null;
              },
            ),
          },
          // A press in that surplus dismisses. An invisible region that
          // silently ate clicks would be worse than the resize it replaced:
          // this window floats over whatever the user is recording.
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) => _client.dismissInputMenu(),
            child: Align(
              alignment: Alignment.topLeft,
              // Measured at its natural size, not at the window's: the window is
              // sized from what this reports, and measuring inside it would let
              // the two clamp each other at the host's first estimate.
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: 0,
                maxWidth: double.infinity,
                minHeight: 0,
                maxHeight: double.infinity,
                // Absorbs its own presses so the dismissal above never sees a
                // click that landed on the sheet.
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (_) {},
                  child: InputMenuSheet(
                    key: _menuKey,
                    state: _state,
                    onChoose: (InputMenuItem item) => _client.chooseInputDevice(
                      _state.kind,
                      deviceId: item.id,
                      // The `Off` row is the one entry with neither an id nor a
                      // device behind it; the application turns it into the same
                      // toggle the strip's own button raises.
                      off: item.id == null && item.label.endsWith('off'),
                    ),
                    onChoosePreset: (CameraPipPreset preset) =>
                        _client.chooseCameraPreset(_state.kind, preset),
                    onChooseCorner: (CameraOverlayCorner corner) =>
                        _client.chooseCameraCorner(_state.kind, corner),
                    onResetPosition: () =>
                        _client.resetCameraPipPosition(_state.kind),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
