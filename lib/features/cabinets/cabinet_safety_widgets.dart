import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../data/cabinets/cabinet_controller.dart';
import '../../domain/cabinets/cabinet_models.dart';
import '../../domain/cabinets/cabinet_safety.dart';

class CabinetBusyButton extends StatefulWidget {
  const CabinetBusyButton({
    super.key,
    required this.onPressed,
    required this.child,
  }) : icon = null;
  const CabinetBusyButton.icon({
    super.key,
    required this.onPressed,
    required Widget label,
    required this.icon,
  }) : child = label;
  final FutureOr<void> Function()? onPressed;
  final Widget child;
  final Widget? icon;
  @override
  State<CabinetBusyButton> createState() => _CabinetBusyButtonState();
}

class _CabinetBusyButtonState extends State<CabinetBusyButton> {
  bool busy = false;
  @override
  Widget build(BuildContext context) {
    Future<void> run() async {
      if (busy) return;
      setState(() => busy = true);
      try {
        await widget.onPressed?.call();
      } finally {
        if (mounted) setState(() => busy = false);
      }
    }

    return FilledButton(
      onPressed: widget.onPressed == null || busy ? null : run,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          if (busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (widget.icon != null)
            widget.icon!,
          widget.child,
        ],
      ),
    );
  }
}

String cabinetIdentity(CabinetController c, String id) {
  final w = c.record(id).working,
      install = object(c.record(id).working['installation']);
  final base = c.app.visibleSurveys
      .where((b) => b.id == install['baseId'])
      .firstOrNull;
  return 'UID: ${displayUid(w['uid'])}\nModelo: ${w['model']}${w['automated'] == true ? '-A' : ''}\nBase: ${base?.displayIdentifier ?? install['baseId'] ?? 'sin seleccionar'}\nCuenta: ${install['accountNumber'] ?? 'sin cuenta'}';
}

Future<bool> confirmCabinetAction(
  BuildContext context, {
  required String title,
  required String message,
  String confirm = 'Confirmar',
  String cancel = 'Cancelar',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirm),
          ),
        ],
      ),
    ) ??
    false;

/// Advisories are explicit acknowledgements, not a claim of physical proximity certification.
Future<bool> confirmInstallation(
  BuildContext context,
  CabinetController c,
  String id,
) async {
  await c.flushDrafts();
  if (!context.mounted) return false;
  final w = c.record(id).working;
  if (!freshInstallationGps(w['installationGpsAt'], DateTime.now())) {
    throw StateError(
      'Captura GPS actual antes de guardar: la ubicación falta o tiene más de 15 minutos. El borrador se conserva.',
    );
  }
  validateInstallationLocation(c, id);
  final existing = objects(object(w['installation'])['answers']);
  for (final answer in objects(
    installationWithDefaults(
      object(w['installation']),
      objects(w['parts']),
    )['answers'],
  )) {
    if (!existing.any((a) => a['code'] == answer['code'])) {
      await c.patchInstallation(
        id,
        'answers',
        answer,
        answerCode: '${answer['code']}',
      );
    }
  }
  if (!context.mounted) return false;
  final warnings = installationWarnings(c, id);
  return confirmCabinetAction(
    context,
    title: 'Confirmar ubicación de instalación',
    message:
        '${cabinetIdentity(c, id)}\n\n${warnings.join('\n')}\n\nComprueba que estás registrando este gabinete en la base indicada.',
    confirm: 'Confirmar base y ubicación',
  );
}

double validateInstallationLocation(CabinetController c, String id) {
  final install = object(c.record(id).working['installation']);
  final base = c.app.visibleSurveys
      .where((b) => b.id == install['baseId'])
      .firstOrNull;
  final point = base?.canonicalLocation;
  if (point == null) {
    throw StateError(
      'Selecciona una base con coordenadas descargadas para validar la ubicación.',
    );
  }
  final gps = object(install['gps']);
  if (gps['latitude'] is! num || gps['longitude'] is! num) {
    throw StateError('Falta capturar GPS propio de instalación.');
  }
  final distance = distanceMeters(
    point.latitude,
    point.longitude,
    (gps['latitude'] as num).toDouble(),
    (gps['longitude'] as num).toDouble(),
  );
  if (!installationWithinBase(distance)) {
    throw StateError(
      'La instalación está a ${distance.toStringAsFixed(1)} m de la base. Debe estar a menos de 50 m. Revisa la base o vuelve a capturar el GPS.',
    );
  }
  return distance;
}

