import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/app_controller.dart';
import '../../domain/construction/construction_models.dart';
import '../surveys/new_survey_page.dart';
import '../resident/resident_review_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, this.onSurveysTap});
  final VoidCallback? onSurveysTap;
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>(),
        resident = app.profile?.role == ConstructionRole.resident;
    return Scaffold(
      appBar: AppBar(title: const Text('DDR001 Levantamientos')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Hola, ${app.profile?.displayName ?? app.session?.name ?? ''}',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(resident ? 'Residente' : 'Contratista'),
          const SizedBox(height: 24),
          if (!resident) ...[
            _ActionCard(
              key: const Key('new_survey_action'),
              icon: Icons.add_location_alt,
              title: 'INICIAR NUEVO LEVANTAMIENTO',
              subtitle: 'Documenta una base incluso sin conexión',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NewSurveyPage()),
              ),
            ),
            const SizedBox(height: 12),
            _ActionCard(
              key: const Key('my_surveys_action'),
              icon: Icons.list_alt,
              title: 'MIS LEVANTAMIENTOS',
              subtitle: '${app.surveys.length} guardados en este dispositivo',
              onTap: onSurveysTap ?? () {},
            ),
          ] else ...[
            _ActionCard(
              icon: Icons.add_business,
              title: 'REGISTRAR INSTALACIÓN',
              subtitle: 'Próximamente',
              onTap: () => ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Próximamente'))),
            ),
            const SizedBox(height: 12),
            _ActionCard(
              key: const Key('resident_review_action'),
              icon: Icons.fact_check,
              title: 'REVISIÓN DE BASE',
              subtitle: 'Revisa, acepta o rechaza levantamientos ejecutados',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ResidentReviewPage()),
              ),
            ),
          ],
          const SizedBox(height: 20),
          Card(
            child: ListTile(
              leading: Icon(app.online ? Icons.cloud_done : Icons.cloud_off),
              title: Text(
                app.syncing
                    ? 'Sincronizando'
                    : app.online
                    ? app.queue.isEmpty
                          ? 'Sincronizado'
                          : 'Información pendiente'
                    : 'Sin conexión',
              ),
              subtitle: Text('${app.queue.length} operaciones pendientes'),
              trailing: IconButton(
                onPressed: app.online ? app.synchronize : null,
                icon: const Icon(Icons.sync),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            CircleAvatar(radius: 28, child: Icon(icon)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(subtitle),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    ),
  );
}
