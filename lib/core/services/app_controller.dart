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
import '../identity/uuid_identity.dart';
import '../location/location_service.dart';
import '../media/photo_capture_service.dart';
import '../network/api_client.dart';
import '../persistence/local_store.dart';
import '../persistence/uuid_hive_migration.dart';
import '../security/field_identity.dart';
import '../security/session_store.dart';
import 'construction_sync_scheduler.dart';

class AppController extends ChangeNotifier {
  AppController({
    required this.config,
    required this.local,
    required this.sessions,
    required ApiClient api,
    required this.packageInfo,
    ConstructionRemote? remote,
    LocationService? locations,
    PhotoCaptureService? camera,
  }) : remote = remote ?? ConstructionApi(api, sessions, packageInfo),
       locations = locations ?? LocationService(),
       camera = camera ?? PhotoCaptureService();
  final AppConfig config;
  final LocalStore local;
  final SessionStore sessions;
  final ConstructionRemote remote;
  final PackageInfo packageInfo;
  final LocationService locations;
  final PhotoCaptureService camera;
  FieldSession? session;
  ConstructionProfile? profile;
  List<BaseSurvey> surveys = [];
  List<ConstructionPhoto> photos = [];
  List<SyncQueueItem> queue = [];
  bool busy = false, online = true, syncing = false;
  String? reviewMutationSurveyId;
  String? message;
  String? pendingTakeoverToken;

  bool reviewSubmitting(String surveyId) =>
      reviewMutationSurveyId != null &&
      uuidEquals(reviewMutationSurveyId, surveyId);

  Future<void> acceptSurvey(String surveyId) => _reviewMutation(
    surveyId,
    () => remote.residentAction(surveyId, 'accept'),
    (survey) => survey.copyWith(
      status: SurveyStatus.accepted,
      updatedAt: DateTime.now().toUtc(),
      syncState: SyncState.synchronized,
    ),
  );

  Future<void> rejectSurvey(String surveyId, String reason) {
    final normalized = reason.trim();
    if (normalized.length < 3) {
      throw StateError('El motivo del rechazo es obligatorio.');
    }
    return _reviewMutation(
      surveyId,
      () => remote.residentAction(surveyId, 'reject', {
        'rejectionReason': normalized,
      }),
      (survey) => survey.copyWith(
        status: SurveyStatus.rejected,
        rejectionReason: normalized,
        updatedAt: DateTime.now().toUtc(),
        syncState: SyncState.synchronized,
      ),
    );
  }

  Future<void> deliverSurvey(String surveyId) => _reviewMutation(
    surveyId,
    () => remote.residentAction(surveyId, 'deliver'),
    (survey) => survey.copyWith(
      status: SurveyStatus.delivered,
      updatedAt: DateTime.now().toUtc(),
      syncState: SyncState.synchronized,
    ),
  );

  Future<void> updateSurveyIdentity(
    String surveyId, {
    String? displayIdentifier,
    String? accountNumber,
    bool updateAccount = false,
  }) => _reviewMutation(
    surveyId,
    () => remote.residentUpdate(surveyId, {
      'displayIdentifier': ?displayIdentifier,
      if (updateAccount) 'accountNumber': accountNumber,
    }),
    (survey) => survey.copyWith(
      displayIdentifier: displayIdentifier,
      accountNumber: accountNumber,
      clearAccountNumber: updateAccount && accountNumber == null,
      updatedAt: DateTime.now().toUtc(),
      syncState: SyncState.synchronized,
    ),
  );

  Future<void> correctSurveyCanonicalLocation(
    String surveyId,
    GeoPoint point,
    String reason,
  ) => _reviewMutation(
    surveyId,
    () => remote.correctCanonicalLocation(surveyId, point, reason),
    (survey) => survey.copyWith(
      canonicalLocation: point,
      updatedAt: DateTime.now().toUtc(),
      syncState: SyncState.synchronized,
    ),
  );

