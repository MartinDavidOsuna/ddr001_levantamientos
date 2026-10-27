import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/hydrostatic/hydrostatic_contracts.dart';
import '../../domain/cabinets/cabinet_models.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';
import 'hydrostatic_controller.dart';
import 'hydrostatic_scanner.dart';

String hydroStatus(HydrostaticTest t) => switch (t.state) {
  HydrostaticTestState.preparation => 'PREPARACIÓN',
  HydrostaticTestState.starting => 'PREPARACIÓN PENDIENTE',
  HydrostaticTestState.active => 'EN PROCESO',
  HydrostaticTestState.endedPendingResult => 'RESULTADO PENDIENTE',
  HydrostaticTestState.leakDetailsPending ||
  HydrostaticTestState.approvalEvidencePending => 'EVIDENCIAS PENDIENTES',
  HydrostaticTestState.failed => 'FUGA',
  HydrostaticTestState.passed => 'APROBADO',
};
String hydroDateLabel(DateTime? date) =>
    date == null ? 'Pendiente' : date.toLocal().toString().split('.').first;
String hydroDuration(HydrostaticTest t) => t.durationMs == null
    ? 'Pendiente'
    : HydrostaticElapsed(t.durationMs!, t.timeState, const []).display;
String hydroModel(HydrostaticTest t) =>
    '${t.cabinet.model}${t.cabinet.automated ? '-A' : ''}';
String hydroVideo(HydrostaticTest t) => switch (t.video.state) {
  HydrostaticVideoState.notApplicable => 'No aplica',
  HydrostaticVideoState.pending => 'VIDEO PENDIENTE',
  HydrostaticVideoState.declaredSent => 'VIDEO ENVIADO',
};
void _push(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

/// Each route binds to the entering session. A new user never inherits its UI.
/// Resume verifies SecureSessionStore again; back only navigates, never writes.
class HydrostaticFrame extends StatefulWidget {
  const HydrostaticFrame({
    super.key,
    required this.title,
    required this.builder,
  });
  final String title;
  final Widget Function(BuildContext, HydrostaticController) builder;
  @override
  State<HydrostaticFrame> createState() => _HydrostaticFrameState();
}

class _HydrostaticFrameState extends State<HydrostaticFrame>
    with WidgetsBindingObserver {
  late final HydrostaticController controller;
  String? identity;
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    controller = context.read<HydrostaticController>();
    identity = controller.identity;
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    try {
      controller.requireIdentity(identity);
      await controller.initialize();
      controller.requireIdentity(identity);
      if (mounted) {
        setState(() {
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '$e';
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() => loading = true);
      _load();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<HydrostaticController>();
    final authorized = identity != null && c.identity == identity;
    Widget body;
    if (!authorized) {
      body = const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Sesión sin autorización o modificada. Regresa a Inicio. Los registros se conservan.',
          ),
        ),
      );
    } else if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (error != null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error!, textAlign: TextAlign.center),
            FilledButton(
              onPressed: () {
                setState(() => loading = true);
                _load();
              },
              child: const Text('REINTENTAR'),
            ),
          ],
        ),
      );
    } else {
      try {
        body = widget.builder(context, c);
      } catch (e) {
        body = Center(child: Text('$e'));
      }
    }
    return PopScope(
      canPop: !c.busy || !authorized,
      child: Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: body,
      ),
    );
  }
}

class HydrostaticListPage extends StatelessWidget {
  const HydrostaticListPage({super.key});
  @override
  Widget build(BuildContext context) => HydrostaticFrame(
    title: 'PRUEBAS HIDROSTÁTICAS',
    builder: (context, c) {
      final uids = c.started.map((t) => t.cabinet.uid).toSet();
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          FilledButton.icon(
            key: const Key('hydro_new'),
            onPressed: () => _push(context, const HydrostaticIdentifyPage()),
            icon: const Icon(Icons.add),
            label: const Text('NUEVA PRUEBA'),
          ),
          if (uids.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('Aún no hay pruebas hidrostáticas registradas.'),
            ),
          for (final uid in uids)
            Card(
              child: ListTile(
                title: Text(displayUid(uid)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${c.history(uid).length} intento(s) · Prueba #${c.history(uid).first.attemptNumber}',
                    ),
                    HydrostaticStatusLabel(test: c.history(uid).first),
                    Text(
                      '${hydroDateLabel(c.history(uid).first.startedAt)} · ${hydroDuration(c.history(uid).first)}',
                    ),
                    if (c.history(uid).first.state ==
                        HydrostaticTestState.passed)
                      Text(hydroVideo(c.history(uid).first)),
                  ],
                ),
                trailing: const Icon(Icons.history),
                onTap: () => _push(context, HydrostaticHistoryPage(uid: uid)),
              ),
            ),
          if (c.preparations.isNotEmpty) ...[
            const SizedBox(height: 24),
            const Text('PREPARACIONES GUARDADAS'),
            for (final t in c.preparations)
              Card(
                child: ListTile(
                  key: ValueKey('preparation_${t.id}'),
                  title: Text(displayUid(t.cabinet.uid)),
                  subtitle: Text('${hydroModel(t)} · ${hydroStatus(t)}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () =>
                      _push(context, HydrostaticPreparationPage(id: t.id)),
                ),
              ),
          ],
        ],
      );
    },
  );
}

