import 'dart:async';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';
import '../../data/remote/construction_api.dart';
import '../../domain/construction/construction_models.dart';
import '../config/app_config.dart';
import '../location/location_service.dart';
import '../media/photo_capture_service.dart';
import '../network/api_client.dart';
import '../persistence/local_store.dart';
import '../security/session_store.dart';

class AppController extends ChangeNotifier {
  AppController({
    required this.config,
    required this.local,
    required this.sessions,
    required ApiClient api,
    required this.packageInfo,
    LocationService? locations,
    PhotoCaptureService? camera,
  }) : remote = ConstructionApi(api, sessions, packageInfo),
       locations = locations ?? LocationService(),
       camera = camera ?? PhotoCaptureService();
  final AppConfig config;
  final LocalStore local;
  final SessionStore sessions;
  final ConstructionApi remote;
  final PackageInfo packageInfo;
  final LocationService locations;
  final PhotoCaptureService camera;
  FieldSession? session;
  ConstructionProfile? profile;
  List<BaseSurvey> surveys = [];
  List<ConstructionPhoto> photos = [];
  List<SyncQueueItem> queue = [];
  bool busy = false, online = true, syncing = false;
  String? message;
  String? pendingTakeoverToken;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;

  Future<void> bootstrap() async {
    surveys = local.surveys();
    photos = local.photos();
    queue = local.queue();
    profile = local.profile();
    session = await sessions.read();
    _connectivity = Connectivity().onConnectivityChanged.listen((values) {
      online = !values.contains(ConnectivityResult.none);
      notifyListeners();
      if (online && session != null) unawaited(synchronize());
    });
    if (session != null) {
      try {
        profile = await remote.profile();
        await local.saveProfile(profile!);
        online = true;
        unawaited(refreshServer());
        unawaited(synchronize());
      } catch (_) {
        online = false;
      }
    }
  }

  @override
  void dispose() {
    _connectivity?.cancel();
    super.dispose();
  }

