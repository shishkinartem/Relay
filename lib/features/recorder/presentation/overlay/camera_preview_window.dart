import 'package:flutter/widgets.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

import '../../../../design_system/design_system.dart';

/// The always-on-top camera preview, rendered in its own Flutter engine
/// (design `1e`, `1p`).
///
/// The frames arrive through a platform texture registered against this
/// engine, so the camera reaches the screen without ever being screen-captured
/// back out of this window — which is itself excluded from capture.
class CameraPreviewWindow extends StatefulWidget {
  const CameraPreviewWindow({super.key, this.client});

  final OverlayViewClient? client;

  @override
  State<CameraPreviewWindow> createState() => _CameraPreviewWindowState();
}

class _CameraPreviewWindowState extends State<CameraPreviewWindow> {
  late final OverlayViewClient _client = widget.client ?? OverlayViewClient();
  CameraPreviewOverlayState _state = const CameraPreviewOverlayState();

  @override
  void initState() {
    super.initState();
    _client.cameraPreviewStates.listen((CameraPreviewOverlayState state) {
      if (mounted) {
        setState(() => _state = state);
      }
    });
  }

  @override
  void dispose() {
    if (widget.client == null) {
      _client.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget surface = CameraPreviewSurface(
      mirrored: _state.mirrored,
      matchesCompositedPip: _state.matchesCompositedPip,
      aspectRatio: _state.aspectRatio,
      fit: _state.fit,
      cornerRadiusRatio: _state.cornerRadiusRatio,
      pipAspectRatio: _state.pipAspectRatio,
      feed: _state.textureId == null
          ? null
          : Texture(textureId: _state.textureId!),
    );
    if (!_state.matchesCompositedPip) {
      // Window mode: the preview is a captioned object placed where the user
      // can see it, deliberately *not* where the tile lands (design `1e`).
      // Dragging it would move a thing that is not the picture-in-picture, so
      // it does not drag at all (§33.5). It keeps its ground because it is a
      // panel in its own right rather than a stand-in for something in the file.
      return RelayTheme(child: surface);
    }
    // Display mode: no ground. This window is the composited tile, and the
    // compositor leaves everything outside the tile untouched — so a ground
    // here paints a square over the user's screen around a circular tile.
    return RelayTheme(
      ground: null,
      child: _Draggable(onMove: _client.beginMove, child: surface),
    );
  }
}

/// Display mode: the preview *is* the tile, so dragging it moves the
/// picture-in-picture (design `1p`, §33.5).
///
/// The same threshold and the same handoff as the control strip: past 4 px the
/// host takes the gesture and the operating system's own window-drag loop runs
/// it. Where the tile ends up comes back through `cameraPreviewPosition`.
class _Draggable extends StatefulWidget {
  const _Draggable({required this.onMove, required this.child});

  final Future<void> Function() onMove;
  final Widget child;

  @override
  State<_Draggable> createState() => _DraggableState();
}

class _DraggableState extends State<_Draggable> {
  Offset? _origin;
  bool _requested = false;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: (PointerDownEvent event) {
      _origin = event.position;
      _requested = false;
    },
    onPointerMove: (PointerMoveEvent event) {
      final Offset? origin = _origin;
      if (_requested || origin == null) {
        return;
      }
      if ((event.position - origin).distance <
          RecordingControlStrip.moveThreshold) {
        return;
      }
      _requested = true;
      widget.onMove();
    },
    onPointerUp: (_) => _origin = null,
    onPointerCancel: (_) => _origin = null,
    child: MouseRegion(cursor: SystemMouseCursors.grab, child: widget.child),
  );
}