List<String> installationWarnings(CabinetController c, String id) {
  final w = c.record(id).working,
      install = object(w['installation']),
      gps = object(install['gps']);
  final base = c.app.visibleSurveys
      .where((b) => b.id == install['baseId'])
      .firstOrNull;
  final point = base?.canonicalLocation;
  if (point == null) {
    return [
      'No hay coordenadas de base descargadas para comparar. Verifica su identificación en campo.',
    ];
  }
  if (gps['latitude'] is! num || gps['longitude'] is! num) {
    return ['Falta GPS propio de instalación.'];
  }
  final distance = distanceMeters(
    point.latitude,
    point.longitude,
    (gps['latitude'] as num).toDouble(),
    (gps['longitude'] as num).toDouble(),
  );
  return [
    'Distancia a la base: ${distance.round()} m.',
    if (!installationWithinBase(distance))
      'Ubicación no válida: la distancia a la base debe ser menor de 50 metros.',
  ];
}

class CabinetModelDialog extends StatefulWidget {
  const CabinetModelDialog({super.key, required this.id});
  final String id;
  @override
  State<CabinetModelDialog> createState() => _CabinetModelDialogState();
}

class _CabinetModelDialogState extends State<CabinetModelDialog> {
  final form = GlobalKey<FormState>();
  late String model;
  late bool automated;
  late TextEditingController reason;
  @override
  void initState() {
    super.initState();
    final r = context.read<CabinetController>().record(widget.id);
    final actor = context.read<CabinetController>().actor;
    final draft = object(
      object(object(r.json['uiDrafts'])[actor])['modelCorrectionDraft'],
    );
    model = '${draft['model'] ?? r.working['model']}';
    automated = draft['automated'] as bool? ?? r.working['automated'] == true;
    reason = TextEditingController(text: '${draft['reason'] ?? ''}');
  }

  Future<void> saveDraft() => context.read<CabinetController>().saveAuxDraft(
    widget.id,
    'modelCorrectionDraft',
    {'model': model, 'automated': automated, 'reason': reason.text},
  );
  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>(),
        w = c.record(widget.id).working;
    final retained = compatibleParts(
      w,
      c.catalogFor(c.record(widget.id)).parts(model, automated),
    );
    final removed = objects(w['parts']).length - retained.length;
    return AlertDialog(
      scrollable: true,
      title: const Text('Corregir modelo'),
      content: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(cabinetIdentity(c, widget.id)),
            const SizedBox(height: 12),
            Text(
              'Se conservan ${retained.length} piezas compatibles. $removed capturas de piezas dejan de aplicar al nuevo modelo. Las fotos y el historial se conservan. Se reinicia el checklist de instalación y se exige revalidar.',
            ),
            DropdownButtonFormField<String>(
              initialValue: model,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Modelo correcto'),
              items: [
                'A1',
                'A2',
                'A3',
                'A4',
              ].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
              onChanged: (v) {
                setState(() => model = v!);
                unawaited(saveDraft());
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Incluye automatización'),
              value: automated,
              onChanged: (v) {
                setState(() => automated = v);
                unawaited(saveDraft());
              },
            ),
            TextFormField(
              controller: reason,
              minLines: 2,
              maxLines: 4,
              maxLength: 2000,
              decoration: const InputDecoration(
                labelText: 'Motivo obligatorio',
              ),
              validator: reasonError,
              onChanged: (_) => unawaited(saveDraft()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        CabinetBusyButton(
          onPressed: () async {
            if (!form.currentState!.validate()) return;
            await saveDraft();
            if (context.mounted) {
              Navigator.pop(context, {
                'model': model,
                'automated': automated,
                'reason': reason.text.trim(),
              });
            }
          },
          child: const Text('Aplicar corrección'),
        ),
      ],
    );
  }
}
