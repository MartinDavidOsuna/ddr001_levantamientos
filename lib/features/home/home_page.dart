import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/app_controller.dart';
import '../../core/widgets/branded_app_bar_title.dart';
import '../../domain/construction/construction_models.dart';
import '../surveys/new_survey_page.dart';
import '../resident/resident_review_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key, this.onSurveysTap});
  final VoidCallback? onSurveysTap;
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>(),
        reviewer = app.profile?.role.isReviewer ?? false;
    return Scaffold(
      appBar: AppBar(title: const BrandedAppBarTitle('DDR001 Levantamientos')),
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
          Text(app.profile?.role.displayLabel ?? 'Contratista'),
          const SizedBox(height: 24),
          if (!reviewer) ...[
            _ActionCard(
              key: const Key('new_survey_action'),
              icon: Icons.add_location_alt,
              title: 'INICIAR NUEVO LEVANTAMIENTO',
              subtitle: 'Documenta una base nueva',
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
              subtitle: '${app.visibleSurveys.length} levantamientos propios',
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
          if (app.unownedPendingCount > 0 && !reviewer)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.warning_amber),
                title: const Text('Pendientes legacy protegidos'),
                subtitle: Text(
                  '${app.unownedPendingCount} operaciones se conservaron sin enviar porque su propietario no está identificado.',
                ),
              ),
            ),
          Card(
            child: ListTile(
              leading: _SyncStatusIcon(
                syncing: app.syncing,
                online: app.online,
              ),
              title: Text(
                app.syncing
                    ? 'Sincronizando'
                    : app.online
                    ? app.visibleQueue.isEmpty
                          ? 'Sincronizado'
                          : 'Información pendiente'
                    : 'Sin conexión',
              ),
              subtitle: Text(
                '${app.visibleQueue.length} operaciones pendientes',
              ),
              trailing: IconButton(
                tooltip: 'Intentar sincronizar',
                onPressed: app.session != null && !app.syncing
                    ? () => app.synchronize(force: true)
                    : null,
                icon: const Icon(Icons.sync),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SyncStatusIcon extends StatefulWidget {
  const _SyncStatusIcon({required this.syncing, required this.online});

  final bool syncing;
  final bool online;

  @override
  State<_SyncStatusIcon> createState() => _SyncStatusIconState();
}

class _SyncStatusIconState extends State<_SyncStatusIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.syncing) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _SyncStatusIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.syncing && !oldWidget.syncing) {
      _controller.repeat();
    } else if (!widget.syncing && oldWidget.syncing) {
      _controller
        ..stop()
        ..reset();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.syncing) {
      return Icon(widget.online ? Icons.cloud_done : Icons.cloud_off);
    }
    return SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Positioned(bottom: 2, child: Icon(Icons.cloud, size: 30)),
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Transform.translate(
              offset: Offset(0, 7 - (_controller.value * 12)),
              child: child,
            ),
            child: Icon(
              Icons.arrow_upward,
              size: 17,
              color: Theme.of(context).colorScheme.onPrimary,
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
