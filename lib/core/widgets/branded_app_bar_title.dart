import 'package:flutter/material.dart';

import '../assets/app_assets.dart';

class BrandedAppBarTitle extends StatelessWidget {
  const BrandedAppBarTitle(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Image.asset(
        AppAssets.logoSymbol,
        width: 30,
        height: 30,
        fit: BoxFit.contain,
        semanticLabel: 'DDR001',
      ),
      const SizedBox(width: 9),
      Flexible(
        child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ],
  );
}
