import 'dart:async';

import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_shadows.dart';
import '../tokens/app_typography.dart';

/// A hairline tooltip on the system's tokens.
///
/// The design does not draw a tooltip, so this is the minimum structurally
/// consistent surface: square, transparent-free, hairline-bordered, `.mono`
/// text. It exists because the control strip is icon-only and its controls
/// need names (`docs/development/design-system.md` → component API
/// expectations).
class AppTooltip extends StatefulWidget {
  const AppTooltip({
    super.key,
    required this.message,
    required this.child,
    this.waitDuration = const Duration(milliseconds: 450),
    this.verticalOffset = 30,
  });

  final String message;
  final Widget child;
  final Duration waitDuration;
  final double verticalOffset;

  @override
  State<AppTooltip> createState() => _AppTooltipState();
}

class _AppTooltipState extends State<AppTooltip> {
  final LayerLink _link = LayerLink();
  OverlayEntry? _entry;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _remove();
    super.dispose();
  }

  void _scheduleShow() {
    _timer?.cancel();
    _timer = Timer(widget.waitDuration, _show);
  }

  void _show() {
    if (_entry != null || !mounted || widget.message.isEmpty) {
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context);
    if (overlay == null) {
      return;
    }
    _entry = OverlayEntry(
      builder: (BuildContext context) => Positioned(
        child: CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomCenter,
          followerAnchor: Alignment.topCenter,
          offset: Offset(0, widget.verticalOffset - 24),
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.background,
                border: Border.all(color: AppColors.divider),
                boxShadow: AppShadows.small,
              ),
              child: Text(
                widget.message,
                style: AppTypography.mono.copyWith(color: AppColors.text),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_entry!);
  }

  void _remove() {
    _entry?.remove();
    _entry = null;
  }

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
    link: _link,
    child: MouseRegion(
      onEnter: (_) => _scheduleShow(),
      onExit: (_) {
        _timer?.cancel();
        _remove();
      },
      child: widget.child,
    ),
  );
}