  Future<void> _reviewMutation(
    String surveyId,
    Future<void> Function() request,
    BaseSurvey Function(BaseSurvey) apply,
  ) async {
    final role = profile?.role;
    if (role == null || !role.isReviewer) {
      throw StateError('No tienes permisos para realizar esta acción.');
    }
    if (reviewMutationSurveyId != null) return;
    reviewMutationSurveyId = canonicalUuid(surveyId);
    notifyListeners();
    try {
      await request();
      await _replaceSurvey(apply(survey(surveyId)));
      await refreshServer();
    } on DioException catch (error) {
      final data = error.response?.data;
      final detail = data is Map ? data['detail']?.toString() : null;
      throw StateError(detail ?? 'No fue posible completar la operación.');
    } finally {
      reviewMutationSurveyId = null;
      notifyListeners();
    }
  }

  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Timer? _offlineConnectivityPoll;
  StreamSubscription<LocationFix>? _locationFixes;
  final Map<String, Timer> _locationDeadlines = {};
  int _locationFlowDepth = 0;
  final ConstructionSyncScheduler _scheduler =
      const ConstructionSyncScheduler();

  Future<void> bootstrap() async {
    surveys = local.surveys();
    photos = local.photos();
    queue = local.queue();
    profile = local.profile();
    session = await sessions.read();
    await _recoverPendingLocations();
    final connectivity = Connectivity();
    _setConnectivity(await connectivity.checkConnectivity());
    _connectivity = connectivity.onConnectivityChanged.listen(_setConnectivity);
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

  void _setConnectivity(List<ConnectivityResult> values) {
    final wasOnline = online;
    online = values.any((result) => result != ConnectivityResult.none);
    if (online) {
      _offlineConnectivityPoll?.cancel();
      _offlineConnectivityPoll = null;
    } else {
      _startOfflineConnectivityPoll();
    }
    notifyListeners();
    if (online && session != null && (!wasOnline || queue.isNotEmpty)) {
      unawaited(synchronize());
    }
  }

  void _startOfflineConnectivityPoll() {
    _offlineConnectivityPoll ??= Timer.periodic(const Duration(seconds: 3), (
      _,
    ) async {
      try {
        final values = await Connectivity().checkConnectivity();
        if (values.any((result) => result != ConnectivityResult.none)) {
          _setConnectivity(values);
        }
      } catch (_) {
        // The next tick retries; queue and offline capture remain untouched.
      }
    });
  }

  @override
  void dispose() {
    _connectivity?.cancel();
    _offlineConnectivityPoll?.cancel();
    _locationFixes?.cancel();
    for (final timer in _locationDeadlines.values) {
      timer.cancel();
    }
    unawaited(locations.dispose());
    super.dispose();
  }

  void enterLocationFlow() {
    _locationFlowDepth++;
    _ensureLocationListener();
    unawaited(locations.startPrewarm());
  }

  void leaveLocationFlow() {
    _locationFlowDepth = (_locationFlowDepth - 1).clamp(0, 1000);
    if (_locationFlowDepth == 0 &&
        !photos.any((photo) => photo.locationPending)) {
      unawaited(locations.stopPrewarm());
    }
  }

  void _ensureLocationListener() {
    _locationFixes ??= locations.fixes.listen((_) {
      unawaited(_applyBufferedFixes());
    });
  }

  Future<String?> login({
    required String name,
    required String email,
    required String phone,
  }) async {
    busy = true;
    message = null;
    pendingTakeoverToken = null;
    notifyListeners();
    try {
      final identity = FieldIdentity(name: name, email: email, phone: phone);
      final validation = identity.validate();
      if (validation != null) return validation;
      session = await remote.fieldLogin(
        name: identity.normalizedName,
        email: identity.normalizedEmail,
        phone: identity.normalizedPhone,
      );
      try {
        profile = await remote.profile();
        await local.saveProfile(profile!);
      } catch (_) {
        final incomplete = session;
        if (incomplete != null) {
          await remote.logout(incomplete).catchError((_) {});
        }
        await sessions.clear();
        session = null;
        rethrow;
      }
      online = true;
      if (profile!.role.isReviewer) unawaited(refreshServer());
      return null;
    } on DioException catch (error) {
      final data = error.response?.data;
      if (error.response?.statusCode == 409 && data is Map) {
        pendingTakeoverToken = data['takeoverToken']?.toString();
        return pendingTakeoverToken == null
            ? 'La sesión ya está activa.'
            : 'Tu usuario está activo en otro dispositivo.';
      }
      return fieldLoginErrorMessage(error);
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

  Future<BaseSurvey> createSurvey(
    String identifier, {
    String? accountNumber,
  }) async {
    final clean = identifier.trim().replaceAll(RegExp(r'\s+'), ' ');
    final cleanAccount = accountNumber?.trim();
    if (clean.isEmpty) throw StateError('El identificador es obligatorio.');
    if (duplicateKnown(clean)) {
      throw StateError(
        'Ya existe un levantamiento propio con ese identificador.',
      );
    }
    final now = DateTime.now().toUtc();
    final survey = BaseSurvey(
      id: canonicalUuid(const Uuid().v4()),
      displayIdentifier: clean,
      accountNumber: cleanAccount == null || cleanAccount.isEmpty
          ? null
          : cleanAccount,
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

  BaseSurvey survey(String id) =>
      surveys.firstWhere((s) => uuidEquals(s.id, id));
  List<ConstructionPhoto> photosForStep(String surveyId, int step) => photos
      .where(
        (p) =>
            uuidEquals(p.surveyId, surveyId) &&
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

  Future<void> capturePhoto(
    String surveyId,
    int step, {
    PhotoPurpose? purpose,
  }) async {
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
    if (step == 6 && purpose == null) {
      throw StateError('Selecciona la dirección de la fotografía.');
    }
    if (purpose != null &&
        purpose != PhotoPurpose.additional &&
        existing.any((photo) => photo.purpose == purpose)) {
      throw StateError(
        'Ya existe la fotografía ${photoPurposeLabel(purpose)}.',
      );
    }
    final pending = await camera.capture(
      surveyId: surveyId,
      step: step,
      purpose: purpose,
    );
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
    _beginLocationAcquisition(pending.id);
  }

  void _beginLocationAcquisition(String photoId) {
    _ensureLocationListener();
    unawaited(locations.startPrewarm());
    unawaited(_considerBestFix(photoId));
    _scheduleLocationDeadline(photoId);
  }

  Future<void> _recoverPendingLocations() async {
    _ensureLocationListener();
    final now = DateTime.now().toUtc();
    for (final photo in [...photos]) {
      if (!photo.locationPending) continue;
      final expires = photo.capturedAt.add(
        LocationEvidencePolicy.postCaptureWindow,
      );
      if (!now.isBefore(expires)) {
        await _finalizeLocationWindow(photo.id);
      } else {
        _scheduleLocationDeadline(photo.id);
      }
    }
    if (photos.any((photo) => photo.locationPending)) {
      unawaited(locations.startPrewarm());
    }
  }

  Future<void> _applyBufferedFixes() async {
    for (final photo in [...photos].where((item) => item.locationPending)) {
      await _considerBestFix(photo.id);
    }
  }

  Future<void> _considerBestFix(String photoId) async {
    final photo = photos
        .where((item) => uuidEquals(item.id, photoId))
        .firstOrNull;
    if (photo == null || !photo.locationPending) return;
    final s = survey(photo.surveyId);
    final neighbors = photos
        .where(
          (item) =>
              uuidEquals(item.surveyId, photo.surveyId) &&
              !uuidEquals(item.id, photo.id) &&
              item.locationConfirmed,
        )
        .map((item) => item.location!)
        .toList();
    final fix = locations.bestFix(
      photo.capturedAt,
      canonicalLocation: s.canonicalLocation,
      neighboringFixes: neighbors,
    );
    if (fix == null) return;
    if (photo.location != null) {
      final previous = LocationFix(
        latitude: photo.location!.latitude,
        longitude: photo.location!.longitude,
        horizontalAccuracy: photo.location!.accuracy,
        altitude: photo.location!.altitude,
        timestamp: photo.locationFixAt ?? photo.location!.capturedAt,
        acquiredAt: photo.locationAcquiredAt ?? photo.location!.capturedAt,
        isMocked: photo.locationIntegrityFlag == LocationIntegrityFlag.mocked,
      );
      if (scoreLocationFix(
            previous,
            photo.capturedAt,
            canonicalLocation: s.canonicalLocation,
            neighboringFixes: neighbors,
          ) <=
          scoreLocationFix(
            fix,
            photo.capturedAt,
            canonicalLocation: s.canonicalLocation,
            neighboringFixes: neighbors,
          )) {
        return;
      }
    }
    final early = canEarlyAcceptLocationFix(fix, photo.capturedAt);
    await _applyLocationFix(
      photo,
      fix,
      early ? PhotoLocationState.confirmed : PhotoLocationState.provisional,
      s.canonicalLocation,
    );
  }

  Future<void> _applyLocationFix(
    ConstructionPhoto photo,
    LocationFix fix,
    PhotoLocationState state,
    GeoPoint? canonical,
  ) async {
    final consistency = locationConsistency(fix, canonical);
    final updated = photo.copyWith(
      location: fix.toGeoPoint(),
      locationState: state,
      locationFixAt: fix.timestamp,
      locationAcquiredAt: fix.acquiredAt,
      locationAltitudeAccuracy: fix.altitudeAccuracy,
      locationHeading: fix.heading,
      locationSpeed: fix.speed,
      locationSource: fix.source,
      locationTemporalDeltaMs: fix.ageAt(photo.capturedAt).inMilliseconds,
      locationConfidence: locationConfidence(fix.horizontalAccuracy),
      locationDistanceToCanonical: canonical == null
          ? null
          : distanceBetweenFixAndPoint(fix, canonical),
      locationConsistency: consistency,
      locationIntegrityFlag: fix.isMocked
          ? LocationIntegrityFlag.mocked
          : LocationIntegrityFlag.none,
      syncState: state == PhotoLocationState.confirmed
          ? PhotoSyncState.queued
          : photo.syncState,
    );
    await _replacePhoto(updated);
    if (state == PhotoLocationState.confirmed) {
      _locationDeadlines.remove(photo.id)?.cancel();
      final s = survey(photo.surveyId);
      if (photo.stepNumber == 1 && s.canonicalLocation == null) {
        await _replaceSurvey(s.copyWith(canonicalLocation: updated.location));
      }
      await _enqueue(
        photo.surveyId,
        QueueOperation.uploadPhoto,
        photoId: photo.id,
        step: photo.stepNumber,
      );
    }
  }

  void _scheduleLocationDeadline(String photoId) {
    _locationDeadlines.remove(photoId)?.cancel();
    final photo = photos
        .where((item) => uuidEquals(item.id, photoId))
        .firstOrNull;
    if (photo == null || !photo.locationPending) return;
    final wait = photo.capturedAt
        .add(LocationEvidencePolicy.postCaptureWindow)
        .difference(DateTime.now().toUtc());
    _locationDeadlines[photo.id] = Timer(
      wait.isNegative ? Duration.zero : wait,
      () => unawaited(_finalizeLocationWindow(photo.id)),
    );
  }

  Future<void> _finalizeLocationWindow(String photoId) async {
    final photo = photos
        .where((item) => uuidEquals(item.id, photoId))
        .firstOrNull;
    if (photo == null || !photo.locationPending) return;
    await _considerBestFix(photo.id);
    final latest = photos.where((item) => uuidEquals(item.id, photo.id)).first;
    if (latest.location != null &&
        latest.locationState == PhotoLocationState.provisional) {
      final fix = LocationFix(
        latitude: latest.location!.latitude,
        longitude: latest.location!.longitude,
        horizontalAccuracy: latest.location!.accuracy,
        altitude: latest.location!.altitude,
        altitudeAccuracy: latest.locationAltitudeAccuracy,
        heading: latest.locationHeading,
        speed: latest.locationSpeed,
        timestamp: latest.locationFixAt ?? latest.location!.capturedAt,
        acquiredAt: latest.locationAcquiredAt ?? latest.location!.capturedAt,
        source: latest.locationSource,
        isMocked: latest.locationIntegrityFlag == LocationIntegrityFlag.mocked,
      );
      await _applyLocationFix(
        latest,
        fix,
        PhotoLocationState.confirmed,
        survey(latest.surveyId).canonicalLocation,
      );
    } else {
      await _replacePhoto(
        latest.copyWith(locationState: PhotoLocationState.unresolved),
      );
    }
    _locationDeadlines.remove(photo.id)?.cancel();
  }

  Future<void> deletePhoto(String surveyId, int step, String photoId) async {
    final s = survey(surveyId), current = s.steps[step - 1];
    if (current.state != StepState.open) {
      throw StateError('La evidencia finalizada es inmutable.');
    }
    final photo = photos.firstWhere((p) => uuidEquals(p.id, photoId));
    final needsRemoteDelete = const {
      PhotoSyncState.uploadedUnverified,
      PhotoSyncState.verifying,
      PhotoSyncState.confirmed,
      PhotoSyncState.retryRequired,
      PhotoSyncState.mappingConflict,
    }.contains(photo.syncState);
    final photoQueue = queue
        .where((item) => uuidEquals(item.photoId, photoId))
        .toList();
    for (final item in photoQueue) {
      await local.deleteQueue(item.id);
    }
    queue = queue.where((item) => !uuidEquals(item.photoId, photoId)).toList();
    await File(
      photo.localPath,
    ).delete().catchError((_) => File(photo.localPath));
    await File(
      photo.thumbnailPath,
    ).delete().catchError((_) => File(photo.thumbnailPath));
    photos = photos.where((p) => !uuidEquals(p.id, photoId)).toList();
    await local.deletePhoto(canonicalUuid(photoId));
    final steps = [...s.steps];
    steps[step - 1] = current.copyWith(
      photoIds: current.photoIds
          .where((id) => !uuidEquals(id, photoId))
          .toList(),
    );
    await _replaceSurvey(s.copyWith(steps: steps));
    if (needsRemoteDelete) {
      await _enqueue(
        surveyId,
        QueueOperation.deletePhoto,
        photoId: photoId,
        step: step,
      );
    }
  }

  bool canFinalize(String surveyId, int step) {
    final s = survey(surveyId),
        current = s.steps[step - 1],
        evidence = photosForStep(surveyId, step);
    final hasCardinals =
        step != 6 ||
        cardinalPhotoPurposes.every(
          (purpose) => evidence.any((photo) => photo.purpose == purpose),
        );
    return current.state == StepState.open &&
        evidence.length >= current.minimumPhotos &&
        hasCardinals &&
        (current.maximumPhotos == null ||
            evidence.length <= current.maximumPhotos!) &&
        evidence.every(
          (p) =>
              p.locationConfirmed &&
              File(p.localPath).existsSync() &&
              p.sha256.length == 64,
        );
  }

  bool canAttemptFinalize(String surveyId, int step) {
    final s = survey(surveyId), evidence = photosForStep(surveyId, step);
    return s.steps[step - 1].state == StepState.open &&
        evidence.length >= s.steps[step - 1].minimumPhotos;
  }

  Future<void> finalizeStep(String surveyId, int step) async {
    for (final photo in photosForStep(
      surveyId,
      step,
    ).where((item) => item.locationState == PhotoLocationState.provisional)) {
      await _finalizeLocationWindow(photo.id);
    }
    if (!canFinalize(surveyId, step)) {
      final unresolved = photosForStep(
        surveyId,
        step,
      ).any((photo) => photo.locationUnresolved);
      throw StateError(
        unresolved
            ? 'No fue posible registrar una ubicación válida para una fotografía. Permanece en el sitio y vuelve a tomar esa evidencia.'
            : 'La ubicación de una fotografía sigue pendiente. Permanece en el sitio antes de finalizar.',
      );
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
    surveyId = canonicalUuid(surveyId);
    correctionId = canonicalUuid(correctionId);
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
            uuidEquals(p.correctionId, correctionId) &&
            p.syncState != PhotoSyncState.deleted,
      )
      .toList();

  Future<void> captureCorrectionPhoto(
    String surveyId,
    String correctionId,
  ) async {
    final s = survey(surveyId);
    final correction = s.corrections.firstWhere(
      (c) => uuidEquals(c.id, correctionId),
    );
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
          (c) => uuidEquals(c.id, correctionId)
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
    _beginLocationAcquisition(pending.id);
  }

  Future<void> finalizeCorrection(String surveyId, String correctionId) async {
    final related = photos
        .where((p) => uuidEquals(p.correctionId, correctionId))
        .toList();
    if (related.isEmpty || related.any((p) => !p.locationConfirmed)) {
      throw StateError('La corrección requiere foto con GPS.');
    }
    final s = survey(surveyId);
    final corrections = s.corrections
        .map(
          (c) => uuidEquals(c.id, correctionId)
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
              (c) => uuidEquals(c.id, correctionId)
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

  Future<void> synchronize({bool force = false}) async {
    if (syncing || session == null || (!online && !force)) return;
    if (force && !online) {
      online = true;
      notifyListeners();
    }
    if (force) {
      final delayed = queue
          .where((item) => item.nextAttemptAt != null)
          .toList();
      if (delayed.isNotEmpty) {
        queue = queue
            .map(
              (item) => item.nextAttemptAt == null
                  ? item
                  : item.copyWith(clearNextAttempt: true),
            )
            .toList();
        for (final item in queue.where(
          (candidate) => delayed.any((previous) => previous.id == candidate.id),
        )) {
          await local.saveQueue(item);
        }
      }
    }
    syncing = true;
    notifyListeners();
    try {
      try {
        await _reconcilePendingSurveys();
      } catch (error) {
        if (error is DioException && error.response?.statusCode != 401) {
          online = false;
        }
        if (kDebugMode) {
          debugPrint(
            '[SYNC] reconciliation classification=global category=${error.runtimeType}',
          );
        }
        return;
      }
      while (online && queue.isNotEmpty) {
        final ready = _scheduler.readyRound(queue, photos, DateTime.now());
        if (ready.isEmpty) {
          _logBlockedQueue(DateTime.now());
          break;
        }
        var progressed = false;
        for (final selected in ready) {
          final item = queue.where((q) => q.id == selected.id).firstOrNull;
          if (item == null) continue;
          try {
            _logQueue(item, ready: true);
            await _execute(item);
            await _removeQueueItem(item);
            progressed = true;
          } catch (error) {
            if (_isGlobalSyncError(error)) {
              if (error is DioException && error.response?.statusCode != 401) {
                online = false;
              }
              await _recordRetry(item, error, global: true);
              return;
            }
            await _recordRetry(
              item,
              error,
              dependency: _isDependencyResponse(error),
            );
          }
        }
        if (!progressed &&
            _scheduler.readyRound(queue, photos, DateTime.now()).isEmpty) {
          _logBlockedQueue(DateTime.now());
          break;
        }
      }
    } finally {
      syncing = false;
      _scheduleNextAttempt();
      notifyListeners();
    }
  }

  Future<void> _reconcilePendingSurveys() async {
    final surveyIds = queue.map((item) => canonicalUuid(item.surveyId)).toSet();
    for (final surveyId in surveyIds) {
      Map<String, dynamic> detail;
      try {
        detail = await remote.detail(surveyId);
      } on DioException catch (error) {
        if (error.response?.statusCode == 404) continue;
        if (_isGlobalSyncError(error)) rethrow;
        continue;
      } catch (_) {
        continue;
      }
      final steps = (detail['steps'] as List? ?? const [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      final serverPhotos = (detail['photos'] as List? ?? const [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      final corrections = (detail['corrections'] as List? ?? const [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      final satisfied = <SyncQueueItem>[];
      for (final item in queue.where(
        (candidate) => uuidEquals(candidate.surveyId, surveyId),
      )) {
        var done = item.operation == QueueOperation.createSurvey;
        if (item.operation == QueueOperation.openStep) {
          done = steps.any(
            (row) => (row['step_number'] as num?)?.toInt() == item.step,
          );
        }
        if (item.operation == QueueOperation.completeStep) {
          done = steps.any(
            (row) =>
                (row['step_number'] as num?)?.toInt() == item.step &&
                '${row['status']}' == 'completed',
          );
        }
        if (item.operation == QueueOperation.uploadPhoto ||
            item.operation == QueueOperation.verifyPhotos) {
          final row = serverPhotos
              .where(
                (candidate) => uuidEquals(
                  '${candidate['photo_id'] ?? candidate['photoId']}',
                  item.photoId,
                ),
              )
              .firstOrNull;
          if (row != null) {
            final confirmed = '${row['integrity_status']}' == 'confirmed';
            if (item.operation == QueueOperation.uploadPhoto || confirmed) {
              done = true;
            }
            final localPhoto = photos
                .where((photo) => uuidEquals(photo.id, item.photoId))
                .firstOrNull;
            if (localPhoto != null) {
              await _replacePhoto(
                localPhoto.copyWith(
                  syncState: confirmed
                      ? PhotoSyncState.confirmed
                      : PhotoSyncState.uploadedUnverified,
                ),
              );
            }
          }
        }
        if (item.operation == QueueOperation.completeCorrection) {
          done = corrections.any(
            (row) =>
                uuidEquals('${row['correction_id']}', item.correctionId) &&
                '${row['status']}' == 'completed',
          );
        }
        if (done) satisfied.add(item);
      }
      for (final item in satisfied) {
        await _removeQueueItem(item);
      }
    }
  }

  Future<void> _removeQueueItem(SyncQueueItem item) async {
    queue = queue.where((candidate) => candidate.id != item.id).toList();
    await local.deleteQueue(item.id);
    if (!queue.any(
      (candidate) => uuidEquals(candidate.surveyId, item.surveyId),
    )) {
      final current = surveys
          .where((survey) => uuidEquals(survey.id, item.surveyId))
          .firstOrNull;
      if (current != null && current.syncState != SyncState.requiresReview) {
        await _replaceSurvey(
          current.copyWith(syncState: SyncState.synchronized),
        );
      }
    }
  }

  Future<void> _recordRetry(
    SyncQueueItem item,
    Object error, {
    bool dependency = false,
    bool global = false,
  }) async {
    final localDependency = dependency && _hasPendingLocalPrerequisite(item);
    final retry = localDependency
        ? item.copyWith(
            nextAttemptAt: DateTime.now().add(const Duration(seconds: 2)),
          )
        : item.retry(DateTime.now());
    queue = queue
        .map((candidate) => candidate.id == item.id ? retry : candidate)
        .toList();
    await local.saveQueue(retry);
    if (kDebugMode) {
      final response = error is DioException ? error.response : null;
      final data = response?.data;
      final code = data is Map ? data['code'] : null;
      debugPrint(
        '[SYNC] survey=${canonicalUuid(item.surveyId)} operation=${item.operation.name} '
        'step=${item.step ?? '-'} ready=true retry=${retry.attempts} '
        'classification=${dependency
            ? 'dependency'
            : global
            ? 'global'
            : 'operation'} '
        'category=${error.runtimeType} status=${response?.statusCode ?? '-'} '
        'code=${code ?? '-'} localDependency=$localDependency',
      );
    }
  }

  bool _hasPendingLocalPrerequisite(SyncQueueItem item) {
    if (item.operation == QueueOperation.openStep &&
        item.step != null &&
        item.step! > 1) {
      return queue.any(
        (candidate) =>
            uuidEquals(candidate.surveyId, item.surveyId) &&
            candidate.operation == QueueOperation.completeStep &&
            candidate.step == item.step! - 1,
      );
    }
    return false;
  }

  bool _isDependencyResponse(Object error) {
    if (error is StateError &&
        error.message.toString().contains('EVIDENCE_NOT_SYNCED')) {
      return true;
    }
    if (error is! DioException || error.response?.statusCode != 409) {
      return false;
    }
    final data = error.response?.data;
    final code = data is Map ? '${data['code']}' : '';
    return const {'STEP_SEQUENCE', 'EVIDENCE_NOT_SYNCED'}.contains(code);
  }

  bool _isGlobalSyncError(Object error) {
    if (error is! DioException) return false;
    if (error.response?.statusCode == 401) return true;
    return const {
      DioExceptionType.connectionError,
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.badCertificate,
    }.contains(error.type);
  }

  void _scheduleNextAttempt() {
    final next = queue
        .map((item) => item.nextAttemptAt)
        .whereType<DateTime>()
        .where((date) => date.isAfter(DateTime.now()))
        .fold<DateTime?>(
          null,
          (earliest, date) =>
              earliest == null || date.isBefore(earliest) ? date : earliest,
        );
    if (next == null || !online || session == null) return;
    final wait = next.difference(DateTime.now());
    unawaited(
      Future<void>.delayed(wait, () {
        if (online && session != null) unawaited(synchronize());
      }),
    );
  }

  void _logBlockedQueue(DateTime now) {
    if (!kDebugMode) return;
    for (final item in queue) {
      final state = _scheduler.readiness(item, queue, photos, now);
      if (!state.isReady) {
        _logQueue(item, ready: false, dependency: state.dependency);
      }
    }
  }

  void _logQueue(
    SyncQueueItem item, {
    required bool ready,
    String? dependency,
  }) {
    if (!kDebugMode) return;
    debugPrint(
      '[SYNC] survey=${canonicalUuid(item.surveyId)} operation=${item.operation.name} '
      'step=${item.step ?? '-'} ready=$ready dependency=${dependency ?? '-'}',
    );
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
      case QueueOperation.deletePhoto:
        await remote.deletePhoto(s.id, item.photoId!);
      case QueueOperation.updateComment:
        await remote.commentStep(
          s.id,
          item.step!,
          s.steps[item.step! - 1].comment,
        );
      case QueueOperation.uploadPhoto:
        final p = photos.firstWhere((x) => uuidEquals(x.id, item.photoId));
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
            .where((p) => uuidEquals(p.correctionId, item.correctionId))
            .toList();
        if (related.any((p) => p.syncState != PhotoSyncState.confirmed)) {
          throw StateError('EVIDENCE_NOT_SYNCED');
        }
        final correction = s.corrections.firstWhere(
          (c) => uuidEquals(c.id, item.correctionId),
        );
        await remote.correctionComment(s.id, correction.id, correction.comment);
        await remote.completeCorrection(s.id, item.correctionId!);
    }
  }

  Future<void> _verify(String id) async {
    final p = photos.firstWhere((x) => uuidEquals(x.id, id));
    await _replacePhoto(p.copyWith(syncState: PhotoSyncState.verifying));
    final raw = await remote.verify([id]),
        items = raw['items'] as List? ?? raw['results'] as List? ?? const [];
    final row = items.whereType<Map>().cast<Map>().firstWhere(
          (x) => uuidEquals('${x['photoId'] ?? x['photo_id']}', id),
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
        resident: profile?.role.isReviewer ?? false,
        search: search,
        status: status,
      );
      for (final row in rows) {
        final id = canonicalUuid('${row['survey_id'] ?? row['surveyId']}');
        final index = surveys.indexWhere((s) => uuidEquals(s.id, id));
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
                id: canonicalUuid('${correction['correction_id']}'),
                round: (correction['round_number'] as num).toInt(),
                state: '${correction['status']}' == 'completed'
                    ? StepState.completedServer
                    : StepState.open,
                comment: correction['comment']?.toString(),
              );
            }).toList();
          }
          surveys[index] = localSurvey.copyWith(
            accountNumber: mergeAccountNumber(localSurvey.accountNumber, row),
            contractorName:
                '${row['contractor_name'] ?? row['contractorName'] ?? localSurvey.contractorName}',
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
    final normalized = SyncQueueItem(
      id: '',
      surveyId: canonicalUuid(surveyId),
      operation: operation,
      createdAt: DateTime.now().toUtc(),
      photoId: canonicalUuidOrNull(photoId),
      step: step,
      correctionId: canonicalUuidOrNull(correctionId),
    );
    final key = canonicalQueueItemId(normalized);
    if (queue.any((q) => q.id == key)) return;
    final item = SyncQueueItem(
      id: key,
      surveyId: normalized.surveyId,
      operation: operation,
      createdAt: DateTime.now().toUtc(),
      photoId: normalized.photoId,
      step: step,
      correctionId: normalized.correctionId,
    );
    queue = [...queue, item];
    await local.saveQueue(item);
    notifyListeners();
  }

  Future<void> _replaceSurvey(BaseSurvey value) async {
    surveys = surveys
        .map((s) => uuidEquals(s.id, value.id) ? value : s)
        .toList();
    await local.saveSurvey(value);
    notifyListeners();
  }

  Future<void> _replacePhoto(ConstructionPhoto value) async {
    photos = photos.map((p) => uuidEquals(p.id, value.id) ? value : p).toList();
    await local.savePhoto(value);
    notifyListeners();
  }
}

String? mergeAccountNumber(
  String? localAccount,
  Map<String, dynamic> serverRow,
) =>
    serverRow['account_number']?.toString() ??
    serverRow['accountNumber']?.toString() ??
    localAccount;
