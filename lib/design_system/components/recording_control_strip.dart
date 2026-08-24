import 'package:flutter/widgets.dart';

import '../../core/formatting/formatters.dart';
import '../icons/app_icons.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_shadows.dart';
import '../tokens/app_typography.dart';
import 'app_button.dart';
import 'status_dot.dart';

/// The always-on-top recording control strip (design `1f` and `1g`).
///
/// A presentation component: it renders a state and raises intents. It owns no
/// session state, so the strip in the overlay window and a strip rendered in a
/// widget test behave identically.
///
/// Accent fill means the source is contributing to the mix; a hairline frame
/// means it is off.
///
/// The strip has **one width in every state**, and it is the compact one. Its
/// host window is sized to what the strip measures, so a strip that changed
/// width on pause would resize that always-on-top window during the very click
/// that paused it and slide every remaining control out from under the cursor.
/// Design `1g` gets there by adding a `Paused` tag and a labelled `Resume`
/// button; this renders the paused state in place instead — accent frame,
/// hollow status dot, and the play glyph filled with the accent — so nothing
/// moves and the strip stays as small as `1f` draws it.
///
/// Each control's hit target also claims the 12 px gap beside it
/// ([AppIconButton.hitSlop]). The drawn squares are unchanged; a click that
/// lands between two of them now reaches the nearer one instead of nothing.
class RecordingControlStrip extends StatelessWidget {
  const RecordingControlStrip({
    super.key,
    required this.elapsed,
    required this.isPaused,
    required this.microphoneEnabled,
    required this.cameraEnabled,
    required this.systemAudioEnabled,
    this.microphoneAvailable = true,
    this.cameraAvailable = true,
    this.systemAudioAvailable = true,
    this.isStopping = false,
    this.onToggleMicrophone,
    this.onToggleCamera,
    this.onToggleSystemAudio,
    this.onPauseOrResume,
    this.onStop,
  });

  /// The gap the design puts between two controls.
  static const double gap = 12;

  /// Half that gap, claimed by each neighbouring control's hit target. Two
  /// slopped controls sit flush and still read as [gap] apart.
  static const EdgeInsets controlSlop = EdgeInsets.symmetric(
    horizontal: gap / 2,
    vertical: 7,
  );

  final Duration elapsed;
  final bool isPaused;
  final bool microphoneEnabled;
  final bool cameraEnabled;
  final bool systemAudioEnabled;
  final bool microphoneAvailable;
  final bool cameraAvailable;
  final bool systemAudioAvailable;
  final bool isStopping;

  final VoidCallback? onToggleMicrophone;
  final VoidCallback? onToggleCamera;
  final VoidCallback? onToggleSystemAudio;
  final VoidCallback? onPauseOrResume;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      // The trailing control carries half a gap of slop of its own, so the
      // right inset is halved to match; the leading status dot carries none.
      // The vertical inset is what is left of 8 once the controls grew by 7 —
      // the strip is still 48 px tall, and every control now spans its height.
      padding: const EdgeInsets.only(
        left: gap,
        right: gap / 2,
        top: 1,
        bottom: 1,
      ),
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border.all(
          color: isPaused ? AppColors.accent : AppColors.ink(28),
        ),
        boxShadow: AppShadows.medium,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          StatusDot(active: !isPaused),
          const SizedBox(width: 7),
          Text(
            formatClock(elapsed),
            style: AppTypography.mono.copyWith(
              fontSize: 13,
              color: AppColors.text,
            ),
          ),
          const _StripDivider(leading: gap, trailing: gap / 2),
          _InputToggle(
            enabledIcon: AppIcons.microphone,
            disabledIcon: AppIcons.microphoneOff,
            enabled: microphoneEnabled,
            available: microphoneAvailable,
            label: microphoneEnabled ? 'Microphone on' : 'Microphone off',
            onPressed: onToggleMicrophone,
          ),
          _InputToggle(
            enabledIcon: AppIcons.camera,
            disabledIcon: AppIcons.cameraOff,
            enabled: cameraEnabled,
            available: cameraAvailable,
            label: cameraEnabled ? 'Camera on' : 'Camera off',
            onPressed: onToggleCamera,
          ),
          _InputToggle(
            enabledIcon: AppIcons.systemAudio,
            disabledIcon: AppIcons.systemAudioOff,
            enabled: systemAudioEnabled,
            available: systemAudioAvailable,
            label: systemAudioEnabled ? 'System audio on' : 'System audio off',
            onPressed: onToggleSystemAudio,
          ),
          const _StripDivider(leading: gap / 2, trailing: gap / 2),
          // One control in one square, in both states: the glyph and the fill
          // change, the geometry does not.
          AppIconButton(
            icon: isPaused ? AppIcons.play : AppIcons.pause,
            semanticLabel: isPaused ? 'Resume' : 'Pause',
            size: 32,
            iconSize: isPaused ? 13 : 14,
            variant: isPaused
                ? AppButtonVariant.primary
                : AppButtonVariant.secondary,
            hitSlop: controlSlop,
            onPressed: isStopping ? null : onPauseOrResume,
          ),
          AppIconButton(
            icon: AppIcons.stop,
            semanticLabel: 'Stop',
            size: 32,
            iconSize: 13,
            hitSlop: controlSlop,
            onPressed: isStopping ? null : onStop,
          ),
        ],
      ),
    );
  }
}

/// The hairline between two groups of controls.
///
/// The insets are asymmetric because its neighbours are: a control claims half
/// the gap beside it as hit target, the clock claims none.
class _StripDivider extends StatelessWidget {
  const _StripDivider({required this.leading, required this.trailing});

  final double leading;
  final double trailing;

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 24,
    color: AppColors.divider,
    margin: EdgeInsets.only(left: leading, right: trailing),
  );
}

class _InputToggle extends StatelessWidget {
  const _InputToggle({
    required this.enabledIcon,
    required this.disabledIcon,
    required this.enabled,
    required this.available,
    required this.label,
    required this.onPressed,
  });

  final AppIconData enabledIcon;
  final AppIconData disabledIcon;
  final bool enabled;
  final bool available;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => AppIconButton(
    icon: enabled ? enabledIcon : disabledIcon,
    semanticLabel: available ? label : '$label — unavailable',
    size: 32,
    variant: enabled ? AppButtonVariant.primary : AppButtonVariant.secondary,
    foreground: enabled ? null : AppColors.neutral600,
    hitSlop: RecordingControlStrip.controlSlop,
    onPressed: available ? onPressed : null,
  );
}
