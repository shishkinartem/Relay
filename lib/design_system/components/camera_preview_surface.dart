import 'package:flutter/widgets.dart';
import 'package:recorder_platform_interface/recorder_platform_interface.dart';

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
    this.fit = CameraPipFit.contain,
    this.cornerRadiusRatio = 0,
  });

  /// The camera frames. Null renders the wireframe placeholder.
  final Widget? feed;

  /// Users expect a mirrored view of themselves; the file is not mirrored.
  final bool mirrored;

  final bool matchesCompositedPip;

  /// The camera's own width / height.
  final double aspectRatio;

  /// Whether the frame is fitted whole or centre-cropped to fill the tile
  /// (§33.5).
  ///
  /// This has to agree with the compositor to the pixel: design `1p` promises
  /// the preview *is* the picture-in-picture, and a circle on screen with a
  /// square in the file is the defect that promise exists to prevent.
  final CameraPipFit fit;

  /// Corner radius as a fraction of the tile's width. `0.5` is a circle.
  final double cornerRadiusRatio;

  @override
  Widget build(BuildContext context) {
    final Widget frame = feed ?? const HatchedSurface(stripe: 5);
    final Widget image = ClipRect(
      child: Transform(
        alignment: Alignment.center,
        transform: mirrored
            ? (Matrix4.identity()..scaleByDouble(-1, 1, 1, 1))
            : Matrix4.identity(),
        // `contain` letterboxes the whole frame; `cover` takes the centre and
        // drops the rest, which is what a square or a circle asks for and the
        // only cropping this product does (§33.5).
        child: fit == CameraPipFit.cover
            ? FittedBox(
                fit: BoxFit.cover,
                child: _Sized(aspectRatio: aspectRatio, child: frame),
              )
            : _Letterboxed(aspectRatio: aspectRatio, child: frame),
      ),
    );

    if (matchesCompositedPip) {
      // Display mode: this window *is* the composited picture-in-picture
      // (design `1p`, §33.5), so it draws exactly what the compositor draws and
      // nothing else — no frame, no registration marks, no ground behind the
      // camera. The compositor writes the camera's pixels into the tile and
      // leaves everything outside it untouched; anything this window adds is a
      // mark on the user's screen that is absent from the file, which is the
      // one disagreement `1p` exists to forbid. It is also why the window
      // itself carries no background (`RelayTheme(ground: null)`).
      //
      // `SizedBox.expand` rather than trusting the constraints that arrive: a
      // `cover` fit sizes itself to its child when its minimums are zero, and
      // its child is the camera's aspect ratio measured in *logical pixels*.
      // Any parent that loosens — a `Stack`, an `Align`, anything that
      // shrink-wraps — collapsed the tile to under two pixels in the corner of
      // an otherwise empty window. That is what the square preset drew.
      final Widget tile = SizedBox.expand(
        child: DuotoneFilter(enabled: feed == null, child: image),
      );
      if (cornerRadiusRatio <= 0) {
        return tile;
      }
      // The mask is the shape the compositor draws, resolved against the tile's
      // own width so the circle is a circle at every canvas size.
      return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) =>
            ClipRRect(
              borderRadius: BorderRadius.circular(
                cornerRadiusRatio * constraints.maxWidth,
              ),
              child: tile,
            ),
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

/// The frame at its own shape, for a `cover` fit to crop.
///
/// `FittedBox` needs an intrinsic size to scale, and a platform texture has
/// none — it takes whatever it is given, which is how the camera came to be
/// stretched before `1p` was written down.
class _Sized extends StatelessWidget {
  const _Sized({required this.aspectRatio, required this.child});

  final double aspectRatio;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: aspectRatio <= 0 ? 1 : aspectRatio,
    height: 1,
    child: child,
  );
}
