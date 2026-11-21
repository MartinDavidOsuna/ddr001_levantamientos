import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'recovery/cabinet_backup.dart';

// No imports of productive bootstrap, controllers, sessions, GPS or HTTP clients.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: CabinetRecoveryPage()));
}

class CabinetRecoveryPage extends StatefulWidget {
  const CabinetRecoveryPage({super.key});
  @override
  State<CabinetRecoveryPage> createState() => _CabinetRecoveryPageState();
}

class _CabinetRecoveryPageState extends State<CabinetRecoveryPage> {
  static const channel = MethodChannel('ddr/cabinet_recovery');
  bool busy = false;
  String status =
      'Este modo sólo prepara un respaldo privado de Gabinetes. '
      'No inicia sincronización, cámara, GPS ni migraciones. '
      'El respaldo contiene fotografías y trabajo de campo: consérvalo en una ubicación local privada.';
  String? directory;
  Future<void> export() async {
    final agreed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmar respaldo diagnóstico'),
        content: const Text(
          'Se leerán los expedientes de Gabinetes y sus archivos. '
          'No se enviará información al servidor. ¿Autorizar esta copia privada?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Crear respaldo'),
          ),
        ],
      ),
    );
    if (agreed != true || !mounted) return;
    setState(() {
      busy = true;
      directory = null;
    });
    try {
      final roots = map(await channel.invokeMethod('exclusiveRoots'));
      if (roots['exclusive'] != true) {
        throw StateError('Exclusión no confirmada.');
      }
      final destination = Directory(
        '${roots['cache']}/cabinet_recovery/${DateTime.now().microsecondsSinceEpoch}',
      );
      final manifest = await CabinetBackup(
        root: Directory(roots['root'] as String),
        destination: destination,
        assertExclusive: () async {
          final current = map(await channel.invokeMethod('exclusiveRoots'));
          if (current['exclusive'] != true ||
              current['root'] != roots['root']) {
            throw StateError('Proceso no exclusivo.');
          }
        },
      ).create();
      await File('${destination.path}/inventory.json').writeAsString(
        jsonEncode({
          'complete': manifest['complete'],
          'issues': manifest['issues'],
          'inventory': manifest['inventory'],
        }),
        flush: true,
      );
      if (!mounted) return;
      setState(() {
        directory = destination.path;
        status =
            '${manifest['complete'] == true ? "Respaldo completo" : "Respaldo PARCIAL: faltan referencias u originales"}. '
            '${manifest['dossiers']} expedientes. Hashes verificados. '
            'Elige un destino local para conservarlo. El inventario también es privado. '
            'No se activará sincronización al terminar.';
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => status =
              'Exportación bloqueada: exclusión, formato, integridad o contenido no seguro. '
              'Originales sin modificar. No hay respaldo certificado.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> save(String name) async {
    setState(() => busy = true);
    try {
      final saved = await channel.invokeMethod<bool>('save', {
        'path': '$directory/$name',
      });
      if (mounted) {
        setState(
          () => status = saved == true
              ? 'Archivo guardado y hash verificado en el destino local. No se inicia sincronización.'
              : 'Selección cancelada; copia privada conservada.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => status =
              'No se pudo verificar el destino. Copia privada conservada.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Respaldo privado de Gabinetes')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: ListView(
        children: [
          Text(status),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : export,
            child: const Text('Preparar respaldo'),
          ),
          if (busy) const LinearProgressIndicator(),
          if (directory != null) ...[
            OutlinedButton(
              onPressed: busy ? null : () => save('backup.ddr.jsonl'),
              child: const Text('Guardar respaldo privado'),
            ),
            OutlinedButton(
              onPressed: busy ? null : () => save('inventory.json'),
              child: const Text('Guardar inventario técnico'),
            ),
          ],
        ],
      ),
    ),
  );
}
