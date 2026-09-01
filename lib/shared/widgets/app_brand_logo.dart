import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/assets/app_assets.dart';

enum AppBrandLogoVariant { horizontal, symbol }

class AppBrandLogo extends StatelessWidget {
  const AppBrandLogo({
    required this.variant,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.borderRadius = BorderRadius.zero,
    super.key,
  });

  final AppBrandLogoVariant variant;
  final double? width;
  final double? height;
  final BoxFit fit;
  final BorderRadius borderRadius;

  static String assetFor(AppBrandLogoVariant variant) => switch (variant) {
    AppBrandLogoVariant.horizontal => AppAssets.logoHorizontal,
    AppBrandLogoVariant.symbol => AppAssets.logoSymbol,
  };

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: 'Identidad institucional Aquafim · DDR001 Levantamientos',
    child: ClipRRect(
      borderRadius: borderRadius,
      child: Image.asset(
        assetFor(variant),
        key: ValueKey('app-brand-logo-${variant.name}'),
        width: width,
        height: height,
        fit: fit,
        excludeFromSemantics: true,
        errorBuilder: (context, error, stackTrace) {
          if (kDebugMode) {
            debugPrint('[BRANDING] No se pudo cargar el asset institucional.');
          }
          return SizedBox(width: width, height: height);
        },
      ),
    ),
  );
}
