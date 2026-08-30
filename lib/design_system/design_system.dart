/// The project design system.
///
/// Every visual value in the application comes from here. Feature widgets
/// compose these components and never re-declare a colour, a type style, a
/// spacing step or a radius (`docs/development/design-system.md`).
///
/// Layering: tokens → primitives → composites → feature widgets → screens.
/// Nothing in this library imports a feature, and no shared component owns
/// recorder or upload orchestration.
library;

export 'components/app_button.dart';
export 'components/app_dialog.dart';
export 'components/app_disclosure.dart';
export 'components/app_panel.dart';
export 'components/app_progress_bar.dart';
export 'components/app_radio.dart';
export 'components/app_segmented_control.dart';
export 'components/app_select.dart';
export 'components/app_table.dart';
export 'components/app_tag.dart';
export 'components/app_text.dart';
export 'components/app_text_field.dart';
export 'components/app_tooltip.dart';
export 'components/blueprint_frame.dart';
export 'components/camera_preview_surface.dart';
export 'components/destination_card.dart';
export 'components/hatched_surface.dart';
export 'components/level_meter.dart';
export 'components/recording_control_strip.dart';
export 'components/source_card.dart';
export 'components/status_dot.dart';
export 'icons/app_icon.dart';
export 'icons/app_icons.dart';
export 'theme/relay_theme.dart';
export 'tokens/app_colors.dart';
export 'tokens/app_shadows.dart';
export 'tokens/app_spacing.dart';
export 'tokens/app_typography.dart';
