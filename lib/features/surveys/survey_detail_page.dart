import 'dart:io';
import 'package:flutter/material.dart' hide StepState;
import 'package:provider/provider.dart';
import '../../core/services/app_controller.dart';
import '../../domain/construction/construction_models.dart';
import 'surveys_page.dart';

class SurveyDetailPage extends StatelessWidget {
  const SurveyDetailPage({super.key, required this.surveyId});
  final String surveyId;
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final survey = app.survey(surveyId);
    return Scaffold(
      appBar: AppBar(title: Text(survey.displayIdentifier)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              title: Text(
                statusLabel(survey.status),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(
                '${survey.accountNumber ?? 'Sin cuenta'} · Etapa ${survey.currentStep}/6',
              ),
              trailing: Icon(syncIcon(survey.syncState)),
            ),
          ),
          if (survey.status == SurveyStatus.rejected)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                title: const Text('Rechazado'),
                subtitle: Text(
                  survey.rejectionReason ??
                      'Consulta el motivo con el residente',
                ),
                trailing: const Icon(Icons.build),
              ),
            ),
          ...survey.steps.map(
            (step) => _StepCard(surveyId: surveyId, step: step),
          ),
          if (survey.corrections.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text(
                'Correcciones',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ...survey.corrections.map(
              (correction) =>
                  _CorrectionCard(surveyId: surveyId, correction: correction),
            ),
          ],
        ],
      ),
    );
  }
}

class _CorrectionCard extends StatelessWidget {
  const _CorrectionCard({required this.surveyId, required this.correction});
  final String surveyId;
  final CorrectionRound correction;
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final evidence = app.photosForCorrection(correction.id);
    final open = correction.state == StepState.open;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Correction Round ${correction.round}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              '${evidence.length} fotos · ${open ? 'Abierta' : 'Finalizada localmente'}',
            ),
            if (open) ...[
              TextFormField(
                initialValue: correction.comment,
                decoration: const InputDecoration(
                  labelText: 'Comentario opcional',
                ),
                onChanged: (value) =>
                    app.updateCorrectionComment(surveyId, correction.id, value),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    app.captureCorrectionPhoto(surveyId, correction.id),
                icon: const Icon(Icons.camera_alt),
                label: const Text('Tomar foto de corrección'),
              ),
              FilledButton(
                onPressed:
                    evidence.isNotEmpty &&
                        evidence.every((photo) => !photo.locationPending)
                    ? () => app.finalizeCorrection(surveyId, correction.id)
                    : null,
                child: const Text('Finalizar corrección'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  const _StepCard({required this.surveyId, required this.step});
  final String surveyId;
  final SurveyStep step;
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final evidence = app.photosForStep(surveyId, step.number);
    final open = step.state == StepState.open;
    return Card(
      child: ExpansionTile(
        key: Key('step_${step.number}'),
        initiallyExpanded: open,
        enabled: step.state != StepState.locked,
        leading: CircleAvatar(child: Text('${step.number}')),
        title: Text(
          constructionStepNames[step.number],
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${evidence.length}/${step.maximumPhotos ?? '∞'} fotos · ${stepStateLabel(step.state)}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: step.state == StepState.locked
            ? const []
            : [
                TextFormField(
                  initialValue: step.comment,
                  enabled: open,
                  maxLength: 2000,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Comentario opcional',
                  ),
                  onChanged: (value) =>
                      app.updateComment(surveyId, step.number, value),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: evidence
                        .map(
                          (photo) => GestureDetector(
                            key: Key('photo_${photo.id}'),
                            onTap: () => showDialog<void>(
                              context: context,
                              builder: (_) => Dialog(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Image.file(File(photo.localPath)),
                                    if (open)
                                      TextButton.icon(
                                        onPressed: () {
                                          Navigator.pop(context);
                                          app.deletePhoto(
                                            surveyId,
                                            step.number,
                                            photo.id,
                                          );
                                        },
                                        icon: const Icon(Icons.delete),
                                        label: const Text('Eliminar'),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            child: Stack(
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.file(
                                    File(photo.thumbnailPath),
                                    width: 88,
                                    height: 88,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                                if (photo.locationPending)
                                  const Positioned(
                                    right: 4,
                                    bottom: 4,
                                    child: CircleAvatar(
                                      radius: 12,
                                      child: Icon(
                                        Icons.location_searching,
                                        size: 14,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
                const SizedBox(height: 12),
                if (open)
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: Key('camera_${step.number}'),
                          onPressed:
                              step.maximumPhotos != null &&
                                  evidence.length >= step.maximumPhotos!
                              ? null
                              : () => app.capturePhoto(surveyId, step.number),
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('Tomar foto'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          key: Key('finalize_${step.number}'),
                          onPressed: app.canFinalize(surveyId, step.number)
                              ? () => app.finalizeStep(surveyId, step.number)
                              : null,
                          child: const Text('Finalizar etapa'),
                        ),
                      ),
                    ],
                  ),
                if (evidence.any((p) => p.locationPending))
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Esperando ubicación válida para una o más fotos.',
                    ),
                  ),
              ],
      ),
    );
  }
}

String stepStateLabel(StepState state) => switch (state) {
  StepState.locked => 'Bloqueada',
  StepState.open => 'Abierta',
  StepState.completedLocal => 'Finalizada localmente',
  StepState.completedServer => 'Sincronizada',
};
