import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/hydrostatic/hydrostatic_contracts.dart';
import '../../domain/cabinets/cabinet_models.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';
import 'hydrostatic_controller.dart';
import 'hydrostatic_scanner.dart';
import 'hydrostatic_execution_pages.dart';

String hydroStatus(HydrostaticTest t) => t.isDiscarded
    ? 'DESCARTADA — TIEMPO DE REGISTRO AGOTADO'
    : t.endedAt != null &&
          t.closedAt == null &&
          t.timeState == HydrostaticTimeState.needsReview
    ? 'REVISIÓN TEMPORAL REQUERIDA'
    : switch (t.state) {
        HydrostaticTestState.preparation => 'PREPARACIÓN',
        HydrostaticTestState.starting => 'PREPARACIÓN PENDIENTE',
        HydrostaticTestState.active => 'EN PROCESO',
        HydrostaticTestState.endedPendingResult => 'RESULTADO PENDIENTE',
        HydrostaticTestState.leakDetailsPending =>
          'REGISTRO DE FUGAS PENDIENTE',
        HydrostaticTestState.approvalEvidencePending =>
          'EVIDENCIAS DE APROBACIÓN PENDIENTES',
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
    this.canPop = true,
    this.onBackBlocked,
  });
  final String title;
  final bool canPop;
  final VoidCallback? onBackBlocked;
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
    } else if (error != null || !c.ready) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error ??
                  'Recuperación pendiente. Reintenta para resolver el journal antes de continuar.',
              textAlign: TextAlign.center,
            ),
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
    if (authorized && !loading && c.cameraRecoveryError != null) {
      body = Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(c.cameraRecoveryError!),
          ),
          TextButton(
            onPressed: () => hydroAction(context, _load),
            child: const Text('REINTENTAR RECUPERACIÓN DE CÁMARA'),
          ),
          Expanded(child: body),
        ],
      );
    }
    return PopScope(
      canPop: !authorized || (!c.busy && widget.canPop),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !c.busy) widget.onBackBlocked?.call();
      },
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
          if (c.sync != null || c.syncSetupError != null) ...[
            if (c.syncSetupError != null) Text(c.syncSetupError!),
            if (c.sync?.error != null) Text(c.sync!.error!),
            TextButton.icon(
              onPressed: c.sync?.busy == true ? null : c.retrySync,
              icon: const Icon(Icons.sync),
              label: const Text('REINTENTAR SINCRONIZACIÓN'),
            ),
          ],
          if (uids.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('Aún no hay pruebas hidrostáticas registradas.'),
            ),
          for (final t in c.started.where(
            (t) =>
                !t.isDiscarded &&
                (t.state == HydrostaticTestState.active ||
                    t.state == HydrostaticTestState.endedPendingResult ||
                    t.state == HydrostaticTestState.leakDetailsPending ||
                    t.state == HydrostaticTestState.approvalEvidencePending ||
                    (t.state == HydrostaticTestState.passed &&
                        t.video.state == HydrostaticVideoState.pending)),
          ))
            ListTile(
              title: Text(
                t.state == HydrostaticTestState.active
                    ? 'PRUEBA EN CURSO — REANUDAR'
                    : t.state == HydrostaticTestState.passed
                    ? 'CONFIRMAR VIDEO ENVIADO'
                    : 'COMPLETAR RESULTADO',
              ),
              subtitle: Text(
                '${displayUid(t.cabinet.uid)} · Prueba #${t.attemptNumber}',
              ),
              onTap: () => _push(
                context,
                t.state == HydrostaticTestState.active
                    ? HydrostaticExecutionPage(id: t.id)
                    : HydrostaticPendingResultPage(id: t.id),
              ),
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
                    Text(c.syncLabel(c.history(uid).first.id)),
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
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${hydroModel(t)} · REANUDAR PREPARACIÓN'),
                      Text(c.syncLabel(t.id)),
                    ],
                  ),
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
        return TextButton(
          onPressed: () => Navigator.pushReplacement(
            context,
            MaterialPageRoute<void>(
              builder: (_) => t.state == HydrostaticTestState.active
                  ? HydrostaticExecutionPage(id: id)
                  : HydrostaticPendingResultPage(id: id),
            ),
          ),
          child: const Text('REANUDAR PRUEBA'),
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
          HydrostaticEvidencePanel(
            id: id,
            role: HydrostaticEvidenceRole.initialSetup,
          ),
          FutureBuilder<bool>(
            future: c.startAvailable(id),
            builder: (context, snapshot) => FilledButton(
              key: const Key('hydro_start'),
              onPressed: snapshot.data == true && !c.busy
                  ? () => hydroAction(context, () async {
                      await c.start(id);
                      if (context.mounted &&
                          c.document(id).state == HydrostaticTestState.active) {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => HydrostaticExecutionPage(id: id),
                          ),
                        );
                      }
                    })
                  : null,
              child: const Text('INICIAR PRUEBA'),
            ),
          ),
          Text(
            c.photos == null
                ? 'Para iniciar una prueba será necesario tomar la fotografía inicial del gabinete y registrar la ubicación GPS. Esta función se habilitará próximamente.'
                : 'Se requiere una foto inicial íntegra. Al iniciar se solicitará GPS reciente con precisión de hasta 100 m.',
          ),
          TextButton(
            onPressed: c.busy
                ? null
                : () => Navigator.pushReplacement(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const HydrostaticIdentifyPage(),
                    ),
                  ),
            child: const Text('VOLVER A IDENTIFICAR GABINETE'),
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
                  Text(c.syncLabel(t.id)),
                  Text(t.actor.name),
                  Text(
                    'Inicio: ${hydroDateLabel(t.startedAt)}\nFin: ${hydroDateLabel(t.endedAt)}\nDuración: ${hydroDuration(t)}',
                  ),
                  Text(hydroVideo(t)),
                ],
              ),
              trailing: TextButton(
                onPressed: () =>
                    _push(context, HydrostaticDetailPage(id: t.id)),
                child: const Text('VER DETALLE'),
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
          Text(c.syncLabel(id)),
          if (c.sync == null && c.syncSetupError != null)
            TextButton(
              onPressed: c.retrySync,
              child: const Text('REINTENTAR SINCRONIZACIÓN'),
            ),
          if (c.sync != null) ...[
            if (c.sync!.error != null) Text(c.sync!.error!),
            if (c.sync!.view(id)?['lastCommitAt'] != null)
              Text('Último recibo: ${c.sync!.view(id)!['lastCommitAt']}'),
            if (c.sync!.view(id)?['active']?['remoteStatus'] != null)
              Text(
                'Conflicto: versión remota ${c.sync!.view(id)!['active']['remoteStatus']['serverVersion']}. Se conserva la revisión local; no se sobrescribe el servidor.',
              ),
            TextButton(
              onPressed: c.sync!.busy ? null : c.retrySync,
              child: const Text('REINTENTAR / RECUPERAR RECIBO'),
            ),
          ],
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
          if (j['leakDraft'] != null)
            Text('Observación de fugas: ${j['leakDraft']['observation']}'),
          if (t.isDiscarded)
            Text(
              'Descarte por plazo vencido: ${hydroDateLabel(t.discardedAt)}. Originales e historial conservados.',
            ),
          const Text('EVIDENCIAS'),
          if (t.evidence.isEmpty) const Text('Pendiente'),
          for (final e in t.evidence)
            Text(
              '${hydroWire(e.role)} · ${hydroWire(e.state)} · ${hydroWire(e.integrity)}',
            ),
          for (final role in HydrostaticEvidenceRole.values)
            if (t.evidence.any((e) => e.role == role))
              HydrostaticEvidencePanel(id: id, role: role, readOnly: true),
          if ([
            HydrostaticTestState.endedPendingResult,
            HydrostaticTestState.leakDetailsPending,
            HydrostaticTestState.approvalEvidencePending,
            HydrostaticTestState.passed,
          ].contains(t.state))
            TextButton(
              onPressed: () =>
                  _push(context, HydrostaticPendingResultPage(id: id)),
              child: const Text('CONTINUAR RESULTADO / VIDEO'),
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
