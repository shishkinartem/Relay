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
  Widget build(BuildContext context) => RelayTheme(
    child: CameraPreviewSurface(
      mirrored: _state.mirrored,
      matchesCompositedPip: _state.matchesCompositedPip,
      aspectRatio: _state.aspectRatio,
      feed: _state.textureId == null
          ? null
          : Texture(textureId: _state.textureId!),
    ),
  );
}
