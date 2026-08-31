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
      return RelayTheme(child: _placed(surface));
    }
    // Display mode: no ground, and nothing painted outside the tile. This
    // window carries the composited tile, and the compositor leaves every pixel
    // around it untouched — so a ground here paints a square over the user's
    // screen around a circular tile.
    return RelayTheme(
      ground: null,
      child: _placed(_Draggable(onMove: _client.beginMove, child: surface)),
    );
  }

  /// Puts [child] where the host says the picture goes inside this window.
  ///
  /// The window can be larger than the picture — on macOS in display mode it
  /// always is, because a panel sized to the tile would be driven through
  /// `Camera → Square → Camera` and a hosted Flutter view handed a surface of
  /// the wrong size crashes its raster thread (flutter/flutter#185394). The
  /// surplus is left empty and untouched: nothing is painted in it, and nothing
  /// in it takes a press, so it is neither visible over the user's screen nor a
  /// drag handle for a tile that is not there.
  ///
  /// A host that sends no rectangle means its window *is* the picture, which is
  /// the case in window mode on both platforms and everywhere on Windows.
  Widget _placed(Widget child) {
    final Rect? content = _state.content;
    if (content == null) {
      return child;
    }
    return Stack(
      children: <Widget>[
        Positioned(
          left: content.left,
          top: content.top,
          width: content.width,
          height: content.height,
          child: child,
        ),
      ],
    );
  }
}

/// Display mode: the preview *is* the tile, so dragging it moves the
/// picture-in-picture (design `1p`, §33.5).
///
/// The same threshold and the same handoff as the control strip: past 4 px the
/// host takes the gesture and the operating system's own window-drag loop runs
/// it. Where the tile ends up is reported on the events channel as a
/// `cameraPreviewMoved`.
///
/// Mounted **inside the tile's rectangle**, never around the whole window: the
/// window is larger than the tile, and a press in the transparent surplus is a
/// press on the user's own screen — not a request to drag a picture that is not
/// under the pointer.
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
    // See the strip's handle: the latch clears with the gesture.
    onPointerUp: (_) {
      _origin = null;
      _requested = false;
    },
    onPointerCancel: (_) {
      _origin = null;
      _requested = false;
    },
    child: MouseRegion(cursor: SystemMouseCursors.grab, child: widget.child),
  );
}
