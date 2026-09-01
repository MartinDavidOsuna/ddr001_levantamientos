import 'dart:io';
import 'package:flutter/material.dart' hide StepState;
import 'package:provider/provider.dart';
import '../../core/services/app_controller.dart';
import '../../core/widgets/branded_app_bar_title.dart';
import '../../domain/construction/construction_models.dart';
import 'surveys_page.dart';
import '../../shared/widgets/optional_comment_field.dart';
import '../shell/main_shell.dart';

class SurveyDetailPage extends StatefulWidget {
  const SurveyDetailPage({super.key, required this.surveyId});
  final String surveyId;
  @override
  State<SurveyDetailPage> createState() => _SurveyDetailPageState();
}

class _SurveyDetailPageState extends State<SurveyDetailPage>
    with WidgetsBindingObserver {
  AppController? _app;
  bool _locationActive = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_app != null) return;
    _app = context.read<AppController>();
    _activateLocation();
  }

  void _activateLocation() {
    if (_locationActive) return;
    _locationActive = true;
    _app?.enterLocationFlow();
  }

  void _deactivateLocation() {
    if (!_locationActive) return;
    _locationActive = false;
    _app?.leaveLocationFlow();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _activateLocation();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _deactivateLocation();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _deactivateLocation();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final survey = app.survey(widget.surveyId);
    return Scaffold(
      appBar: AppBar(title: BrandedAppBarTitle(survey.displayIdentifier)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              title: Text(
                surveyStatusLabel(survey.status),
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
            (step) => _StepCard(surveyId: widget.surveyId, step: step),
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
              (correction) => _CorrectionCard(
                surveyId: widget.surveyId,
                correction: correction,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum StepSavedAction { continueSurvey, home }

Future<StepSavedAction?> showStepSavedDialog(
  BuildContext context, {
  required int step,
}) => showDialog<StepSavedAction>(
  context: context,
  barrierDismissible: false,
  builder: (dialogContext) => AlertDialog(
    title: const Text('Información guardada'),
    content: const Text(
      'Tu información quedó guardada en el dispositivo y se sincronizará automáticamente.',
    ),
    actions: [
      TextButton(
        key: const Key('saved_home'),
        onPressed: () => Navigator.pop(dialogContext, StepSavedAction.home),
        child: const Text('SALIR AL INICIO'),
      ),
      FilledButton(
        key: const Key('saved_continue'),
        onPressed: () =>
            Navigator.pop(dialogContext, StepSavedAction.continueSurvey),
        child: Text(
          step == 6 ? 'VER LEVANTAMIENTO' : 'CONTINUAR LEVANTAMIENTO',
        ),
      ),
    ],
  ),
);

class _CorrectionCard extends StatelessWidget {
  const _CorrectionCard({required this.surveyId, required this.correction});
  final String surveyId;
  final CorrectionRound correction;
  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final evidence = app.photosForCorrection(correction.id);
    final open = correction.state == StepState.open;
    final editable =
        open &&
        (app.profile?.role ?? ConstructionRole.contractor).canMutateEvidence;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Corrección ${correction.round}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text(
              '${evidence.length} fotos · ${open ? 'Abierta' : 'Finalizada localmente'}',
            ),
            if (editable) ...[
              OptionalCommentField(
                initialValue: correction.comment,
                enabled: open,
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
                        evidence.every((photo) => photo.locationConfirmed)
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

class _StepCard extends StatefulWidget {
  const _StepCard({required this.surveyId, required this.step});
  final String surveyId;
  final SurveyStep step;

  @override
  State<_StepCard> createState() => _StepCardState();
}

class _StepCardState extends State<_StepCard> {
  static const _photoPageSize = 24;
  var _visiblePhotoCount = _photoPageSize;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final surveyId = widget.surveyId;
    final step = widget.step;
    final evidence = app.photosForStep(surveyId, step.number);
    final visibleEvidence = evidence.take(_visiblePhotoCount);
    final open = step.state == StepState.open;
    final editable =
        open &&
        (app.profile?.role ?? ConstructionRole.contractor).canMutateEvidence;
    final nextPurpose = step.number == 6
        ? cardinalPhotoPurposes.cast<PhotoPurpose?>().firstWhere(
            (purpose) => !evidence.any((photo) => photo.purpose == purpose),
            orElse: () => PhotoPurpose.additional,
          )
        : null;
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
                OptionalCommentField(
                  initialValue: step.comment,
                  enabled: editable,
                  onChanged: (value) =>
                      app.updateComment(surveyId, step.number, value),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: visibleEvidence
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
                                    if (editable)
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
                                    cacheWidth: 264,
                                    cacheHeight: 264,
                                    fit: BoxFit.cover,
                                    filterQuality: FilterQuality.low,
                                  ),
                                ),
                                if (photo.locationState ==
                                    PhotoLocationState.pending)
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
                                if (photo.locationState ==
                                    PhotoLocationState.provisional)
                                  const Positioned(
                                    right: 4,
                                    bottom: 4,
                                    child: CircleAvatar(
                                      radius: 12,
                                      backgroundColor: Colors.amber,
                                      child: Icon(
                                        Icons.location_on_outlined,
                                        color: Colors.black87,
                                        size: 14,
                                      ),
                                    ),
                                  ),
                                if (photo.locationConfirmed)
                                  const Positioned(
                                    right: 4,
                                    bottom: 4,
                                    child: CircleAvatar(
                                      radius: 12,
                                      backgroundColor: Colors.green,
                                      child: Icon(
                                        Icons.location_on,
                                        color: Colors.white,
                                        size: 14,
                                      ),
                                    ),
                                  ),
                                if (photo.locationUnresolved ||
                                    photo.locationConsistency ==
                                        LocationConsistency.outlier)
                                  const Positioned(
                                    right: 4,
                                    bottom: 4,
                                    child: CircleAvatar(
                                      radius: 12,
                                      backgroundColor: Colors.red,
                                      child: Icon(
                                        Icons.location_off,
                                        color: Colors.white,
                                        size: 14,
                                      ),
                                    ),
                                  ),
                                if (photo.purpose != null)
                                  Positioned(
                                    left: 3,
                                    top: 3,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: Colors.black87,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 2,
                                        ),
                                        child: Text(
                                          photoPurposeLabel(photo.purpose!),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 10,
                                          ),
                                        ),
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
                if (_visiblePhotoCount < evidence.length) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: Key('more_photos_${step.number}'),
                    onPressed: () => setState(() {
                      _visiblePhotoCount += _photoPageSize;
                    }),
                    icon: const Icon(Icons.expand_more),
                    label: Text(
                      'Mostrar más fotos '
                      '(${evidence.length - _visiblePhotoCount} restantes)',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                if (editable && step.number == 6) ...[
                  Row(
                    children: cardinalPhotoPurposes
                        .map(
                          (purpose) => Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  evidence.any(
                                        (photo) => photo.purpose == purpose,
                                      )
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                ),
                                const SizedBox(height: 4),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    photoPurposeLabel(purpose),
                                    maxLines: 1,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    nextPurpose == PhotoPurpose.additional
                        ? 'Fotografías adicionales'
                        : 'Foto requerida: ${photoPurposeLabel(nextPurpose!)}',
                    key: const Key('step6_next_photo'),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                ],
                if (editable)
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: Key('camera_${step.number}'),
                          onPressed:
                              step.maximumPhotos != null &&
                                  evidence.length >= step.maximumPhotos!
                              ? null
                              : () => app.capturePhoto(
                                  surveyId,
                                  step.number,
                                  purpose: nextPurpose,
                                ),
                          icon: const Icon(Icons.camera_alt),
                          label: Text(
                            nextPurpose == PhotoPurpose.additional
                                ? 'Agregar fotografía'
                                : 'Tomar foto',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton(
                          key: Key('finalize_${step.number}'),
                          onPressed:
                              app.canAttemptFinalize(surveyId, step.number)
                              ? () async {
                                  try {
                                    await app.finalizeStep(
                                      surveyId,
                                      step.number,
                                    );
                                  } on StateError catch (error) {
                                    if (!context.mounted) return;
                                    final replace = await showDialog<bool>(
                                      context: context,
                                      builder: (dialogContext) => AlertDialog(
                                        title: const Text(
                                          'Ubicación de evidencia',
                                        ),
                                        content: Text(error.message.toString()),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(
                                              dialogContext,
                                              false,
                                            ),
                                            child: const Text('VER FOTO'),
                                          ),
                                          FilledButton(
                                            onPressed: () => Navigator.pop(
                                              dialogContext,
                                              true,
                                            ),
                                            child: const Text(
                                              'REEMPLAZAR FOTO',
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (replace == true) {
                                      final target = evidence.firstWhere(
                                        (photo) => !photo.locationConfirmed,
                                      );
                                      await app.deletePhoto(
                                        surveyId,
                                        step.number,
                                        target.id,
                                      );
                                      await app.capturePhoto(
                                        surveyId,
                                        step.number,
                                        purpose: target.purpose,
                                      );
                                    }
                                    return;
                                  }
                                  if (!context.mounted) return;
                                  final action = await showStepSavedDialog(
                                    context,
                                    step: step.number,
                                  );
                                  if (!context.mounted) return;
                                  if (action == StepSavedAction.home) {
                                    MainShell.selectTab(0);
                                    Navigator.popUntil(
                                      context,
                                      (route) => route.isFirst,
                                    );
                                  } else if (action ==
                                          StepSavedAction.continueSurvey &&
                                      step.number < 6) {
                                    Navigator.pushReplacement(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => SurveyDetailPage(
                                          surveyId: surveyId,
                                        ),
                                      ),
                                    );
                                  }
                                }
                              : null,
                          child: const Text('Finalizar etapa'),
                        ),
                      ),
                    ],
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
