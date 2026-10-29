import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../domain/construction/construction_models.dart';

class SurveyCoordinatesCard extends StatelessWidget {
  const SurveyCoordinatesCard({super.key, required this.location});

  final GeoPoint? location;

  Future<void> _openMaps(BuildContext context, GeoPoint point) async {
    final url = Uri.https('www.google.com', '/maps/search/', {
      'api': '1',
      'query': '${point.latitude},${point.longitude}',
    });
    try {
      if (await launchUrl(url, mode: LaunchMode.externalApplication)) return;
    } catch (_) {
      // Keep the detail usable when Android/iOS cannot open the map.
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No fue posible abrir Google Maps.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final point = location;
    return Card(
      child: ListTile(
        key: const Key('survey_coordinates'),
        leading: const Icon(Icons.location_on_outlined),
        title: const Text('Coordenadas del levantamiento'),
        subtitle: point == null
            ? const Text('Sin coordenadas registradas')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Latitud: ${point.latitude.toStringAsFixed(6)}\n'
                    'Longitud: ${point.longitude.toStringAsFixed(6)}',
                  ),
                  Text(
                    'Abrir en Google Maps',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
        trailing: point == null ? null : const Icon(Icons.open_in_new),
        onTap: point == null ? null : () => _openMaps(context, point),
      ),
    );
  }
}
