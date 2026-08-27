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
                (s) => DropdownMenuItem(value: s, child: Text(s.name)),
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
                          '${s.contractorName} · ${s.status.name}',
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
    final app = context.watch<AppController>(), survey = app.survey(surveyId);
    return Scaffold(
      appBar: AppBar(title: Text(survey.displayIdentifier)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: Text(survey.displayIdentifier),
            subtitle: Text(
              '${survey.contractorName}\n${survey.accountNumber ?? 'Sin cuenta'}',
            ),
          ),
          FilledButton(
            onPressed: survey.status == SurveyStatus.executed
                ? () => app.remote.residentAction(survey.id, 'accept')
                : null,
            child: const Text('Aceptar'),
          ),
          OutlinedButton(
            onPressed: survey.status == SurveyStatus.executed
                ? () async {
                    final reason = await _prompt(context, 'Motivo de rechazo');
                    if (reason != null) {
                      await app.remote.residentAction(survey.id, 'reject', {
                        'rejectionReason': reason,
                      });
                    }
                  }
                : null,
            child: const Text('Rechazar'),
          ),
          OutlinedButton(
            onPressed: survey.status == SurveyStatus.accepted
                ? () => app.remote.residentAction(survey.id, 'deliver')
                : null,
            child: const Text('Marcar entregado'),
          ),
          OutlinedButton(
            onPressed: () async {
              final value = await _prompt(context, 'Nuevo identificador');
              if (value != null) {
                await app.remote.residentUpdate(survey.id, {
                  'displayIdentifier': value,
                });
              }
            },
            child: const Text('Editar identificador'),
          ),
          OutlinedButton(
            onPressed: () async {
              final value = await _prompt(context, 'Número de cuenta');
              if (value != null) {
                await app.remote.residentUpdate(survey.id, {
                  'accountNumber': value.isEmpty ? null : value,
                });
              }
            },
            child: const Text('Asignar cuenta'),
          ),
          OutlinedButton(
            onPressed: () async {
              final reason = await _prompt(context, 'Motivo de corrección GPS');
              if (reason == null || reason.length < 3) return;
              final point = await app.locations.capture();
              await app.remote.correctCanonicalLocation(
                survey.id,
                point,
                reason,
              );
            },
            child: const Text('Corregir ubicación canónica'),
          ),
          const Divider(),
          const Text(
            'El residente puede revisar estados y metadatos, pero no editar evidencia.',
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
