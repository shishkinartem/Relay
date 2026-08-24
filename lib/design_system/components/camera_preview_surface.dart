import 'package:flutter/widgets.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_shadows.dart';
import '../tokens/app_typography.dart';
import 'blueprint_frame.dart';
import 'hatched_surface.dart';

/// The live camera preview window (design `1e` and `1p`).
///
/// The same logical camera source the compositor draws into the picture-in-
/// picture, shown directly — never screen-captured back out of this window,
/// which is excluded from capture.
///
/// [matchesCompositedPip] switches between the two designed presentations: in
/// display mode the preview sits exactly where the composited picture-in-
/// picture lands and carries no labels at all, so the frame over the user's
/// screen stays clean; in window mode it is a separate captioned object placed
/// where the user can see it.
///
/// In both, the feed is drawn at [aspectRatio] and letterboxed inside whatever
/// box it is given. A platform texture has no intrinsic size and would
/// otherwise be stretched to fill the window — which is what made a 16:9
/// camera look squeezed in a square preview.
class CameraPreviewSurface extends StatelessWidget {
  const CameraPreviewSurface({
    super.key,
    this.feed,
    this.mirrored = true,
    this.matchesCompositedPip = false,
    this.aspectRatio = 16 / 9,
  });

  /// The camera frames. Null renders the wireframe placeholder.
  final Widget? feed;

  /// Users expect a mirrored view of themselves; the file is not mirrored.
  final bool mirrored;

  final bool matchesCompositedPip;

  /// The camera's own width / height.
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    final Widget image = ClipRect(
      child: Transform(
        alignment: Alignment.center,
        transform: mirrored
            ? (Matrix4.identity()..scaleByDouble(-1, 1, 1, 1))
            : Matrix4.identity(),
        child: _Letterboxed(
          aspectRatio: aspectRatio,
          child: feed ?? const HatchedSurface(stripe: 5),
        ),
      ),
    );

    if (matchesCompositedPip) {
      return BlueprintFrame(
        background: AppColors.neutral400,
        child: DuotoneFilter(enabled: feed == null, child: image),
      );
    }

    return BlueprintFrame(
      background: AppColors.background,
      boxShadow: AppShadows.large,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // The window is a fixed rectangle; the feed is letterboxed inside it
          // rather than driving its height, so a camera of any shape fits
          // without overflowing the window or being stretched into it.
          Expanded(
            child: DuotoneFilter(enabled: feed == null, child: image),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.divider)),
            ),
            child: Text(
              'Camera preview',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.mono.copyWith(fontSize: 9),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws [child] at [aspectRatio], centred in the box it is given.
///
/// The camera reaches the preview as a platform texture, which fills whatever
/// box it is handed. Sizing that box from the camera's own shape is the only
/// thing standing between a live preview and a distorted one.
class _Letterboxed extends StatelessWidget {
  const _Letterboxed({required this.aspectRatio, required this.child});

  final double aspectRatio;
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: AspectRatio(
      aspectRatio: aspectRatio > 0 ? aspectRatio : 1,
      child: child,
    ),
  );
}
