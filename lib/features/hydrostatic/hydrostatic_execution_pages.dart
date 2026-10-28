import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';
import '../../domain/cabinets/cabinet_models.dart';
import 'hydrostatic_controller.dart';
import 'hydrostatic_pages.dart';
import 'hydrostatic_result_pages.dart';

Future<void> hydroAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  final controller = context.read<HydrostaticController>();
  final identity = controller.identity;
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.identity == identity
                ? '$e'
                : 'La sesión cambió. Los datos se conservan.',
          ),
        ),
      );
    }
  }
}

class HydrostaticEvidencePanel extends StatelessWidget {
  const HydrostaticEvidencePanel({
    super.key,
    required this.id,
    required this.role,
    this.readOnly = false,
  });
  final String id;
  final HydrostaticEvidenceRole role;
  final bool readOnly;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<HydrostaticController>(), t = c.document(id);
    final photos = t.evidence.where((e) => e.role == role).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (c.pendingCaptures(id) > 0)
          Text(
            '${c.pendingCaptures(id)} captura(s) pendientes de recuperación. Los archivos se conservan; no cuentan como evidencia válida.',
          ),
        Text(switch (role) {
          HydrostaticEvidenceRole.initialSetup => 'FOTOGRAFÍA INICIAL',
          HydrostaticEvidenceRole.manometer5Bar => 'FOTOGRAFÍA A 5 BAR',
          HydrostaticEvidenceRole.final4Bar => 'FOTOGRAFÍA FINAL A 4 BAR',
          HydrostaticEvidenceRole.leakEvidence => 'FOTOGRAFÍAS DE FUGA',
        }, style: Theme.of(context).textTheme.titleMedium),
        Text(switch (role) {
          HydrostaticEvidenceRole.initialSetup =>
            'Toma una fotografía donde se vea el gabinete completo conectado al banco de pruebas.',
          HydrostaticEvidenceRole.manometer5Bar =>
            'Cuando el manómetro indique 5 bar, toma una fotografía clara en la que se vea la lectura de presión.',
          HydrostaticEvidenceRole.final4Bar =>
            'DEJA EL GABINETE PRESURIZADO A 4 BAR Y TOMA UNA FOTOGRAFÍA DEL MANÓMETRO.',
          HydrostaticEvidenceRole.leakEvidence =>
            'Toma una o más fotografías de las uniones con fuga.',
        }),
        for (final e in photos)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  if (c.evidencePath != null)
                    GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              HydrostaticPhotoPage(id: id, evidenceId: e.id),
                        ),
                      ),
                      child: Image.file(
                        File(c.evidencePath!(e)),
                        height: 160,
                        cacheWidth: 600,
                        errorBuilder: (_, error, stack) => const Text(
                          'Archivo no disponible. Se conserva el registro.',
                        ),
                      ),
                    ),
                  Text(
                    'Captura: ${hydroDateLabel(e.capturedAt)} · ${e.timeSource == HydrostaticCaptureTimeSource.cameraMetadata
                        ? 'metadatos de cámara'
                        : e.timeSource == HydrostaticCaptureTimeSource.estimated
                        ? 'hora estimada del archivo'
                        : 'hora no determinada (retorno)'}',
                  ),
                  if (e.returnedAt != null)
                    Text('Retorno de cámara: ${hydroDateLabel(e.returnedAt)}'),
                  FutureBuilder<bool>(
                    future: c.evidenceValid(e),
                    builder: (context, s) => Text(
                      s.data == true
                          ? 'EVIDENCIA ÍNTEGRA'
                          : 'EVIDENCIA PENDIENTE O ARCHIVO NO DISPONIBLE',
                    ),
                  ),
                  if (e.location != null)
                    Text(
                      'GPS: ${e.location!.latitude}, ${e.location!.longitude} · precisión ${e.location!.accuracy} m',
                    ),
                  if (e.location != null)
                    Text('Fix GPS: ${hydroDateLabel(e.location!.fixAt)}'),
                  if (e.jointCodes.isNotEmpty)
                    Text(
                      'Uniones: ${e.jointCodes.map((code) => HydrostaticJoint.catalog.firstWhere((j) => j.code == code).name).join(', ')}',
                    ),
                  Text('Integridad: ${hydroWire(e.integrity)}'),
                  if (role == HydrostaticEvidenceRole.manometer5Bar &&
                      e.location == null)
                    const Text(
                      'GPS pendiente. La imagen se conserva; toma otra fotografía con ubicación válida.',
                    ),
                ],
              ),
            ),
          ),
        if (!readOnly)
          FilledButton.icon(
            onPressed:
                c.busy || c.photos == null || c.cameraRecoveryError != null
                ? null
                : () => hydroAction(context, () => c.capturePhoto(id, role)),
            icon: const Icon(Icons.camera_alt),
            label: Text(switch (role) {
              HydrostaticEvidenceRole.initialSetup => 'TOMAR FOTO',
              HydrostaticEvidenceRole.manometer5Bar => 'TOMAR FOTO A 5 BAR',
              HydrostaticEvidenceRole.final4Bar => 'TOMAR FOTO A 4 BAR',
              HydrostaticEvidenceRole.leakEvidence => 'TOMAR FOTO DE FUGA',
            }),
          ),
        if (photos.isNotEmpty)
          const Text(
            'Puedes tomar otra fotografía. Los originales anteriores se conservan.',
          ),
        if (c.busy) const LinearProgressIndicator(),
      ],
    );
  }
}