  Future<String?> login({
    required String name,
    required String email,
    required String phone,
    required String crew,
  }) async {
    if (name.trim().length < 3 ||
        !email.contains('@') ||
        !RegExp(r'^\d{10}$').hasMatch(phone.trim()) ||
        crew.trim().isEmpty) {
      return 'Revisa nombre, correo, teléfono de 10 dígitos y cuadrilla.';
    }
    busy = true;
    message = null;
    notifyListeners();
    try {
      session = await remote.login(
        name: name,
        email: email,
        phone: phone,
        crew: crew,
      );
      profile = await remote.profile();
      await local.saveProfile(profile!);
      online = true;
      return null;
    } on DioException catch (error) {
      final data = error.response?.data;
      if (error.response?.statusCode == 409 && data is Map) {
        pendingTakeoverToken = data['takeoverToken']?.toString();
        return pendingTakeoverToken == null
            ? 'La sesión ya está activa.'
            : 'Tu usuario está activo en otro dispositivo.';
      }
      return 'No fue posible iniciar sesión. Verifica conexión y datos.';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<String?> revokeExistingSession() async {
    final token = pendingTakeoverToken;
    if (token == null) return 'No hay una sesión por reemplazar.';
    try {
      await remote.revokeExisting(token);
      pendingTakeoverToken = null;
      notifyListeners();
      return null;
    } catch (_) {
      return 'No fue posible cerrar la sesión anterior.';
    }
  }

  Future<void> logout() async {
    final current = session;
    if (current != null) await remote.logout(current).catchError((_) {});
    session = null;
    profile = null;
    notifyListeners();
  }

  bool duplicateKnown(String identifier) {
    final normalized = normalizeIdentifier(identifier);
    return surveys.any(
      (s) => normalizeIdentifier(s.displayIdentifier) == normalized,
    );
  }

  Future<BaseSurvey> createSurvey(String identifier) async {
    final clean = identifier.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (clean.isEmpty) throw StateError('El identificador es obligatorio.');
    if (duplicateKnown(clean)) {
      throw StateError(
        'Ya existe un levantamiento propio con ese identificador.',
      );
    }
    final now = DateTime.now().toUtc();
    final survey = BaseSurvey(
      id: const Uuid().v4(),
      displayIdentifier: clean,
      contractorName: profile?.displayName ?? session?.name ?? '',
      createdAt: now,
      updatedAt: now,
      status: SurveyStatus.created,
      localState: LocalSurveyState.createdLocal,
      syncState: SyncState.pending,
      currentStep: 0,
      steps: List.generate(
        6,
        (i) => SurveyStep(
          number: i + 1,
          state: i == 0 ? StepState.open : StepState.locked,
        ),
      ),
    );
    surveys = [survey, ...surveys];
    await local.saveSurvey(survey);
    await _enqueue(survey.id, QueueOperation.createSurvey);
    notifyListeners();
    return survey;
  }

  BaseSurvey survey(String id) => surveys.firstWhere((s) => s.id == id);
  List<ConstructionPhoto> photosForStep(String surveyId, int step) => photos
      .where(
        (p) =>
            p.surveyId == surveyId &&
            p.stepNumber == step &&
            p.syncState != PhotoSyncState.deleted,
      )
      .toList();
  Future<void> updateComment(String surveyId, int step, String comment) async {
    final s = survey(surveyId), steps = [...s.steps], current = steps[step - 1];
    if (current.state != StepState.open) {
      throw StateError('La etapa finalizada es inmutable.');
    }
    steps[step - 1] = current.copyWith(comment: comment);
    await _replaceSurvey(
      s.copyWith(steps: steps, syncState: SyncState.pending),
    );
    await _enqueue(surveyId, QueueOperation.updateComment, step: step);
  }

  Future<void> capturePhoto(String surveyId, int step) async {
    final s = survey(surveyId),
        current = s.steps[step - 1],
        existing = photosForStep(surveyId, step);
    if (current.state != StepState.open) {
      throw StateError('La etapa está cerrada.');
    }
    if (current.maximumPhotos != null &&
        existing.length >= current.maximumPhotos!) {
      throw StateError('Esta etapa admite máximo 4 fotos.');
    }
    final pending = await camera.capture(surveyId: surveyId, step: step);
    if (pending == null) return;
    photos = [...photos, pending];
    await local.savePhoto(pending);
    final steps = [...s.steps];
    steps[step - 1] = current.copyWith(
      photoIds: [...current.photoIds, pending.id],
    );
    await _replaceSurvey(
      s.copyWith(
        steps: steps,
        localState: LocalSurveyState.active,
        syncState: SyncState.pending,
      ),
    );
    notifyListeners();
    unawaited(_resolveLocation(pending.id));
  }

  Future<void> _resolveLocation(String photoId) async {
    try {
      final point = await locations.capture(),
          photo = photos.firstWhere((p) => p.id == photoId),
          updated = photo.copyWith(
            location: point,
            syncState: PhotoSyncState.queued,
          );
      await _replacePhoto(updated);
      final s = survey(photo.surveyId);
      if (photo.stepNumber == 1 && s.canonicalLocation == null) {
        await _replaceSurvey(s.copyWith(canonicalLocation: point));
      }
      await _enqueue(
        photo.surveyId,
        QueueOperation.uploadPhoto,
        photoId: photo.id,
        step: photo.stepNumber,
      );
    } catch (_) {
      message = 'Una foto sigue esperando ubicación válida.';
      notifyListeners();
    }
  }

  Future<void> deletePhoto(String surveyId, int step, String photoId) async {
    final s = survey(surveyId), current = s.steps[step - 1];
    if (current.state != StepState.open) {
      throw StateError('La evidencia finalizada es inmutable.');
    }
    final photo = photos.firstWhere((p) => p.id == photoId);
    await File(
      photo.localPath,
    ).delete().catchError((_) => File(photo.localPath));
    await File(
      photo.thumbnailPath,
    ).delete().catchError((_) => File(photo.thumbnailPath));
    photos = photos.where((p) => p.id != photoId).toList();
    await local.deletePhoto(photoId);
    final steps = [...s.steps];
    steps[step - 1] = current.copyWith(
      photoIds: current.photoIds.where((id) => id != photoId).toList(),
    );
    await _replaceSurvey(s.copyWith(steps: steps));
  }

  bool canFinalize(String surveyId, int step) {
    final s = survey(surveyId),
        current = s.steps[step - 1],
        evidence = photosForStep(surveyId, step);
    return current.state == StepState.open &&
        evidence.length >= current.minimumPhotos &&
        (current.maximumPhotos == null ||
            evidence.length <= current.maximumPhotos!) &&
        evidence.every(
          (p) =>
              !p.locationPending &&
              File(p.localPath).existsSync() &&
              p.sha256.length == 64,
        );
  }

  Future<void> finalizeStep(String surveyId, int step) async {
    if (!canFinalize(surveyId, step)) {
      throw StateError('Completa fotos y ubicación antes de finalizar.');
    }
    final s = survey(surveyId), steps = [...s.steps];
    steps[step - 1] = steps[step - 1].copyWith(state: StepState.completedLocal);
    if (step < 6) steps[step] = steps[step].copyWith(state: StepState.open);
    final executed = step == 6;
    await _replaceSurvey(
      s.copyWith(
        steps: steps,
        currentStep: step,
        localState: executed
            ? LocalSurveyState.executedLocal
            : LocalSurveyState.active,
        status: executed ? SurveyStatus.executed : SurveyStatus.inProgress,
        syncState: SyncState.pending,
      ),
    );
    await _enqueue(surveyId, QueueOperation.openStep, step: step);
    await _enqueue(surveyId, QueueOperation.completeStep, step: step);
    notifyListeners();
    if (online) unawaited(synchronize());
  }

  Future<void> createCorrection(
    String surveyId,
    String correctionId,
    int round,
  ) async {
    final s = survey(surveyId);
    if (s.status != SurveyStatus.rejected) {
      throw StateError('Sólo un levantamiento rechazado puede corregirse.');
    }
    await _replaceSurvey(
      s.copyWith(
        corrections: [
          ...s.corrections,
          CorrectionRound(
            id: correctionId,
            round: round,
            state: StepState.open,
          ),
        ],
      ),
    );
  }

  List<ConstructionPhoto> photosForCorrection(String correctionId) => photos
      .where(
        (p) =>
            p.correctionId == correctionId &&
            p.syncState != PhotoSyncState.deleted,
      )
      .toList();

  Future<void> captureCorrectionPhoto(
    String surveyId,
    String correctionId,
  ) async {
    final s = survey(surveyId);
    final correction = s.corrections.firstWhere((c) => c.id == correctionId);
    if (correction.state != StepState.open) {
      throw StateError('La corrección está cerrada.');
    }
    final pending = await camera.capture(
      surveyId: surveyId,
      correctionId: correctionId,
    );
    if (pending == null) return;
    photos = [...photos, pending];
    await local.savePhoto(pending);
    final corrections = s.corrections
        .map(
          (c) => c.id == correctionId
              ? CorrectionRound(
                  id: c.id,
                  round: c.round,
                  state: c.state,
                  comment: c.comment,
                  photoIds: [...c.photoIds, pending.id],
                )
              : c,
        )
        .toList();
    await _replaceSurvey(
      s.copyWith(corrections: corrections, syncState: SyncState.pending),
    );
    unawaited(_resolveLocation(pending.id));
  }

  Future<void> finalizeCorrection(String surveyId, String correctionId) async {
    final related = photos
        .where((p) => p.correctionId == correctionId)
        .toList();
    if (related.isEmpty || related.any((p) => p.locationPending)) {
      throw StateError('La corrección requiere foto con GPS.');
    }
    final s = survey(surveyId);
    final corrections = s.corrections
        .map(
          (c) => c.id == correctionId
              ? CorrectionRound(
                  id: c.id,
                  round: c.round,
                  state: StepState.completedLocal,
                  comment: c.comment,
                  photoIds: c.photoIds,
                )
              : c,
        )
        .toList();
    await _replaceSurvey(
      s.copyWith(
        corrections: corrections,
        localState: LocalSurveyState.executedLocal,
        syncState: SyncState.pending,
      ),
    );
    await _enqueue(
      surveyId,
      QueueOperation.completeCorrection,
      correctionId: correctionId,
    );
  }

  Future<void> updateCorrectionComment(
    String surveyId,
    String correctionId,
    String comment,
  ) async {
    final current = survey(surveyId);
    await _replaceSurvey(
      current.copyWith(
        corrections: current.corrections
            .map(
              (c) => c.id == correctionId
                  ? CorrectionRound(
                      id: c.id,
                      round: c.round,
                      state: c.state,
                      comment: comment,
                    )
                  : c,
            )
            .toList(),
      ),
    );
  }

  Future<void> synchronize() async {
    if (syncing || !online || session == null) return;
    syncing = true;
    notifyListeners();
    final ordered = [...queue]
      ..sort((a, b) {
        final pa = QueueOperation.values.indexOf(a.operation),
            pb = QueueOperation.values.indexOf(b.operation);
        return pa != pb ? pa.compareTo(pb) : a.createdAt.compareTo(b.createdAt);
      });
    for (final item in ordered) {
      if (item.nextAttemptAt?.isAfter(DateTime.now()) == true) continue;
      try {
        await _execute(item);
        queue = queue.where((q) => q.id != item.id).toList();
        await local.deleteQueue(item.id);
      } catch (error) {
        final retry = item.retry(DateTime.now());
        queue = queue.map((q) => q.id == item.id ? retry : q).toList();
        await local.saveQueue(retry);
        final wait = retry.nextAttemptAt!.difference(DateTime.now());
        unawaited(
          Future<void>.delayed(wait.isNegative ? Duration.zero : wait, () {
            if (online && session != null) unawaited(synchronize());
          }),
        );
        if (kDebugMode) {
          debugPrint(
            '[SYNC] ${item.operation.name} retry=${retry.attempts} category=${error.runtimeType}',
          );
        }
        break;
      }
    }
    syncing = false;
    notifyListeners();
  }

  Future<void> _execute(SyncQueueItem item) async {
    final s = survey(item.surveyId);
    switch (item.operation) {
      case QueueOperation.ensureProfile:
        await remote.profile();
      case QueueOperation.createSurvey:
        final result = await remote.createSurvey(s);
        if (result['duplicateAdvisory'] == true) {
          await _replaceSurvey(s.copyWith(syncState: SyncState.requiresReview));
          message =
              'El identificador también existe en el servidor; revisa la incidencia.';
        } else {
          await _replaceSurvey(s.copyWith(syncState: SyncState.syncing));
        }
      case QueueOperation.openStep:
        await remote.openStep(s.id, item.step!);
      case QueueOperation.updateComment:
        await remote.commentStep(
          s.id,
          item.step!,
          s.steps[item.step! - 1].comment,
        );
      case QueueOperation.uploadPhoto:
        final p = photos.firstWhere((x) => x.id == item.photoId);
        await _replacePhoto(p.copyWith(syncState: PhotoSyncState.uploading));
        await remote.upload(p);
        await _replacePhoto(
          p.copyWith(syncState: PhotoSyncState.uploadedUnverified),
        );
        await _enqueue(
          s.id,
          QueueOperation.verifyPhotos,
          photoId: p.id,
          step: p.stepNumber,
        );
      case QueueOperation.verifyPhotos:
        await _verify(item.photoId!);
      case QueueOperation.completeStep:
        final related = photosForStep(s.id, item.step!);
        if (related.any((p) => p.syncState != PhotoSyncState.confirmed)) {
          throw StateError('EVIDENCE_NOT_SYNCED');
        }
        await remote.completeStep(s.id, item.step!);
        await _replaceSurvey(
          s.copyWith(
            syncState: SyncState.synchronized,
            status: item.step == 6 ? SurveyStatus.executed : s.status,
          ),
        );
      case QueueOperation.completeCorrection:
        final related = photos
            .where((p) => p.correctionId == item.correctionId)
            .toList();
        if (related.any((p) => p.syncState != PhotoSyncState.confirmed)) {
          throw StateError('EVIDENCE_NOT_SYNCED');
        }
        final correction = s.corrections.firstWhere(
          (c) => c.id == item.correctionId,
        );
        await remote.correctionComment(s.id, correction.id, correction.comment);
        await remote.completeCorrection(s.id, item.correctionId!);
    }
  }

  Future<void> _verify(String id) async {
    final p = photos.firstWhere((x) => x.id == id);
    await _replacePhoto(p.copyWith(syncState: PhotoSyncState.verifying));
    final raw = await remote.verify([id]),
        items = raw['items'] as List? ?? raw['results'] as List? ?? const [];
    final row = items.whereType<Map>().cast<Map>().firstWhere(
          (x) => '${x['photoId'] ?? x['photo_id']}' == id,
          orElse: () => {'status': 'not_found'},
        ),
        status = '${row['status'] ?? row['integrityStatus']}';
    final next = switch (status) {
      'confirmed' => PhotoSyncState.confirmed,
      'mapping_conflict' => PhotoSyncState.mappingConflict,
      'deleted' => PhotoSyncState.permanentFailure,
      'missing_original' || 'hash_mismatch' || 'not_found' =>
        File(p.localPath).existsSync()
            ? PhotoSyncState.retryRequired
            : PhotoSyncState.missingLocal,
      _ => PhotoSyncState.retryRequired,
    };
    await _replacePhoto(p.copyWith(syncState: next));
    if (next == PhotoSyncState.retryRequired &&
        const {
          'missing_original',
          'hash_mismatch',
          'not_found',
        }.contains(status)) {
      await _enqueue(
        p.surveyId,
        QueueOperation.uploadPhoto,
        photoId: p.id,
        step: p.stepNumber,
      );
    }
    if (next == PhotoSyncState.retryRequired &&
        const {
          'missing_thumbnail',
          'missing_mapping',
          'not_verified',
        }.contains(status)) {
      throw StateError('PHOTO_VERIFICATION_PENDING');
    }
  }

  Future<void> refreshServer({String? search, String? status}) async {
    if (session == null) return;
    try {
      final rows = await remote.list(
        resident: profile?.role == ConstructionRole.resident,
        search: search,
        status: status,
      );
      for (final row in rows) {
        final id = '${row['survey_id'] ?? row['surveyId']}';
        final index = surveys.indexWhere((s) => s.id == id);
        if (index >= 0) {
          final localSurvey = surveys[index],
              wireStatus = _status('${row['status']}');
          var corrections = localSurvey.corrections;
          if (wireStatus == SurveyStatus.rejected && corrections.isEmpty) {
            final detail = await remote.detail(id);
            corrections = (detail['corrections'] as List? ?? const []).map((
              value,
            ) {
              final correction = Map<String, dynamic>.from(value as Map);
              return CorrectionRound(
                id: '${correction['correction_id']}',
                round: (correction['round_number'] as num).toInt(),
                state: '${correction['status']}' == 'completed'
                    ? StepState.completedServer
                    : StepState.open,
                comment: correction['comment']?.toString(),
              );
            }).toList();
          }
          surveys[index] = localSurvey.copyWith(
            status: wireStatus,
            rejectionReason: row['rejection_reason']?.toString(),
            syncState: localSurvey.syncState == SyncState.requiresReview
                ? SyncState.requiresReview
                : SyncState.synchronized,
            currentStep:
                (row['current_step'] as num?)?.toInt() ??
                localSurvey.currentStep,
            corrections: corrections,
          );
          await local.saveSurvey(surveys[index]);
        } else {
          final now =
              DateTime.tryParse('${row['updated_at'] ?? row['updatedAt']}') ??
              DateTime.now().toUtc();
          final currentStep = (row['current_step'] as num?)?.toInt() ?? 0;
          final remoteSurvey = BaseSurvey(
            id: id,
            displayIdentifier:
                '${row['display_identifier'] ?? row['displayIdentifier']}',
            accountNumber:
                row['account_number']?.toString() ??
                row['accountNumber']?.toString(),
            contractorName:
                '${row['contractor_name'] ?? row['contractorName'] ?? ''}',
            createdAt: DateTime.tryParse('${row['created_at'] ?? ''}') ?? now,
            updatedAt: now,
            status: _status('${row['status']}'),
            localState: currentStep == 6
                ? LocalSurveyState.executedLocal
                : LocalSurveyState.active,
            syncState: SyncState.synchronized,
            currentStep: currentStep,
            steps: List.generate(
              6,
              (i) => SurveyStep(
                number: i + 1,
                state: i < currentStep
                    ? StepState.completedServer
                    : i == currentStep && currentStep < 6
                    ? StepState.open
                    : StepState.locked,
              ),
            ),
            canonicalLocation: row['canonical_latitude'] == null
                ? null
                : GeoPoint(
                    latitude: (row['canonical_latitude'] as num).toDouble(),
                    longitude: (row['canonical_longitude'] as num).toDouble(),
                    accuracy:
                        (row['canonical_accuracy'] as num?)?.toDouble() ?? 100,
                    capturedAt: now,
                  ),
            rejectionReason: row['rejection_reason']?.toString(),
          );
          surveys = [...surveys, remoteSurvey];
          await local.saveSurvey(remoteSurvey);
        }
      }
      online = true;
    } catch (_) {
      online = false;
    }
    notifyListeners();
  }

  SurveyStatus _status(String value) => switch (value) {
    'in_progress' => SurveyStatus.inProgress,
    'executed' => SurveyStatus.executed,
    'rejected' => SurveyStatus.rejected,
    'accepted' => SurveyStatus.accepted,
    'delivered' => SurveyStatus.delivered,
    _ => SurveyStatus.created,
  };
  Future<void> _enqueue(
    String surveyId,
    QueueOperation operation, {
    String? photoId,
    int? step,
    String? correctionId,
  }) async {
    final key =
        '$surveyId-${operation.name}-${photoId ?? step ?? correctionId ?? ''}';
    if (queue.any((q) => q.id == key)) return;
    final item = SyncQueueItem(
      id: key,
      surveyId: surveyId,
      operation: operation,
      createdAt: DateTime.now().toUtc(),
      photoId: photoId,
      step: step,
      correctionId: correctionId,
    );
    queue = [...queue, item];
    await local.saveQueue(item);
    notifyListeners();
  }

  Future<void> _replaceSurvey(BaseSurvey value) async {
    surveys = surveys.map((s) => s.id == value.id ? value : s).toList();
    await local.saveSurvey(value);
    notifyListeners();
  }

  Future<void> _replacePhoto(ConstructionPhoto value) async {
    photos = photos.map((p) => p.id == value.id ? value : p).toList();
    await local.savePhoto(value);
    notifyListeners();
  }
}
