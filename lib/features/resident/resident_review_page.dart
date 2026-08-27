import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/services/app_controller.dart';
import '../../domain/construction/construction_models.dart';
import '../surveys/survey_detail_page.dart';

class ResidentReviewPage extends StatefulWidget {
  const ResidentReviewPage({super.key});
  @override
  State<ResidentReviewPage> createState() => _ResidentReviewPageState();
}

class _ResidentReviewPageState extends State<ResidentReviewPage> {
  String search = '';
  SurveyStatus? filter = SurveyStatus.executed;
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final items = app.surveys
        .where(
          (s) =>
              (filter == null || s.status == filter) &&
              (search.isEmpty ||
                  s.displayIdentifier.toLowerCase().contains(
                    search.toLowerCase(),
                  ) ||
                  s.contractorName.toLowerCase().contains(
                    search.toLowerCase(),
                  )),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Revisión de base')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              onChanged: (v) => setState(() => search = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar base o contratista',
              ),
            ),
          ),
          DropdownButton<SurveyStatus?>(
            value: filter,
            items: [
              const DropdownMenuItem(value: null, child: Text('Todos')),
              ...SurveyStatus.values.map(
                (s) => DropdownMenuItem(
                  value: s,
                  child: Text(surveyStatusLabel(s)),
                ),
              ),
            ],
            onChanged: (v) => setState(() => filter = v),
          ),
          Expanded(
            child: ListView(
              children: items
                  .map(
                    (s) => Card(
                      child: ListTile(
                        title: Text(s.displayIdentifier),
                        subtitle: Text(
                          '${surveyStatusLabel(s.status)} · Etapa ${s.currentStep}/6\n'
                          'Contratista: ${s.contractorName}',
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => _ResidentDetail(surveyId: s.id),
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResidentDetail extends StatelessWidget {
  const _ResidentDetail({required this.surveyId});
  final String surveyId;
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>(),
        survey = app.survey(surveyId),
        submitting = app.reviewSubmitting(surveyId);
    return Scaffold(
      appBar: AppBar(title: Text(survey.displayIdentifier)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ReviewValue(
            label: 'IDENTIFICADOR DE LA BASE',
            value: survey.displayIdentifier,
          ),
          _ReviewValue(
            label: 'NÚMERO DE CUENTA',
            value: survey.accountNumber ?? 'Sin cuenta asignada',
          ),
          _ReviewValue(label: 'CONTRATISTA', value: survey.contractorName),
          _ReviewValue(
            label: 'ESTADO',
            value: surveyStatusLabel(survey.status),
          ),
          _ReviewValue(label: 'ETAPA', value: '${survey.currentStep}/6'),
          _ReviewValue(
            label: 'FECHA DE CREACIÓN',
            value: _dateLabel(survey.createdAt),
          ),
          _ReviewValue(
            label: 'ÚLTIMA ACTUALIZACIÓN',
            value: _dateLabel(survey.updatedAt),
          ),
          if (survey.rejectionReason?.isNotEmpty == true)
            _ReviewValue(
              label: 'MOTIVO DEL RECHAZO',
              value: survey.rejectionReason!,
            ),
          if (submitting)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(),
            ),
          FilledButton(
            onPressed: survey.status == SurveyStatus.executed && !submitting
                ? () => _mutate(
                    context,
                    app.acceptSurvey(survey.id),
                    title: 'Levantamiento aceptado',
                    message:
                        'La base fue validada correctamente y ahora está disponible como entregable.',
                  )
                : null,
            child: const Text('Aceptar'),
          ),
          OutlinedButton(
            onPressed: survey.status == SurveyStatus.executed && !submitting
                ? () async {
                    final reason = await _rejectionPrompt(context);
                    if (reason != null) {
                      if (!context.mounted) return;
                      await _mutate(
                        context,
                        app.rejectSurvey(survey.id, reason),
                        title: 'Levantamiento rechazado',
                        message:
                            'El contratista podrá consultar el motivo y registrar una corrección.',
                      );
                    }
                  }
                : null,
            child: const Text('Rechazar'),
          ),
          OutlinedButton(
            onPressed: survey.status == SurveyStatus.accepted && !submitting
                ? () => _mutate(
                    context,
                    app.deliverSurvey(survey.id),
                    title: 'Levantamiento entregado',
                    message: 'La base fue marcada como entregada.',
                  )
                : null,
            child: const Text('Marcar entregado'),
          ),
          OutlinedButton(
            onPressed: submitting
                ? null
                : () async {
                    final value = await _prompt(context, 'Nuevo identificador');
                    if (value != null) {
                      if (!context.mounted) return;
                      await _mutate(
                        context,
                        app.updateSurveyIdentity(
                          survey.id,
                          displayIdentifier: value,
                        ),
                        title: 'Identificador actualizado',
                        message:
                            'El identificador fue actualizado correctamente.',
                      );
                    }
                  },
            child: const Text('Editar identificador'),
          ),
          OutlinedButton(
            onPressed: submitting
                ? null
                : () async {
                    final value = await _prompt(context, 'Número de cuenta');
                    if (value != null) {
                      if (!context.mounted) return;
                      await _mutate(
                        context,
                        app.updateSurveyIdentity(
                          survey.id,
                          accountNumber: value.isEmpty ? null : value,
                          updateAccount: true,
                        ),
                        title: 'Cuenta actualizada',
                        message:
                            'El número de cuenta fue actualizado correctamente.',
                      );
                    }
                  },
            child: const Text('Asignar cuenta'),
          ),
          OutlinedButton(
            onPressed: submitting
                ? null
                : () async {
                    final reason = await _prompt(
                      context,
                      'Motivo de corrección GPS',
                    );
                    if (reason == null || reason.length < 3) return;
                    final point = await app.locations.capture();
                    if (!context.mounted) return;
                    await _mutate(
                      context,
                      app.correctSurveyCanonicalLocation(
                        survey.id,
                        point,
                        reason,
                      ),
                      title: 'Ubicación actualizada',
                      message:
                          'La ubicación canónica fue corregida y auditada.',
                    );
                  },
            child: const Text('Corregir ubicación canónica'),
          ),
          const Divider(),
          const Text(
            'El reviewer puede revisar estados y metadatos, pero no editar evidencia histórica.',
          ),
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SurveyDetailPage(surveyId: survey.id),
              ),
            ),
            child: const Text('Ver levantamiento'),
          ),
        ],
      ),
    );
  }
}