class HydrostaticExecutionPage extends StatefulWidget {
  const HydrostaticExecutionPage({super.key, required this.id});
  final String id;
  @override
  State<HydrostaticExecutionPage> createState() =>
      _HydrostaticExecutionPageState();
}

class _HydrostaticExecutionPageState extends State<HydrostaticExecutionPage> {
  bool allowPop = false, dialogOpen = false;
  Future<void> back() async {
    if (dialogOpen) return;
    dialogOpen = true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('HAY UNA PRUEBA EN CURSO'),
        content: const Text(
          'La prueba continuará registrada aunque salgas de esta pantalla. ¿Qué deseas hacer?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CONTINUAR PRUEBA'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('SALIR Y CONSERVAR'),
          ),
        ],
      ),
    );
    dialogOpen = false;
    if (leave != true || !mounted) return;
    setState(() => allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      Navigator.of(context).popUntil(
        (route) => route.settings.name == 'hydrostatic-list' || route.isFirst,
      );
    }
  }

  @override
  Widget build(BuildContext context) => HydrostaticFrame(
    title: 'PRUEBA HIDROSTÁTICA EN CURSO',
    canPop: allowPop,
    onBackBlocked: back,
    builder: (context, c) {
      final t = c.document(widget.id);
      if (t.state != HydrostaticTestState.active) {
        return Center(
          child: TextButton(
            onPressed: () => Navigator.pushReplacement(
              context,
              MaterialPageRoute<void>(
                builder: (_) =>
                    t.state == HydrostaticTestState.endedPendingResult
                    ? HydrostaticPendingResultPage(id: t.id)
                    : HydrostaticDetailPage(id: t.id),
              ),
            ),
            child: const Text('VER ESTADO GUARDADO'),
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(displayUid(t.cabinet.uid)),
          Text('Modelo: ${hydroModel(t)}'),
          Text('Técnico: ${t.actor.name}'),
          Text('Prueba #${t.attemptNumber}'),
          Text('Inicio: ${hydroDateLabel(t.startedAt)}'),
          HydrostaticClockView(id: t.id),
          const Text('Presión máxima objetivo: 5 bar'),
          const Text('1 → 2 → 3 → 4 → 5 bar'),
          const Text(
            'El banco se opera manualmente. La app no mide la presión.',
          ),
          const SizedBox(height: 16),
          HydrostaticEvidencePanel(
            id: t.id,
            role: HydrostaticEvidenceRole.manometer5Bar,
          ),
          const Text(
            'Graba un video continuo de aproximadamente 5 segundos a 5 bar: comienza mostrando la placa de identificación, continúa con el gabinete completo y termina enfocando el manómetro durante 3 segundos. Envíalo al grupo exclusivo de WhatsApp de evidencias hidrostáticas.',
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: c.busy
                ? null
                : () => hydroAction(context, () async {
                    await c.finish(t.id);
                    if (context.mounted &&
                        c.document(t.id).state ==
                            HydrostaticTestState.endedPendingResult) {
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              HydrostaticPendingResultPage(id: t.id),
                        ),
                      );
                    }
                  }),
            child: const Text('TERMINAR PRUEBA'),
          ),
        ],
      );
    },
  );
}

class HydrostaticClockView extends StatefulWidget {
  const HydrostaticClockView({super.key, required this.id});
  final String id;
  @override
  State<HydrostaticClockView> createState() => _HydrostaticClockViewState();
}

class _HydrostaticClockViewState extends State<HydrostaticClockView>
    with WidgetsBindingObserver {
  Timer? timer;
  void tick() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    tick();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      tick();
      setState(() {});
    } else {
      timer?.cancel();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final elapsed = context.read<HydrostaticController>().elapsed(widget.id);
    return Column(
      children: [
        Text(
          elapsed.display,
          key: const Key('hydro_clock'),
          style: Theme.of(context).textTheme.displayLarge,
        ),
        if (elapsed.state == HydrostaticTimeState.needsReview)
          const Text(
            'ADVERTENCIA: cambio de reloj. Timestamps conservados; duración pendiente de revisión.',
          ),
        if (elapsed.state == HydrostaticTimeState.reconstructed)
          const Text('Duración reconstruida desde el inicio guardado.'),
      ],
    );
  }
}

class HydrostaticPendingResultPage extends StatelessWidget {
  const HydrostaticPendingResultPage({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context) => HydrostaticResultPage(id: id);
}

class HydrostaticPhotoPage extends StatelessWidget {
  const HydrostaticPhotoPage({
    super.key,
    required this.id,
    required this.evidenceId,
  });
  final String id, evidenceId;
  @override
  Widget build(BuildContext context) => HydrostaticFrame(
    title: 'EVIDENCIA FOTOGRÁFICA',
    builder: (context, c) {
      final e = c
          .document(id)
          .evidence
          .where((e) => e.id == evidenceId)
          .firstOrNull;
      if (e == null || c.evidencePath == null) {
        return const Text('Archivo no disponible');
      }
      return InteractiveViewer(
        minScale: 0.5,
        maxScale: 5,
        child: Center(
          child: Image.file(
            File(c.evidencePath!(e)),
            errorBuilder: (_, error, stack) =>
                const Text('Archivo no disponible'),
          ),
        ),
      );
    },
  );
}
