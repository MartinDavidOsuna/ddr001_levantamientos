import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/app_controller.dart';
import '../../domain/construction/construction_models.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>(), profile = app.profile;
    return Scaffold(
      appBar: AppBar(title: const Text('Perfil')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const CircleAvatar(radius: 44, child: Icon(Icons.person, size: 48)),
          const SizedBox(height: 12),
          Text(
            profile?.displayName ?? app.session?.name ?? '',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Text(
            profile?.role == ConstructionRole.resident
                ? 'Residente'
                : 'Contratista',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.email),
                  title: const Text('Correo'),
                  subtitle: Text(profile?.email ?? app.session?.email ?? ''),
                ),
                ListTile(
                  leading: const Icon(Icons.phone),
                  title: const Text('Teléfono'),
                  subtitle: Text(profile?.phone ?? app.session?.phone ?? ''),
                ),
                ListTile(
                  leading: const Icon(Icons.groups),
                  title: const Text('Cuadrilla'),
                  subtitle: Text(profile?.crew ?? app.session?.crew ?? ''),
                ),
                ListTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('Sincronización'),
                  subtitle: Text(
                    app.queue.isEmpty
                        ? 'Sincronizado'
                        : '${app.queue.length} elementos pendientes',
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.info),
                  title: const Text('Versión'),
                  subtitle: Text(
                    '${app.packageInfo.version}+${app.packageInfo.buildNumber} · ${app.config.environment}',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            key: const Key('logout'),
            onPressed: () async {
              if (app.queue.isNotEmpty) {
                final proceed =
                    await showDialog<bool>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Información pendiente'),
                        content: const Text(
                          'Tus levantamientos locales se conservarán, pero hay información pendiente de sincronizar. ¿Cerrar sesión?',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Cancelar'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Cerrar sesión'),
                          ),
                        ],
                      ),
                    ) ??
                    false;
                if (!proceed) return;
              }
              await app.logout();
            },
            icon: const Icon(Icons.logout),
            label: const Text('Cerrar sesión'),
          ),
        ],
      ),
    );
  }
}
