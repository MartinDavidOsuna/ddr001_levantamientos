import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../data/cabinets/cabinet_controller.dart';
import '../../data/cabinets/cabinet_legacy_scope.dart';
import '../../data/cabinets/legacy_cabinet_recovery.dart';
import '../../domain/cabinets/cabinet_models.dart';

class LegacyRecoveryPage extends StatefulWidget {
  const LegacyRecoveryPage({super.key, required this.controller});
  final CabinetController controller;
  @override
  State<LegacyRecoveryPage> createState() => _LegacyRecoveryPageState();
}

class _LegacyRecoveryPageState extends State<LegacyRecoveryPage> {
  LegacyCabinetRecovery? recovery;
  String? selected, error;
  bool busy = false, exiting = false;
  String? _initialSession;
  @override
  void initState() {
    super.initState();
    _initialSession = widget.controller.app.session?.sessionId;
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  Future<bool> confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;
  Future<void> prepare({
    bool measureOnly = false,
    bool compatibleEvidence = false,
  }) async {
    if (selected == null ||
        !await confirm(
          compatibleEvidence
              ? 'Preparar evidencia compatible — sin envío'
              : measureOnly
              ? 'Medir fotografías locales'
              : 'Preparar soporte selectivo',
          compatibleEvidence
              ? 'Se certificarán los originales y se crearán derivados JPEG separados, con hash de transporte propio y los mismos photoId. No se cambian fotografías ni comandos históricos. Sólo se consulta el servidor; no se transmite evidencia. Autorizar esta preparación no autoriza recuperación.'
              : measureOnly
              ? 'Se pausará Gabinetes para leer tamaños y hashes locales. No se consulta el servidor, no se suben fotos y no se modifica el respaldo anterior.'
              : 'Se pausará la sincronización de Gabinetes y se respaldará este expediente con sus fotografías. '
                    'Esta acción sólo consulta el servidor; no envía comandos. Usa la sesión del residente original.',
          'Preparar',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    final r = LegacyCabinetRecovery(
      widget.controller,
      selected!,
      cabinetAllowlist: {selected!},
      onProgress: () {
        if (mounted) setState(() {});
      },
    );
    recovery = r;
    try {
      await r.prepare(
        measureOnly: measureOnly,
        prepareDerivatives: compatibleEvidence,
      );
    } catch (e) {
      error = CabinetController.explain(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> prepareNew() async {
    if (!await confirm(
      'Acciones nuevas, no eventos históricos',
      'Revisa abajo las fotografías y cada pieza del checklist original. '
          'Al confirmar se crearán cierre, guardado y validación con fecha actual sobre el MISMO expediente. '
          'Las fotografías y capturas históricas no se cambian. No se enviarán todavía.',
      'He revisado y autorizo prepararlas',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await recovery!.prepareNewStages(
        reviewedOriginalChecklistAndEvidence: true,
      );
      error = null;
    } catch (e) {
      error = CabinetController.explain(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> execute() async {
    final r = recovery!;
    if (!await confirm(
      'Autorizar recuperación de este gabinete',
      'Se enviarán sólo las fotografías necesarias y la secuencia preparada, conservando sus identificadores:\n'
          '${r.sequence.map((o) => object(o['body'])['type']).join('\n')}\n'
          'Revise la legibilidad de los derivados mostrados. El respaldo está verificado. Se detendrá ante cualquier discrepancia. ¿Autorizar esta secuencia?',
      'Recuperar este gabinete',
    )) {
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      await r.execute(
        operationAllowlist: r.operationAllowlist,
        explicitlyConfirmed: true,
      );
      error = null;
    } catch (e) {
      error = CabinetController.explain(e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> close() async {
    if (busy || exiting) return;
    if (recovery != null &&
        !await confirm(
          'Finalizar soporte',
          'Los originales y el respaldo se conservan. No se iniciará sincronización al cerrar. '
              'Los expedientes históricos incompletos mantienen protección frente al envío automático.',
          'Cerrar soporte',
        )) {
      return;
    }
    try {
      await recovery?.close();
      if (mounted) {
        setState(() => exiting = true);
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => error = CabinetController.explain(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final records = c.records
        .where((r) => legacyCabinetUids.contains(r.working['uid']))
        .toList();
    final r = recovery;
    return PopScope(
      canPop: exiting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) close();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Soporte · recuperación histórica')),
        body: !c.supportAvailable || c.app.session?.sessionId != _initialSession
            ? const Center(
                child: Text('Soporte no autorizado para esta sesión.'),
              )
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text(
                    'Piloto: AQ26-00006-8. No recrea gabinetes ni valida por el estado local. Sólo el residente original puede autorizar los comandos.',
                  ),
                  if (r == null)
                    DropdownButtonFormField<String>(
                      initialValue: selected,
                      decoration: const InputDecoration(
                        labelText: 'Expediente local',
                      ),
                      items: records
                          .map(
                            (r) => DropdownMenuItem(
                              value: r.id,
                              child: Text(displayUid(r.working['uid'])),
                            ),
                          )
                          .toList(),
                      onChanged: busy
                          ? null
                          : (id) => setState(() => selected = id),
                    ),
                  if (r != null) ...[
                    Text('Fase: ${r.preparationPhase}'),
                    Text(
                      'UID: ${displayUid(r.local['uid'])}\nLocal: ${r.local['status']} · Servidor: ${r.server?['status'] ?? "no verificado"}\nVersión servidor: ${r.server?['version'] ?? "no verificada"}',
                    ),
                    Text(
                      'Fotos locales declaradas: ${c.store.read(r.cabinetId)?.photos.length ?? 0}\nCoincidencias en inventario remoto: ${r.remoteInventoryRead ? r.remoteMatchedPhotos : 'no consultado'}\nFotos verificadas en esta recuperación: ${r.remoteVerifiedPhotos ?? "pendiente de autorización"}\nPiezas del checklist: ${objects(r.local['parts']).length}',
                    ),
                    Text(
                      r.metricsOnly
                          ? 'Medición local: respaldo anterior conservado; no se crea ni sustituye una copia.'
                          : r.backupPath == null
                          ? 'Respaldo: no certificado'
                          : 'Respaldo privado íntegro y verificado. Conservado en este teléfono.',
                    ),
                    if (r.derivativeMode) ...[
                      Text(
                        'Evidencia compatible: ${r.derivatives.length} derivados preparados; originales y uploads históricos protegidos.',
                      ),
                      for (final derivative in r.derivatives.values) ...[
                        ListTile(subtitle: Text(derivative.summary)),
                        Image.file(
                          File(derivative.transport['localPath']),
                          height: 220,
                          errorBuilder: (_, _, _) => const Text(
                            'Derivado ilegible: no autorizar recuperación.',
                          ),
                        ),
                      ],
                      const Text(
                        'Hash declarado de transporte = bytes del derivado; metadatos históricos intactos. Preparar no autoriza transmitir.',
                      ),
                    ],
                    if (r.checklistPlan != null)
                      Text(
                        'Primer comando: ${r.checklistPlan!.firstCount} capturas originales; comparación de recibo ${r.confirmedVersions.containsKey(LegacyCabinetRecovery.pilotOperations[1]) ? "confirmada" : "pendiente"}.\n'
                        'Segundo comando original: ${r.checklistPlan!.secondCount} capturas.\n'
                        'Cobertura propuesta: ${r.checklistPlan!.merged.length}/${r.checklistPlan!.requiredCount}.\n'
                        'Capturas faltantes: ${r.checklistPlan!.missingCodes.join(", ")}. No implica ausencia física.',
                      ),
                    for (final op in r.sequence)
                      ListTile(
                        title: Text('${object(op['body'])['type']}'),
                        subtitle: Text(
                          '${object(op['body'])['operationId']} · versión esperada ${object(op['body'])['expectedVersion']} · ${r.confirmedVersions[object(op['body'])['operationId']] != null ? 'recibo confirmado v${r.confirmedVersions[object(op['body'])['operationId']]}; no reenviar' : op['state']}',
                        ),
                      ),
                    if (r.photoDiagnostics.isNotEmpty)
                      const Text(
                        'Tamaños fotográficos · lectura local sin envío',
                      ),
                    if (r.photoDiagnostics.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: r.photoMetricsSummary),
                                );
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'Resumen técnico copiado; sin fotos ni rutas.',
                                    ),
                                  ),
                                );
                              },
                        icon: const Icon(Icons.copy),
                        label: const Text('Copiar resumen técnico'),
                      ),
                    for (final diagnostic in r.photoDiagnostics)
                      ListTile(subtitle: SelectableText(diagnostic)),
                    if (r.operationDiagnostics.isNotEmpty)
                      const Text('Diagnóstico histórico · sólo lectura'),
                    for (var i = 0; i < r.operationDiagnostics.length; i++)
                      ListTile(
                        title: Text('Operación histórica ${i + 1}'),
                        subtitle: SelectableText(
                          r.operationDiagnostics[i].summary,
                        ),
                      ),
                    if (r.canPrepareNewStages) ...[
                      const Text(
                        'Revisión de evidencia original antes de preparar acciones nuevas',
                      ),
                      for (final photo in c.store.read(r.cabinetId)!.photos)
                        if (photo['localPath'] is String)
                          Image.file(
                            File(photo['localPath']),
                            height: 180,
                            errorBuilder: (_, _, _) => const Text(
                              'No se pudo abrir la fotografía; no confirmar.',
                            ),
                          ),
                      for (final part in objects(r.local['parts']))
                        ListTile(
                          title: Text('${part['code']}'),
                          subtitle: Text(
                            'Presente: ${part['present']} · Serie: ${part['serial'] ?? "no requerida/capturada"}',
                          ),
                        ),
                      FilledButton(
                        onPressed: busy ? null : prepareNew,
                        child: const Text(
                          'Preparar etapas nuevas desde originales',
                        ),
                      ),
                    ],
                    for (final blocker in r.blockers)
                      Text(blocker, style: const TextStyle(color: Colors.red)),
                    for (final result in r.results) Text(result),
                    if (r.completed)
                      const Text(
                        'Servidor confirmó Validado. Historial conservado; originales sin reemplazar.',
                      ),
                  ],
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
                  if (busy) const LinearProgressIndicator(),
                  if (r != null && !r.prepared && !busy)
                    TextButton(
                      onPressed: () async {
                        try {
                          await r.close();
                          if (mounted) {
                            setState(() {
                              recovery = null;
                              error = null;
                            });
                          }
                        } catch (e) {
                          if (mounted) {
                            setState(
                              () => error = CabinetController.explain(e),
                            );
                          }
                        }
                      },
                      child: const Text('Reintentar preparación'),
                    ),
                  if (r == null)
                    OutlinedButton(
                      onPressed:
                          busy ||
                              selected == null ||
                              c.store.read(selected!)?.working['uid'] !=
                                  legacyPilotUid
                          ? null
                          : () => prepare(measureOnly: true),
                      child: const Text('Medir fotografías · sin envío'),
                    ),
                  if (r == null)
                    OutlinedButton(
                      onPressed:
                          busy ||
                              selected == null ||
                              c.store.read(selected!)?.working['uid'] !=
                                  legacyPilotUid
                          ? null
                          : () => prepare(compatibleEvidence: true),
                      child: const Text(
                        'Preparar evidencia compatible — sin envío',
                      ),
                    ),
                  if (r == null)
                    FilledButton(
                      onPressed: busy || selected == null ? null : prepare,
                      child: const Text('Preparar recuperación'),
                    ),
                  if (r != null)
                    FilledButton(
                      onPressed: !busy && r.canExecute ? execute : null,
                      child: Text(
                        r.derivativeMode
                            ? 'Autorizar recuperación del gabinete'
                            : 'Recuperar este gabinete',
                      ),
                    ),
                  TextButton(
                    onPressed: busy ? null : close,
                    child: const Text('Cerrar soporte'),
                  ),
                ],
              ),
      ),
    );
  }
}