class HydrostaticIdentifyPage extends StatefulWidget {
  const HydrostaticIdentifyPage({super.key, this.scannerBuilder});
  final WidgetBuilder? scannerBuilder;
  @override
  State<HydrostaticIdentifyPage> createState() =>
      _HydrostaticIdentifyPageState();
}

class _HydrostaticIdentifyPageState extends State<HydrostaticIdentifyPage> {
  final input = TextEditingController();
  String? error;
  bool navigating = false;
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> identify(String raw) async {
    if (navigating) return;
    setState(() {
      navigating = true;
      error = null;
    });
    try {
      final c = context.read<HydrostaticController>(),
          key = context.read<HydrostaticController>().identity;
      final id = await c.identify(raw);
      c.requireIdentity(key);
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => HydrostaticPreparationPage(id: id),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => navigating = false);
    }
  }

  @override
  Widget build(BuildContext context) => HydrostaticFrame(
    title: 'IDENTIFICAR GABINETE',
    builder: (context, c) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        FilledButton.icon(
          onPressed: navigating
              ? null
              : () async {
                  final key = c.identity;
                  final raw = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder:
                          widget.scannerBuilder ??
                          (_) => const HydrostaticScannerPage(),
                    ),
                  );
                  if (raw != null && mounted && c.identity == key) {
                    input.text = raw;
                    await identify(raw);
                  }
                },
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('ESCANEAR QR'),
        ),
        const SizedBox(height: 24),
        TextField(
          key: const Key('hydro_uid'),
          controller: input,
          enabled: !navigating,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'CAPTURAR NÚMERO DE SERIE',
            hintText: 'AQ26-00001-7',
          ),
          onSubmitted: navigating ? null : identify,
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: navigating ? null : () => identify(input.text),
          icon: const Icon(Icons.search),
          label: const Text('BUSCAR GABINETE'),
        ),
        if (navigating) const LinearProgressIndicator(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(error!, key: const Key('hydro_error')),
          ),
      ],
    ),
  );
}

class HydrostaticPreparationPage extends StatelessWidget {
  const HydrostaticPreparationPage({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context) => HydrostaticFrame(
    title: 'PRUEBA HIDROSTÁTICA',
    builder: (context, c) {
      final t = c.document(id);
      if (t.startedAt != null) {
        return const Center(
          child: Text(
            'Esta prueba ya fue iniciada. Consulta su detalle en el historial.',
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            displayUid(t.cabinet.uid),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Text('Modelo: ${hydroModel(t)}'),
          Text('Usuario: ${t.actor.name}'),
          Text('Prueba #${c.provisional(id)} provisional'),
          const Text(
            'El número definitivo se asignará al iniciar; esta preparación no consume intentos.',
          ),
          Text(
            'Evidencia inicial: ${t.evidence.any((e) => e.role == HydrostaticEvidenceRole.initialSetup && e.ready) ? 'Registrada' : 'Pendiente'}',
          ),
          FutureBuilder<String?>(
            future: c.preparationWarning(id),
            builder: (context, snapshot) => Text(
              snapshot.hasError ? '${snapshot.error}' : snapshot.data ?? '',
            ),
          ),
          const SizedBox(height: 24),
          const FilledButton(
            key: Key('hydro_start'),
            onPressed: null,
            child: Text('INICIAR PRUEBA'),
          ),
          const Text(
            'Para iniciar una prueba será necesario tomar la fotografía inicial del gabinete y registrar la ubicación GPS. Esta función se habilitará próximamente.',
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('CANCELAR'),
          ),
          const Text(
            'La preparación se conserva para continuar posteriormente.',
          ),
        ],
      );
    },
  );
}

class HydrostaticStatusLabel extends StatelessWidget {
  const HydrostaticStatusLabel({super.key, required this.test});
  final HydrostaticTest test;
  @override
  Widget build(BuildContext context) => Text(
    hydroStatus(test),
    style: TextStyle(
      fontWeight: FontWeight.bold,
      color: test.state == HydrostaticTestState.passed
          ? Colors.green.shade800
          : test.state == HydrostaticTestState.failed
          ? Colors.red.shade800
          : Colors.orange.shade900,
    ),
  );
}

class HydrostaticHistoryPage extends StatelessWidget {
  const HydrostaticHistoryPage({super.key, required this.uid});
  final String uid;
  @override
  Widget build(BuildContext context) => HydrostaticFrame(
    title: 'HISTORIAL DE PRUEBAS',
    builder: (context, c) => ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(displayUid(cabinetUid(uid))),
        for (final t in c.history(uid))
          Card(
            child: ListTile(
              title: Text('Prueba #${t.attemptNumber}'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  HydrostaticStatusLabel(test: t),
                  Text(t.actor.name),
                  Text(
                    'Inicio: ${hydroDateLabel(t.startedAt)}\nFin: ${hydroDateLabel(t.endedAt)}\nDuración: ${hydroDuration(t)}',
                  ),
                  if (t.state == HydrostaticTestState.passed)
                    Text(hydroVideo(t)),
                ],
              ),
              onTap: () => _push(context, HydrostaticDetailPage(id: t.id)),
            ),
          ),
      ],
    ),
  );
}

