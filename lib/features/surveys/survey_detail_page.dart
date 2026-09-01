import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart' hide StepState;
import 'package:provider/provider.dart';
import '../../core/services/app_controller.dart';
import '../../core/identity/uuid_identity.dart';
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
  bool _detailRequested = false;
  String? _detailError;

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
    if (_app!.canCurrentSessionViewSurveyId(widget.surveyId)) {
      if (_app!.profile?.role.canMutateEvidence ?? false) _activateLocation();
      _loadDetail();
    }
  }

  Future<void> _loadDetail() async {
    if (_detailRequested || _app?.online != true) return;
    final survey = _app!.survey(widget.surveyId);
    if (survey.syncState != SyncState.synchronized &&
        _app!.profile?.role.isReviewer != true) {
      return;
    }
    _detailRequested = true;
    try {
      await _app!.loadSurveyDetail(widget.surveyId);
    } catch (_) {
      if (mounted) {
        setState(() => _detailError = 'No fue posible actualizar el detalle.');
      }
    }
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
    if (!app.canCurrentSessionViewSurveyId(widget.surveyId)) {
      return const _SurveyAccessDenied();
    }
    final survey = app.survey(widget.surveyId);
    return Scaffold(
      appBar: AppBar(title: BrandedAppBarTitle(survey.displayIdentifier)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_detailError != null)
            ListTile(
              leading: const Icon(Icons.cloud_off),
              title: Text(_detailError!),
              trailing: TextButton(
                onPressed: () {
                  setState(() {
                    _detailRequested = false;
                    _detailError = null;
                  });
                  _loadDetail();
                },
                child: const Text('Reintentar'),
              ),
            ),
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

class _SurveyAccessDenied extends StatelessWidget {
  const _SurveyAccessDenied();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const BrandedAppBarTitle('Acceso denegado')),
    body: const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text('Este levantamiento no pertenece a la sesión actual.'),
      ),
    ),
  );
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

class _CorrectionCard extends StatefulWidget {
  const _CorrectionCard({required this.surveyId, required this.correction});
  final String surveyId;
  final CorrectionRound correction;

  @override
  State<_CorrectionCard> createState() => _CorrectionCardState();
}

class _CorrectionCardState extends State<_CorrectionCard> {
  bool _showRemoteEvidence = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final surveyId = widget.surveyId;
    final correction = widget.correction;
    final evidence = app.photosForCorrection(correction.id);
    final localIds = evidence.map((photo) => photo.id).toSet();
    final remoteEvidence = app
        .remotePhotosForCorrection(surveyId, correction.round)
        .where((photo) => !localIds.any((id) => uuidEquals(id, photo.id)))
        .toList(growable: false);
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
              '${app.photoCountForCorrection(surveyId, correction)} fotos · ${open ? 'Abierta' : 'Finalizada'}',
            ),
            if (remoteEvidence.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: Key('remote_correction_photos_${correction.id}'),
                  onPressed: () => setState(
                    () => _showRemoteEvidence = !_showRemoteEvidence,
                  ),
                  icon: Icon(
                    _showRemoteEvidence ? Icons.expand_less : Icons.expand_more,
                  ),
                  label: Text(
                    _showRemoteEvidence
                        ? 'Ocultar fotos remotas'
                        : 'Ver fotos remotas (${remoteEvidence.length})',
                  ),
                ),
              ),
            if (_showRemoteEvidence && remoteEvidence.isNotEmpty)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: remoteEvidence
                    .map((photo) => _RemotePhotoTile(photo: photo))
                    .toList(growable: false),
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
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.step.state == StepState.open;
  }

  @override
  void didUpdateWidget(covariant _StepCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step.state != widget.step.state &&
        widget.step.state == StepState.open) {
      _expanded = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final surveyId = widget.surveyId;
    final step = widget.step;
    final evidence = app.photosForStep(surveyId, step.number);
    final localIds = evidence.map((photo) => photo.id).toSet();
    final remoteEvidence = app
        .remotePhotosForStep(surveyId, step.number)
        .where((photo) => !localIds.any((id) => uuidEquals(id, photo.id)))
        .toList(growable: false);
    final evidenceCount = app.photoCountForStep(surveyId, step.number);
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
        onExpansionChanged: (expanded) => setState(() {
          _expanded = expanded;
        }),
        enabled: step.state != StepState.locked,
        leading: CircleAvatar(child: Text('${step.number}')),
        title: Text(
          constructionStepNames[step.number],
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '$evidenceCount/${step.maximumPhotos ?? '∞'} fotos · ${stepStateLabel(step.state)}',
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
                if (_expanded && remoteEvidence.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: remoteEvidence
                          .map((photo) => _RemotePhotoTile(photo: photo))
                          .toList(growable: false),
                    ),
                  ),
                ],
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

class _RemotePhotoTile extends StatefulWidget {
  const _RemotePhotoTile({required this.photo});
  final RemoteConstructionPhoto photo;

  @override
  State<_RemotePhotoTile> createState() => _RemotePhotoTileState();
}

class _RemotePhotoTileState extends State<_RemotePhotoTile> {
  Future<Uint8List>? _thumb;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _thumb ??= context.read<AppController>().remotePhotoBytes(
      widget.photo,
      original: false,
    );
  }

  void _retry() => setState(() {
    _thumb = context.read<AppController>().remotePhotoBytes(
      widget.photo,
      original: false,
    );
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: Key('remote_photo_${widget.photo.id}'),
    onTap: () => showDialog<void>(
      context: context,
      builder: (_) => _RemoteOriginalDialog(photo: widget.photo),
    ),
    child: Stack(
      children: [
        SizedBox.square(
          dimension: 88,
          child: FutureBuilder<Uint8List>(
            future: _thumb,
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                return ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(snapshot.data!, fit: BoxFit.cover),
                );
              }
              if (snapshot.hasError) {
                return OutlinedButton(
                  key: Key('remote_photo_retry_${widget.photo.id}'),
                  onPressed: _retry,
                  child: const Text('Imagen no disponible\nReintentar'),
                );
              }
              return const Center(child: CircularProgressIndicator());
            },
          ),
        ),
        if (widget.photo.purpose != null)
          Positioned(
            left: 3,
            top: 3,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  photoPurposeLabel(widget.photo.purpose!),
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _RemoteOriginalDialog extends StatefulWidget {
  const _RemoteOriginalDialog({required this.photo});
  final RemoteConstructionPhoto photo;

  @override
  State<_RemoteOriginalDialog> createState() => _RemoteOriginalDialogState();
}

class _RemoteOriginalDialogState extends State<_RemoteOriginalDialog> {
  Future<Uint8List>? _original;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _original ??= context.read<AppController>().remotePhotoBytes(
      widget.photo,
      original: true,
    );
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: FutureBuilder<Uint8List>(
      future: _original,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return InteractiveViewer(child: Image.memory(snapshot.data!));
        }
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Imagen no disponible temporalmente'),
                TextButton(
                  onPressed: () => setState(() {
                    _original = context.read<AppController>().remotePhotoBytes(
                      widget.photo,
                      original: true,
                    );
                  }),
                  child: const Text('Reintentar'),
                ),
              ],
            ),
          );
        }
        return const Padding(
          padding: EdgeInsets.all(48),
          child: CircularProgressIndicator(),
        );
      },
    ),
  );
}

String stepStateLabel(StepState state) => switch (state) {
  StepState.locked => 'Bloqueada',
  StepState.open => 'Abierta',
  StepState.completedLocal => 'Finalizada localmente',
  StepState.completedServer => 'Sincronizada',
};
