import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../domain/cabinets/cabinet_models.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';
import 'hydrostatic_controller.dart';
import 'hydrostatic_pages.dart';
import 'hydrostatic_execution_pages.dart';

/// All routes reconstruct from an ID. Incomplete editor input belongs to the
/// repository/controller write queue, not to a TextEditingController.
class HydrostaticResultPage extends StatefulWidget {
  const HydrostaticResultPage({super.key, required this.id});
  final String id;
  @override
  State<HydrostaticResultPage> createState() => _HydrostaticResultPageState();
}

class _HydrostaticResultPageState extends State<HydrostaticResultPage> {
  bool leaving = false;
  Timer? expiryTimer;
  @override
  void initState() {
    super.initState();
    expiryTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        c
            .expireResults()
            .whenComplete(() {
              if (mounted) setState(() {});
            })
            .catchError((Object e) {
              /* Frame exposes recovery failure; no false success. */
            });
      }
    });
  }

  @override
  void dispose() {
    expiryTimer?.cancel();
    super.dispose();
  }

  HydrostaticController get c => context.read<HydrostaticController>();
  Future<void> leave() => hydroAction(context, () async {
    await c.flushDrafts();
    if (!mounted) return;
    setState(() => leaving = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      Navigator.of(
        context,
      ).popUntil((r) => r.settings.name == 'hydrostatic-list' || r.isFirst);
    }
  });

  Future<bool> confirm(String title, String message) async {
    final identity = c.identity;
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => Consumer<HydrostaticController>(
        builder: (context, current, _) {
          if (current.identity != identity) {
            return const AlertDialog(
              title: Text('Sesión modificada'),
              content: Text('Los datos se conservan. Regresa a Inicio.'),
            );
          }
          return AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('CANCELAR'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('CONFIRMAR'),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted) return false;
    c.requireIdentity(identity);
    return result == true;
  }

  void edit(String? code, String field, dynamic value) {
    final draft = c.leakDraft(widget.id);
    if (code == null) {
      draft[field] = value;
    } else {
      final joints = hydroObject(draft['joints']);
      final row = joints[code] == null
          ? <String, dynamic>{
              'selected': false,
              'pressure': '',
              'description': '',
            }
          : hydroObject(joints[code]);
      row[field] = value;
      joints[code] = row;
      draft['joints'] = joints;
    }
    // Immediate queued durable writes also preserve intermediate/invalid input.
    final save = c.saveDraft(widget.id, draft);
    setState(() {});
    hydroAction(context, () => save);
  }

  Object? _closureKey;
  Future<String?>? _closureFuture;

  Widget closure(HydrostaticTest t, bool leak) {
    // The countdown must not restart hashing full camera originals every second.
    // Commands still revalidate files and the deadline immediately before commit.
    final key = (
      t.id,
      t.revision,
      c.identity,
      c.busy,
      c.draftPending,
      c.pendingCaptures(t.id),
      c.cameraRecoveryError,
      c.resultExpired(t.id),
      c.resultRemaining(t.id).state,
    );
    if (_closureKey != key) {
      _closureKey = key;
      _closureFuture = c.closureIssue(t.id);
    }
    return FutureBuilder<String?>(
      future: _closureFuture,
      builder: (context, snapshot) => Column(
        children: [
          if (snapshot.data != null) Text(snapshot.data!),
          FilledButton(
            onPressed:
                snapshot.connectionState != ConnectionState.done ||
                    snapshot.data != null ||
                    c.busy
                ? null
                : () => hydroAction(context, () async {
                    await c.resultAction(t.id, leak ? 'leak' : 'pass');
                    if (!mounted) return;
                    if (leak) {
                      await leave();
                    } else {
                      setState(() {});
                    }
                  }),
            child: Text(leak ? 'GUARDAR RESULTADO' : 'GUARDAR APROBACIÓN'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => HydrostaticFrame(
    title: 'RESULTADO DE PRUEBA',
    canPop: leaving,
    onBackBlocked: leave,
    builder: (context, controller) {
      final t = controller.document(widget.id);
      final review = controller.requiresTimeReview(t.id);
      final expired = t.isDiscarded || controller.resultExpired(t.id) || review;
      final leak =
          !expired && t.state == HydrostaticTestState.leakDetailsPending;
      final approval =
          !expired && t.state == HydrostaticTestState.approvalEvidencePending;
      final draft = controller.leakDraft(t.id),
          rows = hydroObject(draft['joints']);
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(displayUid(t.cabinet.uid)),
          Text('Modelo: ${hydroModel(t)}'),
          Text('Prueba #${t.attemptNumber} · ${t.actor.name}'),
          Text('Inicio: ${hydroDateLabel(t.startedAt)}'),
          Text('Fin: ${hydroDateLabel(t.endedAt)}'),
          Text('Duración: ${hydroDuration(t)}'),
          Text(
            hydroStatus(t),
            style: TextStyle(
              color: t.state == HydrostaticTestState.passed
                  ? Colors.green
                  : t.state == HydrostaticTestState.failed
                  ? Colors.red
                  : null,
            ),
          ),
          if (t.endedAt != null && t.closedAt == null && !t.isDiscarded)
            HydrostaticResultCountdown(id: t.id),
          if (t.isDiscarded)
            const Text(
              'El intento, sus datos y fotografías se conservan. No tiene resultado hidráulico definitivo.',
            ),
          if (!t.isDiscarded && controller.resultExpired(t.id))
            const Text('TIEMPO AGOTADO — DESCARTE PENDIENTE DE GUARDAR'),
          if (review)
            const Text(
              'REVISIÓN TEMPORAL REQUERIDA. No se puede determinar un cierre válido. Datos conservados; no se aprueba ni descarta automáticamente.',
            ),
          if (t.isDiscarded || review)
            FilledButton.icon(
              onPressed: c.busy
                  ? null
                  : () => hydroAction(context, () async {
                      await c.flushDrafts();
                      final newId = await c.identify(t.cabinet.uid);
                      if (context.mounted) {
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            builder: (_) =>
                                HydrostaticPreparationPage(id: newId),
                          ),
                        );
                      }
                    }),
              icon: const Icon(Icons.add),
              label: const Text('INICIAR NUEVO INTENTO'),
            ),
          if (!expired &&
              t.state == HydrostaticTestState.endedPendingResult) ...[
            const Text('¿SE REGISTRARON FUGAS?'),
            for (final yes in [true, false])
              FilledButton(
                onPressed: c.busy
                    ? null
                    : () => hydroAction(
                        context,
                        () => c.resultAction(t.id, 'answer', yes: yes),
                      ),
                child: Text(yes ? 'SÍ' : 'NO'),
              ),
          ],
          if (!expired && t.endedAt != null && t.closedAt == null)
            const Text(
              'Completa el cierre dentro de los 30 minutos posteriores al fin del cronómetro. Al vencer, el intento se descarta conservando datos y fotos.',
            ),
          if (leak || approval)
            TextButton(
              onPressed: c.busy
                  ? null
                  : () => hydroAction(context, () async {
                      if (await confirm(
                        'CAMBIAR RESPUESTA',
                        '¿Cambiar a ${leak ? 'NO' : 'SÍ'} hubo fugas? Se conservarán borradores y fotografías.',
                      )) {
                        await c.resultAction(
                          t.id,
                          'change',
                          yes: !leak,
                          confirmed: true,
                        );
                      }
                    }),
              child: const Text('CAMBIAR RESPUESTA'),
            ),
          if (leak) ...[
            const Text('REGISTRO DE FUGAS'),
            Text(
              c.draftPending
                  ? 'Guardado pendiente. No cierres la app hasta confirmar.'
                  : 'Borrador guardado',
            ),
            TextButton(
              onPressed: () => hydroAction(context, c.flushDrafts),
              child: const Text('REINTENTAR GUARDADO'),
            ),
            for (final joint in HydrostaticJoint.catalog) ...[
              CheckboxListTile(
                key: Key('joint_${joint.code}'),
                title: Text(joint.name),
                value: rows[joint.code]?['selected'] == true,
                onChanged: c.busy
                    ? null
                    : (v) => edit(joint.code, 'selected', v == true),
              ),
              if (rows[joint.code]?['selected'] == true) ...[
                TextFormField(
                  key: Key('pressure_${joint.code}'),
                  initialValue: rows[joint.code]['pressure'],
                  enabled: !c.busy,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'PRESIÓN A LA QUE SE PRESENTÓ LA FUGA (bar)',
                    helperText: '1 a 5 bar · hasta tres decimales',
                  ),
                  onChanged: (v) => edit(joint.code, 'pressure', v),
                ),
                if (joint.code == 'J11')
                  TextFormField(
                    key: const Key('other_description'),
                    initialValue: rows[joint.code]['description'],
                    enabled: !c.busy,
                    decoration: const InputDecoration(
                      labelText: 'DESCRIBE LA UNIÓN DONDE SE PRESENTÓ LA FUGA',
                    ),
                    onChanged: (v) => edit(joint.code, 'description', v),
                  ),
              ],
            ],
            TextFormField(
              key: const Key('leak_observation'),
              initialValue: draft['observation'],
              enabled: !c.busy,
              decoration: const InputDecoration(labelText: 'Observación'),
              onChanged: (v) => edit(null, 'observation', v),
            ),
            HydrostaticEvidencePanel(
              id: t.id,
              role: HydrostaticEvidenceRole.leakEvidence,
            ),
            for (final e in t.evidence.where(
              (e) => e.role == HydrostaticEvidenceRole.leakEvidence,
            )) ...[
              Text('Uniones visibles en foto ${e.id}'),
              Wrap(
                children: [
                  for (final joint in HydrostaticJoint.catalog)
                    FilterChip(
                      label: Text(joint.name),
                      selected: e.jointCodes.contains(joint.code),
                      onSelected: c.busy
                          ? null
                          : (selected) => hydroAction(
                              context,
                              () => c.linkEvidence(
                                t.id,
                                e.id,
                                selected
                                    ? [...e.jointCodes, joint.code]
                                    : e.jointCodes
                                          .where((v) => v != joint.code)
                                          .toList(),
                              ),
                            ),
                    ),
                ],
              ),
            ],
            closure(t, true),
          ],
          if (approval) ...[
            const Text('RESUMEN DE PRUEBA HIDROSTÁTICA'),
            Text('GPS inicial: ${t.toJson()['location']}'),
            const Text(
              'Presión máxima objetivo: 5 bar. Presión final requerida: 4 bar. Son valores declarados, no lecturas electrónicas.',
            ),
            HydrostaticEvidencePanel(
              id: t.id,
              role: HydrostaticEvidenceRole.initialSetup,
              readOnly: true,
            ),
            const Text(
              'La evidencia a 5 bar debe haberse capturado durante la ejecución. No se permite recapturarla después del fin.',
            ),
            HydrostaticEvidencePanel(
              id: t.id,
              role: HydrostaticEvidenceRole.manometer5Bar,
              readOnly: true,
            ),
            HydrostaticEvidencePanel(
              id: t.id,
              role: HydrostaticEvidenceRole.final4Bar,
            ),
            closure(t, false),
          ],
          if (t.state == HydrostaticTestState.passed) ...[
            Text(hydroVideo(t)),
            const Text('EVIDENCIA DE VIDEO'),
            const Text(
              'GRABA UN VIDEO CONTINUO DE APROXIMADAMENTE 5 SEGUNDOS A 5 BAR:\n1. Comienza mostrando claramente la placa de identificación.\n2. Muestra todo el gabinete conectado al banco de pruebas.\n3. Termina enfocando el manómetro a 5 bar durante 3 segundos.\nEnvía el video al grupo exclusivo de WhatsApp de evidencias hidrostáticas.',
            ),
            const Text(
              'Estas instrucciones corresponden al video de la ejecución a 5 bar. La app no recibe ni verifica videos o mensajes.',
            ),
            if (t.video.state == HydrostaticVideoState.pending)
              FilledButton(
                onPressed: c.busy
                    ? null
                    : () => hydroAction(context, () async {
                        if (await confirm(
                          'VIDEO ENVIADO',
                          '¿Confirmas que enviaste el video de esta prueba al grupo? Es una declaración del operador, no una confirmación de recepción.',
                        )) {
                          await c.resultAction(t.id, 'video', confirmed: true);
                          if (mounted) await leave();
                        }
                      }),
                child: const Text('VIDEO ENVIADO'),
              ),
            if (t.video.declaredAt != null)
              Text(
                'Declarado por ${t.video.actorId} · ${hydroDateLabel(t.video.declaredAt)}. No acredita recepción en WhatsApp/NAS.',
              ),
          ],
          TextButton(
            onPressed: c.busy ? null : leave,
            child: const Text('VOLVER A LA LISTA'),
          ),
        ],
      );
    },
  );
}

/// Informational only; every close is independently checked by the repository.
class HydrostaticResultCountdown extends StatelessWidget {
  const HydrostaticResultCountdown({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context) {
    final remaining = context.read<HydrostaticController>().resultRemaining(id);
    final review = remaining.state == HydrostaticTimeState.needsReview;
    final seconds = (remaining.milliseconds / 1000).ceil();
    final label = review
        ? '--:--'
        : '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text('TIEMPO RESTANTE PARA REGISTRAR RESULTADO'),
            Text(
              label,
              key: const Key('hydro_result_countdown'),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            if (!review && seconds <= 300)
              const Text(
                'El plazo está por terminar. Guarda el resultado antes del vencimiento.',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            if (review) const Text('Tiempo pendiente de revisión.'),
          ],
        ),
      ),
    );
  }
}