class HydrostaticDetailPage extends StatelessWidget {
  const HydrostaticDetailPage({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context) => HydrostaticFrame(
    title: 'DETALLE DE PRUEBA',
    builder: (context, c) {
      final t = c.document(id), j = t.toJson(), location = j['location'];
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(displayUid(t.cabinet.uid)),
          Text('Modelo: ${hydroModel(t)}'),
          Text('Técnico: ${t.actor.name}'),
          Text('Prueba #${t.attemptNumber ?? 'provisional'}'),
          HydrostaticStatusLabel(test: t),
          Text('Inicio: ${hydroDateLabel(t.startedAt)}'),
          Text('Fin: ${hydroDateLabel(t.endedAt)}'),
          Text('Duración: ${hydroDuration(t)}'),
          Text(
            'Ubicación: ${location == null ? 'No disponible' : '${location['latitude']}, ${location['longitude']} · precisión ${location['accuracy']} m'}',
          ),
          const Text(
            'Objetivo del procedimiento: 5 bar · final requerida: 4 bar',
          ),
          const Text(
            'Estas presiones son objetivos; no constituyen una medición electrónica.',
          ),
          Text(
            'Fugas: ${t.hadLeaks == null
                ? 'Pendiente'
                : t.hadLeaks!
                ? 'Sí'
                : 'No'}',
          ),
          for (final leak in t.leaks)
            Text(
              '${HydrostaticJoint.catalog.firstWhere((v) => v.code == leak.jointCode).name}: ${leak.pressureMilliBar / 1000} bar ${leak.description}',
            ),
          const SizedBox(height: 16),
          const Text('EVIDENCIAS'),
          if (t.evidence.isEmpty) const Text('Pendiente'),
          for (final e in t.evidence)
            Text(
              '${hydroWire(e.role)} · ${hydroWire(e.state)} · ${hydroWire(e.integrity)}',
            ),
          Text(hydroVideo(t)),
          if (t.video.declaredAt != null)
            Text(
              'Declaración: ${hydroDateLabel(t.video.declaredAt)} · ${t.video.actorId}',
            ),
          if (t.state == HydrostaticTestState.passed)
            const Text(
              'La declaración no confirma recepción en WhatsApp ni vinculación en NAS.',
            ),
          if (c.canDelete(id))
            OutlinedButton(
              onPressed: () async {
                final key = c.identity;
                final yes = await showDialog<bool>(
                  context: context,
                  builder: (context) => Consumer<HydrostaticController>(
                    builder: (context, current, _) {
                      if (current.identity != key) {
                        return AlertDialog(
                          title: const Text('Sesión modificada'),
                          content: const Text(
                            'Regresa a Inicio. Los datos se conservan.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('CERRAR'),
                            ),
                          ],
                        );
                      }
                      return AlertDialog(
                        title: const Text('ELIMINAR PRUEBA LOCAL'),
                        content: Text(
                          '${displayUid(t.cabinet.uid)} · Prueba #${t.attemptNumber ?? 'provisional'}\nUUID: $id\nSe eliminarán únicamente esta prueba sintética y sus evidencias locales.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('CANCELAR'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('ELIMINAR'),
                          ),
                        ],
                      );
                    },
                  ),
                );
                if (yes != true || !context.mounted || c.identity != key) {
                  return;
                }
                try {
                  await c.delete(id, id);
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('$e')));
                  }
                }
              },
              child: const Text('ELIMINAR PRUEBA LOCAL'),
            ),
        ],
      );
    },
  );
}
