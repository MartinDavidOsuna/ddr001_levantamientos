import 'package:flutter/material.dart';

class MapStatusLegend extends StatefulWidget {
  const MapStatusLegend({super.key});

  @override
  State<MapStatusLegend> createState() => _MapStatusLegendState();
}

class _MapStatusLegendState extends State<MapStatusLegend> {
  bool expanded = true;
  static const entries = <(String, Color)>[
    ('En proceso', Color(0xff2878b5)),
    ('Ejecutado', Color(0xffe07a1f)),
    ('Rechazado', Color(0xffc93434)),
    ('Aceptado / Entregable', Color(0xff5b4bb7)),
    ('Entregado', Color(0xff238653)),
  ];

  @override
  Widget build(BuildContext context) => Material(
    key: const Key('map_status_legend'),
    elevation: 4,
    color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.94),
    borderRadius: BorderRadius.circular(10),
    child: expanded
        ? ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Estados',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      IconButton(
                        key: const Key('collapse_map_legend'),
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Ocultar leyenda',
                        onPressed: () => setState(() => expanded = false),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                  ...entries.map(
                    (entry) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, size: 12, color: entry.$2),
                          const SizedBox(width: 6),
                          Flexible(child: Text(entry.$1)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
        : TextButton.icon(
            key: const Key('expand_map_legend'),
            onPressed: () => setState(() => expanded = true),
            icon: const Icon(Icons.info_outline, size: 18),
            label: const Text('Estados'),
          ),
  );
}