class _ReviewValue extends StatelessWidget {
  const _ReviewValue({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 3),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );
}

String _dateLabel(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year} '
      '${two(local.hour)}:${two(local.minute)}';
}

Future<void> _mutate(
  BuildContext context,
  Future<void> operation, {
  required String title,
  required String message,
}) async {
  try {
    await operation;
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('CERRAR'),
          ),
        ],
      ),
    );
  } on Object catch (error) {
    if (!context.mounted) return;
    final message = error is StateError
        ? error.message.toString()
        : 'No fue posible completar la operación.';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

Future<String?> _rejectionPrompt(BuildContext context) {
  final controller = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Rechazar levantamiento'),
        content: TextField(
          key: const Key('rejection_reason'),
          controller: controller,
          autofocus: true,
          minLines: 4,
          maxLines: 8,
          decoration: InputDecoration(
            labelText: 'Motivo del rechazo',
            hintText: 'Describe qué debe corregir el contratista.',
            alignLabelWithHint: true,
            errorText: error,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (value.length < 3) {
                setState(() => error = 'Escribe un motivo válido.');
                return;
              }
              Navigator.pop(dialogContext, value);
            },
            child: const Text('RECHAZAR'),
          ),
        ],
      ),
    ),
  );
}

Future<String?> _prompt(BuildContext context, String label) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(label),
      content: TextField(controller: controller, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Guardar'),
        ),
      ],
    ),
  );
}
