import 'package:flutter/widgets.dart';

import 'app_colors.dart';

/// Elevation tokens — soft ink-tinted shadows on the light ground.
abstract final class AppShadows {
  static List<BoxShadow> get small => <BoxShadow>[
    BoxShadow(
      color: AppColors.neutral900.withValues(alpha: 0.14),
      offset: const Offset(0, 1),
      blurRadius: 2,
    ),
  ];

  static List<BoxShadow> get medium => <BoxShadow>[
    BoxShadow(
      color: AppColors.neutral900.withValues(alpha: 0.16),
      offset: const Offset(0, 3),
      blurRadius: 10,
    ),
  ];

  static List<BoxShadow> get large => <BoxShadow>[
    BoxShadow(
      color: AppColors.neutral900.withValues(alpha: 0.22),
      offset: const Offset(0, 12),
      blurRadius: 32,
    ),
  ];
}
