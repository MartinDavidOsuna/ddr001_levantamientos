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
import '../persistence/construction_operation_journal.dart';
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
       camera = camera ?? PhotoCaptureService(local: local);
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
  bool transportAvailable = true;
  bool apiReachable = true;
  bool get degraded => transportAvailable && !apiReachable;
  int get unownedPendingCount => queue
      .where((item) => _surveyAny(item.surveyId)?.contractorUserId == null)
      .length;
  String? reviewMutationSurveyId;
  String? message;
  String? pendingTakeoverToken;
  final Map<String, Uint8List> _remotePhotoBytes = {};

  String? get currentUserId => canonicalUuidOrNull(
    profile?.userId.isNotEmpty == true ? profile!.userId : session?.userId,
  );
  String? get currentCrewId =>
      canonicalUuidOrNull(profile?.crewId ?? session?.crewId);
  String get currentCrew =>
      (profile?.crew.isNotEmpty == true ? profile!.crew : session?.crew ?? '')
          .trim();

  bool get canViewAllSurveys => profile?.role.canViewAllSurveys ?? false;

  bool canCurrentSessionViewSurvey(BaseSurvey value) {
    if (session == null) return false;
    if (canViewAllSurveys) return true;
    final owner = canonicalUuidOrNull(value.contractorUserId);
    final user = currentUserId;
    if (value.localState == LocalSurveyState.createdLocal) {
      return owner != null && user != null && uuidEquals(owner, user);
    }
    final surveyCrewId = canonicalUuidOrNull(value.crewId);
    final sessionCrewId = currentCrewId;
    if (surveyCrewId != null && sessionCrewId != null) {
      return uuidEquals(surveyCrewId, sessionCrewId);
    }
    final surveyCrew = value.crew?.trim() ?? '';
    if (surveyCrew.isNotEmpty && currentCrew.isNotEmpty) {
      return surveyCrew == currentCrew;
    }
    return owner != null && user != null && uuidEquals(owner, user);
  }

  bool canCurrentSessionViewSurveyId(String surveyId) {
    final value = _surveyAny(surveyId);
    return value != null && canCurrentSessionViewSurvey(value);
  }

  List<BaseSurvey> get visibleSurveys =>
      surveys.where(canCurrentSessionViewSurvey).toList(growable: false);

  bool _queueBelongsToCurrentActor(SyncQueueItem item) {
    final actor = canonicalUuidOrNull(item.actorUserId);
    final user = currentUserId;
    if (actor != null && user != null) return uuidEquals(actor, user);
    final survey = _surveyAny(item.surveyId);
    final legacyOwner = canonicalUuidOrNull(survey?.contractorUserId);
    return legacyOwner != null && user != null && uuidEquals(legacyOwner, user);
  }

  bool _queueTransferableByCompany(SyncQueueItem item) =>
      item.operation == QueueOperation.verifyPhotos &&
      canCurrentSessionViewSurveyId(item.surveyId);

  List<SyncQueueItem> get visibleQueue => (profile?.role.isReviewer ?? false)
      ? const []
      : queue
            .where(
              (item) =>
                  _queueBelongsToCurrentActor(item) ||
                  _queueTransferableByCompany(item),
            )
            .toList(growable: false);

  List<SyncQueueItem> get _eligibleQueue {
    if (profile?.role.isReviewer ?? false) return const [];
    return visibleQueue;
  }

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
  Timer? _nextAttemptTimer;
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
    await recoverLocalState();
    await _recoverPendingLocations();
    final connectivity = Connectivity();
    _setConnectivity(await connectivity.checkConnectivity());
    _connectivity = connectivity.onConnectivityChanged.listen(_setConnectivity);
    if (session != null) {
      try {
        profile = await remote.profile();
        await _adoptProfileCrew();
        await local.saveProfile(profile!);
        _reportUnownedPendingWork();
        online = true;
        unawaited(refreshServer());
        unawaited(synchronize());
      } catch (_) {
        online = false;
      }
    }
  }

  Future<void> recoverLocalState({bool recoverCamera = true}) async {
    for (final deletion in local.journal.pending().where(
      (entry) => entry.operation == ConstructionJournalOperation.deletePhoto,
    )) {
      final photo = photos
          .where((value) => uuidEquals(value.id, deletion.photoId))
          .firstOrNull;
      if (photo != null && photo.syncState != PhotoSyncState.deleted) {
        await _replacePhoto(photo.copyWith(syncState: PhotoSyncState.deleted));
      }
      await _unlinkDeletedPhoto(deletion);
      if (deletion.remotePossible) {
        await _enqueue(
          deletion.surveyId,
          QueueOperation.deletePhoto,
          photoId: deletion.photoId,
          step: deletion.step,
          correctionId: deletion.correctionId,
        );
      } else {
        await _purgeDeletedPhoto(deletion);
      }
    }
    final recovered = recoverCamera
        ? await camera.recoverPendingCaptures()
        : const <ConstructionPhoto>[];
    for (final candidate in recovered) {
      var photo = photos
          .where((value) => uuidEquals(value.id, candidate.id))
          .firstOrNull;
      if (photo == null) {
        photo = candidate;
        photos = [...photos, photo];
        await local.savePhoto(photo);
        await camera.advance(
          photo.id,
          ConstructionJournalState.metadataPersisted,
        );
      }
      await _repairPhotoLink(photo);
    }

    // Older builds opened the next stage only in the local projection. Repair
    // the durable causal commands so later evidence cannot be stranded behind
    // a server-side "Evidence context not found" response.
    for (final survey in [...surveys]) {
      for (final step in survey.steps.where(
        (candidate) => candidate.state == StepState.completedLocal,
      )) {
        await _enqueue(survey.id, QueueOperation.openStep, step: step.number);
        await _enqueue(
          survey.id,
          QueueOperation.completeStep,
          step: step.number,
        );
        if (step.number < survey.steps.length) {
          await _enqueue(
            survey.id,
            QueueOperation.openStep,
            step: step.number + 1,
          );
        }
      }
    }

    for (final original in [...photos]) {
      var photo = original;
      if (photo.syncState == PhotoSyncState.deleted) continue;
      if (!File(photo.localPath).existsSync()) {
        photo = photo.copyWith(syncState: PhotoSyncState.missingLocal);
        await _replacePhoto(photo);
        continue;
      }
      if (photo.syncState == PhotoSyncState.uploading) {
        photo = photo.copyWith(syncState: PhotoSyncState.retryRequired);
        await _replacePhoto(photo);
      } else if (photo.syncState == PhotoSyncState.verifying) {
        photo = photo.copyWith(syncState: PhotoSyncState.uploadedUnverified);
        await _replacePhoto(photo);
      }
      await _repairPhotoLink(photo);
      if (photo.syncState == PhotoSyncState.uploadedUnverified) {
        await _enqueue(
          photo.surveyId,
          QueueOperation.verifyPhotos,
          photoId: photo.id,
          step: photo.stepNumber,
          correctionId: photo.correctionId,
        );
      } else if (photo.locationConfirmed &&
          const {
            PhotoSyncState.localOnly,
            PhotoSyncState.queued,
            PhotoSyncState.retryRequired,
          }.contains(photo.syncState)) {
        await _enqueue(
          photo.surveyId,
          QueueOperation.uploadPhoto,
          photoId: photo.id,
          step: photo.stepNumber,
          correctionId: photo.correctionId,
        );
      }
    }
  }

  Future<void> _repairPhotoLink(ConstructionPhoto photo) async {
    final index = surveys.indexWhere(
      (value) => uuidEquals(value.id, photo.surveyId),
    );
    if (index < 0) return;
    final current = surveys[index];
    if (photo.correctionId != null) {
      final correctionIndex = current.corrections.indexWhere(
        (value) => uuidEquals(value.id, photo.correctionId),
      );
      if (correctionIndex < 0) return;
      final correction = current.corrections[correctionIndex];
      if (!correction.photoIds.any((id) => uuidEquals(id, photo.id))) {
        final corrections = [...current.corrections];
        corrections[correctionIndex] = CorrectionRound(
          id: correction.id,
          round: correction.round,
          state: correction.state,
          comment: correction.comment,
          photoIds: [...correction.photoIds, photo.id],
        );
        await _replaceSurvey(current.copyWith(corrections: corrections));
      }
    } else if (photo.stepNumber != null &&
        photo.stepNumber! >= 1 &&
        photo.stepNumber! <= current.steps.length) {
      final stepIndex = photo.stepNumber! - 1;
      final step = current.steps[stepIndex];
      if (!step.photoIds.any((id) => uuidEquals(id, photo.id))) {
        final steps = [...current.steps];
        steps[stepIndex] = step.copyWith(
          photoIds: [...step.photoIds, photo.id],
        );
        await _replaceSurvey(current.copyWith(steps: steps));
      }
    }
    await camera.advance(photo.id, ConstructionJournalState.linked);
  }

  void _setConnectivity(List<ConnectivityResult> values) {
    final wasOnline = online;
    final previousTransport = transportAvailable;
    transportAvailable = values.any(
      (result) => result != ConnectivityResult.none,
    );
    online = transportAvailable;
    if (transportAvailable) {
      _offlineConnectivityPoll?.cancel();
      _offlineConnectivityPoll = null;
    } else {
      _startOfflineConnectivityPoll();
    }
    if (previousTransport != transportAvailable || wasOnline != online) {
      notifyListeners();
    }
    if (online && session != null && (!wasOnline || queue.isNotEmpty)) {
      unawaited(synchronize());
    }
  }

  void _startOfflineConnectivityPoll() {
    _offlineConnectivityPoll ??= Timer.periodic(const Duration(seconds: 45), (
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
    _nextAttemptTimer?.cancel();
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
    _stopLocationWhenIdle();
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
    required String crew,
  }) async {
    busy = true;
    message = null;
    pendingTakeoverToken = null;
    notifyListeners();
    try {
      final identity = FieldIdentity(
        name: name,
        email: email,
        phone: phone,
        crew: crew,
      );
      final validation = identity.validate();
      if (validation != null) return validation;
      session = await remote.fieldLogin(
        name: identity.normalizedName,
        email: identity.normalizedEmail,
        phone: identity.normalizedPhone,
        crew: identity.normalizedCrew,
      );
      try {
        profile = await remote.profile();
        await _adoptProfileCrew();
        await local.saveProfile(profile!);
        _reportUnownedPendingWork();
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
      unawaited(refreshServer());
      return null;
    } on DioException catch (error) {
      final data = error.response?.data;
      if (error.response?.statusCode == 409 && data is Map) {
        final code = data['code']?.toString();
        final takeoverToken = data['takeoverToken']?.toString();
        if (code == 'SESSION_ALREADY_ACTIVE' && takeoverToken != null) {
          pendingTakeoverToken = takeoverToken;
          return 'Esta instalación necesita recuperar su sesión.';
        }
        if (code == 'COMPANY_MISMATCH' ||
            code == 'COMPANY_OWNERSHIP_CONFLICT') {
          return data['detail']?.toString() ?? fieldLoginErrorMessage(error);
        }
        return 'Los datos de identidad entran en conflicto con otro usuario.';
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

  Future<String?> logout() async {
    final current = session;
    if (current != null) {
      try {
        await remote.logout(current);
      } catch (_) {
        return 'No fue posible cerrar la sesión. Intenta de nuevo.';
      }
    }
    session = null;
    profile = null;
    notifyListeners();
    return null;
  }

  bool duplicateKnown(String identifier) {
    final normalized = normalizeIdentifier(identifier);
    return visibleSurveys.any(
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
      contractorUserId: currentUserId,
      crewId: currentCrewId,
      crew: currentCrew,
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
    await _enqueue(survey.id, QueueOperation.openStep, step: 1);
    notifyListeners();
    return survey;
  }

  BaseSurvey? _surveyAny(String id) =>
      surveys.where((s) => uuidEquals(s.id, id)).firstOrNull;

  BaseSurvey survey(String id) {
    final value = _surveyAny(id);
    if (value == null) throw StateError('Levantamiento no encontrado.');
    if (session != null && !canCurrentSessionViewSurvey(value)) {
      throw StateError('No tienes acceso a este levantamiento.');
    }
    return value;
  }

  List<ConstructionPhoto> photosForStep(String surveyId, int step) => photos
      .where(
        (p) =>
            (session == null || canCurrentSessionViewSurveyId(p.surveyId)) &&
            uuidEquals(p.surveyId, surveyId) &&
            p.stepNumber == step &&
            p.syncState != PhotoSyncState.deleted,
      )
      .toList();

  List<RemoteConstructionPhoto> remotePhotosForStep(String surveyId, int step) {
    if (!canCurrentSessionViewSurveyId(surveyId)) return const [];
    return survey(surveyId).remotePhotos
        .where((photo) => photo.context == 'step' && photo.stepNumber == step)
        .toList(growable: false);
  }

  int photoCountForStep(String surveyId, int step) => {
    ...photosForStep(surveyId, step).map((photo) => canonicalUuid(photo.id)),
    ...remotePhotosForStep(
      surveyId,
      step,
    ).map((photo) => canonicalUuid(photo.id)),
  }.length;

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
    await camera.advance(
      pending.id,
      ConstructionJournalState.metadataPersisted,
    );
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
    await camera.advance(pending.id, ConstructionJournalState.linked);
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
    if (photos.any((photo) => photo.locationPending)) {
      _ensureLocationListener();
    }
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
    } else {
      _stopLocationWhenIdle();
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
      await camera.advance(photo.id, ConstructionJournalState.committed);
      _stopLocationWhenIdle();
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
    _stopLocationWhenIdle();
  }

  void _stopLocationWhenIdle() {
    if (_locationFlowDepth != 0 ||
        photos.any((photo) => photo.locationPending)) {
      return;
    }
    final subscription = _locationFixes;
    _locationFixes = null;
    unawaited(subscription?.cancel());
    unawaited(locations.stopPrewarm());
  }

  Future<void> deletePhoto(String surveyId, int step, String photoId) async {
    final s = survey(surveyId), current = s.steps[step - 1];
    if (current.state != StepState.open) {
      throw StateError('La evidencia finalizada es inmutable.');
    }
    final photo = photos.firstWhere((p) => uuidEquals(p.id, photoId));
    final needsRemoteDelete = const {
      PhotoSyncState.uploading,
      PhotoSyncState.uploadedUnverified,
      PhotoSyncState.verifying,
      PhotoSyncState.confirmed,
      PhotoSyncState.retryRequired,
      PhotoSyncState.mappingConflict,
    }.contains(photo.syncState);
    final captureJournal = local.journal.find(photo.id);
    final deletion = ConstructionJournalEntry(
      id: 'delete-${canonicalUuid(photo.id)}',
      operation: ConstructionJournalOperation.deletePhoto,
      state: ConstructionJournalState.prepared,
      surveyId: canonicalUuid(surveyId),
      photoId: canonicalUuid(photo.id),
      step: step,
      correctionId: photo.correctionId,
      sourcePath: captureJournal?.sourcePath,
      uploadPath: photo.localPath,
      thumbnailPath: photo.thumbnailPath,
      sha256: photo.sha256,
      fileSize: File(photo.localPath).existsSync()
          ? File(photo.localPath).lengthSync()
          : null,
      remotePossible: needsRemoteDelete,
      createdAt: DateTime.now().toUtc(),
    );
    await local.journal.save(deletion);
    final photoQueue = queue
        .where((item) => uuidEquals(item.photoId, photoId))
        .toList();
    for (final item in photoQueue) {
      await local.deleteQueue(item.id);
    }
    queue = queue.where((item) => !uuidEquals(item.photoId, photoId)).toList();
    await _replacePhoto(photo.copyWith(syncState: PhotoSyncState.deleted));
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
      await local.journal.save(
        deletion.copyWith(state: ConstructionJournalState.queued),
      );
    } else {
      await _purgeDeletedPhoto(deletion);
    }
  }

  Future<void> _purgeDeletedPhoto(ConstructionJournalEntry deletion) async {
    for (final path in {
      deletion.sourcePath,
      deletion.uploadPath,
      deletion.thumbnailPath,
    }.whereType<String>()) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    final photoId = deletion.photoId;
    if (photoId != null) {
      photos = photos.where((photo) => !uuidEquals(photo.id, photoId)).toList();
      await local.deletePhoto(photoId);
    }
    await local.journal.save(
      deletion.copyWith(state: ConstructionJournalState.committed),
    );
  }

  Future<void> _unlinkDeletedPhoto(ConstructionJournalEntry deletion) async {
    final surveyIndex = surveys.indexWhere(
      (value) => uuidEquals(value.id, deletion.surveyId),
    );
    final photoId = deletion.photoId;
    if (surveyIndex < 0 || photoId == null) return;
    final current = surveys[surveyIndex];
    if (deletion.correctionId != null) {
      final corrections = current.corrections
          .map(
            (correction) => uuidEquals(correction.id, deletion.correctionId)
                ? CorrectionRound(
                    id: correction.id,
                    round: correction.round,
                    state: correction.state,
                    comment: correction.comment,
                    photoIds: correction.photoIds
                        .where((id) => !uuidEquals(id, photoId))
                        .toList(),
                  )
                : correction,
          )
          .toList();
      await _replaceSurvey(current.copyWith(corrections: corrections));
      return;
    }
    final steps = current.steps
        .map(
          (step) => step.copyWith(
            photoIds: step.photoIds
                .where((id) => !uuidEquals(id, photoId))
                .toList(),
          ),
        )
        .toList();
    await _replaceSurvey(current.copyWith(steps: steps));
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
    if (step < 6) {
      await _enqueue(surveyId, QueueOperation.openStep, step: step + 1);
    }
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
            (session == null || canCurrentSessionViewSurveyId(p.surveyId)) &&
            uuidEquals(p.correctionId, correctionId) &&
            p.syncState != PhotoSyncState.deleted,
      )
      .toList();

  List<RemoteConstructionPhoto> remotePhotosForCorrection(
    String surveyId,
    int correctionRound,
  ) {
    if (!canCurrentSessionViewSurveyId(surveyId)) return const [];
    return survey(surveyId).remotePhotos
        .where(
          (photo) =>
              photo.context == 'correction' &&
              photo.correctionRound == correctionRound,
        )
        .toList(growable: false);
  }

  int photoCountForCorrection(String surveyId, CorrectionRound correction) => {
    ...photosForCorrection(
      correction.id,
    ).map((photo) => canonicalUuid(photo.id)),
    ...remotePhotosForCorrection(
      surveyId,
      correction.round,
    ).map((photo) => canonicalUuid(photo.id)),
  }.length;

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
    await camera.advance(
      pending.id,
      ConstructionJournalState.metadataPersisted,
    );
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
    await camera.advance(pending.id, ConstructionJournalState.linked);
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
    if (profile?.role.isReviewer ?? false) return;
    if (force && !online) {
      online = true;
      notifyListeners();
    }
    if (force) {
      final delayed = _eligibleQueue
          .where((item) => item.nextAttemptAt != null)
          .toList();
      if (delayed.isNotEmpty) {
        final delayedIds = delayed.map((item) => item.id).toSet();
        queue = queue
            .map(
              (item) => delayedIds.contains(item.id)
                  ? item.copyWith(clearNextAttempt: true)
                  : item,
            )
            .toList();
        for (final item in _eligibleQueue.where(
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
        await _reconcilePendingSurveys(_eligibleQueue);
      } catch (error) {
        if (error is DioException && error.response?.statusCode != 401) {
          online = false;
          apiReachable = false;
        }
        if (kDebugMode) {
          debugPrint(
            '[SYNC] reconciliation classification=global category=${error.runtimeType}',
          );
        }
        return;
      }
      while (online && _eligibleQueue.isNotEmpty) {
        final eligible = _eligibleQueue;
        final eligiblePhotos = photos
            .where((photo) => canCurrentSessionViewSurveyId(photo.surveyId))
            .toList(growable: false);
        final ready = _scheduler.readyRound(
          eligible,
          eligiblePhotos,
          DateTime.now(),
        );
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
                apiReachable = false;
              }
              await _recordRetry(item, error, global: true);
              return;
            }
            final localReview = _localReviewCode(error);
            if (localReview != null) {
              await _recordRequiresReview(item, localReview);
              continue;
            }
            if (_isStructuralConflict(error)) {
              await _recordStructuralConflict(item, error as DioException);
              continue;
            }
            await _recordRetry(
              item,
              error,
              dependency: _isDependencyResponse(error),
            );
          }
        }
        if (!progressed &&
            _scheduler
                .readyRound(_eligibleQueue, eligiblePhotos, DateTime.now())
                .isEmpty) {
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

  Future<void> _reconcilePendingSurveys(List<SyncQueueItem> eligible) async {
    final surveyIds = eligible
        .map((item) => canonicalUuid(item.surveyId))
        .toSet();
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
      final serverSteps = steps
          .map((row) => (row['step_number'] as num?)?.toInt())
          .whereType<int>()
          .toSet();
      final localSurvey = surveys
          .where((candidate) => uuidEquals(candidate.id, surveyId))
          .firstOrNull;
      if (localSurvey != null) {
        final dependentSteps = eligible
            .where(
              (item) =>
                  uuidEquals(item.surveyId, surveyId) &&
                  const {
                    QueueOperation.updateComment,
                    QueueOperation.uploadPhoto,
                    QueueOperation.completeStep,
                  }.contains(item.operation),
            )
            .map((item) => item.step)
            .whereType<int>()
            .toSet();
        for (final step in localSurvey.steps.where(
          (candidate) =>
              candidate.state != StepState.locked &&
              dependentSteps.contains(candidate.number) &&
              !serverSteps.contains(candidate.number),
        )) {
          await _enqueue(surveyId, QueueOperation.openStep, step: step.number);
        }
      }
      final satisfied = <SyncQueueItem>[];
      for (final item in eligible.where(
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
            // A server-side photo proves that the multipart mutation was
            // committed, even when its response was lost. Integrity remains
            // a separate durable operation: never retire the ambiguous
            // upload unless confirmation is final or verify work exists.
            if (!confirmed &&
                item.operation == QueueOperation.uploadPhoto &&
                item.photoId != null) {
              await _enqueue(
                item.surveyId,
                QueueOperation.verifyPhotos,
                photoId: item.photoId,
                step: item.step,
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

  bool _isStructuralConflict(Object error) =>
      error is DioException &&
      error.response?.statusCode == 409 &&
      !_isDependencyResponse(error);

  Future<void> _recordStructuralConflict(
    SyncQueueItem item,
    DioException error,
  ) async {
    final data = error.response?.data;
    final code = data is Map
        ? '${data['code'] ?? 'STRUCTURAL_CONFLICT'}'
        : 'STRUCTURAL_CONFLICT';
    await _recordRequiresReview(item, code);
  }

  String? _localReviewCode(Object error) {
    if (error is! StateError) return null;
    final value = error.message.toString();
    return const {
          'MISSING_LOCAL_FILE',
          'LOCAL_CORRUPTION',
          'MAPPING_CONFLICT',
        }.contains(value)
        ? value
        : null;
  }

  Future<void> _recordRequiresReview(SyncQueueItem item, String code) async {
    final blocked = item.copyWith(
      requiresReview: true,
      lastErrorCode: code,
      clearNextAttempt: true,
    );
    queue = queue
        .map((candidate) => candidate.id == item.id ? blocked : candidate)
        .toList();
    await local.saveQueue(blocked);
    final current = surveys
        .where((survey) => uuidEquals(survey.id, item.surveyId))
        .firstOrNull;
    if (current != null) {
      await _replaceSurvey(
        current.copyWith(syncState: SyncState.requiresReview),
      );
    }
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
    final next = _eligibleQueue
        .map((item) => item.nextAttemptAt)
        .whereType<DateTime>()
        .where((date) => date.isAfter(DateTime.now()))
        .fold<DateTime?>(
          null,
          (earliest, date) =>
              earliest == null || date.isBefore(earliest) ? date : earliest,
        );
    _nextAttemptTimer?.cancel();
    _nextAttemptTimer = null;
    if (next == null || !online || session == null) return;
    final wait = next.difference(DateTime.now());
    _nextAttemptTimer = Timer(wait, () {
      _nextAttemptTimer = null;
      if (online && session != null) unawaited(synchronize());
    });
  }

  void _logBlockedQueue(DateTime now) {
    if (!kDebugMode) return;
    final eligible = _eligibleQueue;
    final eligiblePhotos = photos
        .where((photo) => canCurrentSessionViewSurveyId(photo.surveyId))
        .toList(growable: false);
    for (final item in eligible) {
      final state = _scheduler.readiness(item, eligible, eligiblePhotos, now);
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
        try {
          await remote.deletePhoto(s.id, item.photoId!);
        } on DioException catch (error) {
          // A retry after an ambiguous successful delete commonly observes
          // 404. The desired remote state is already true, so this is a
          // successful idempotent replay rather than a permanent conflict.
          if (error.response?.statusCode != 404) rethrow;
        }
        final deletion = local.journal.find(
          'delete-${canonicalUuid(item.photoId!)}',
        );
        if (deletion != null) await _purgeDeletedPhoto(deletion);
      case QueueOperation.updateComment:
        await remote.commentStep(
          s.id,
          item.step!,
          s.steps[item.step! - 1].comment,
        );
      case QueueOperation.uploadPhoto:
        final p = photos.firstWhere((x) => uuidEquals(x.id, item.photoId));
        final uploadFile = File(p.localPath);
        if (!uploadFile.existsSync()) {
          await _replacePhoto(
            p.copyWith(syncState: PhotoSyncState.missingLocal),
          );
          throw StateError('MISSING_LOCAL_FILE');
        }
        final capture = local.journal.find(p.id);
        if (capture?.fileSize != null &&
            await uploadFile.length() != capture!.fileSize) {
          await _replacePhoto(
            p.copyWith(syncState: PhotoSyncState.permanentFailure),
          );
          throw StateError('LOCAL_CORRUPTION');
        }
        final digest = await sha256File(uploadFile);
        if (digest.toLowerCase() != p.sha256.toLowerCase() ||
            (capture?.sha256 != null &&
                digest.toLowerCase() != capture!.sha256!.toLowerCase())) {
          await _replacePhoto(
            p.copyWith(syncState: PhotoSyncState.permanentFailure),
          );
          throw StateError('LOCAL_CORRUPTION');
        }
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
    if (next == PhotoSyncState.mappingConflict) {
      throw StateError('MAPPING_CONFLICT');
    }
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
      throw StateError('PHOTO_REUPLOAD_REQUIRED');
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
        final remoteOwner = _ownerFromServerRow(row);
        final index = surveys.indexWhere((s) => uuidEquals(s.id, id));
        if (index >= 0) {
          final localSurvey = surveys[index],
              wireStatus = _status('${row['status']}'),
              hasPendingLocalState =
                  localSurvey.syncState != SyncState.synchronized ||
                  queue.any((item) => uuidEquals(item.surveyId, id));
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
            contractorUserId: remoteOwner,
            crewId: _crewIdFromServerRow(row) ?? localSurvey.crewId,
            crew: _crewFromServerRow(row) ?? localSurvey.crew,
            status: hasPendingLocalState ? localSurvey.status : wireStatus,
            rejectionReason: row['rejection_reason']?.toString(),
            syncState: hasPendingLocalState
                ? localSurvey.syncState
                : SyncState.synchronized,
            currentStep: _newestStep(
              localSurvey.currentStep,
              (row['current_step'] as num?)?.toInt(),
            ),
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
            contractorUserId: remoteOwner,
            crewId: _crewIdFromServerRow(row),
            crew: _crewFromServerRow(row),
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
      apiReachable = true;
    } catch (_) {
      online = false;
      apiReachable = false;
    }
    notifyListeners();
  }

  String? _ownerFromServerRow(Map<String, dynamic> row) {
    final explicit = canonicalUuidOrNull(
      row['contractor_user_id']?.toString() ??
          row['contractorUserId']?.toString(),
    );
    if (explicit != null) return explicit;
    return null;
  }

  String? _crewIdFromServerRow(Map<String, dynamic> row) => canonicalUuidOrNull(
    row['crew_id']?.toString() ?? row['crewId']?.toString(),
  );

  String? _crewFromServerRow(Map<String, dynamic> row) {
    final value = row['crew']?.toString() ?? row['contractor_crew']?.toString();
    return value?.trim().isNotEmpty == true ? value!.trim() : null;
  }

  Future<void> loadSurveyDetail(String surveyId) async {
    final current = survey(surveyId);
    final detail = await remote.detail(current.id);
    final wireOwner = _ownerFromServerRow(detail);
    final wireCrewId = _crewIdFromServerRow(detail);
    final wireCrew = _crewFromServerRow(detail);
    final scoped = current.copyWith(crewId: wireCrewId, crew: wireCrew);
    if (!canViewAllSurveys && !canCurrentSessionViewSurvey(scoped)) {
      throw StateError('No tienes acceso a este levantamiento.');
    }
    final remotePhotos = (detail['photos'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .where((row) => row['deleted_at'] == null && row['deletedAt'] == null)
        .map((row) => RemoteConstructionPhoto.fromWire(current.id, row))
        .toList(growable: false);
    final wireSteps = (detail['steps'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
    final wireCorrections = (detail['corrections'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList(growable: false);
    final pending =
        current.syncState != SyncState.synchronized ||
        queue.any((item) => uuidEquals(item.surveyId, current.id));
    final steps = List.generate(6, (index) {
      final number = index + 1;
      final localStep = current.steps[index];
      final row = wireSteps
          .where(
            (candidate) =>
                (candidate['step_number'] as num?)?.toInt() == number,
          )
          .firstOrNull;
      if (row == null || pending) return localStep;
      final status = '${row['status']}';
      return localStep.copyWith(
        state: status == 'completed'
            ? StepState.completedServer
            : status == 'open'
            ? StepState.open
            : StepState.locked,
        comment: row['comment']?.toString(),
      );
    });
    final corrections = wireCorrections
        .map((row) {
          final round = (row['round_number'] as num?)?.toInt() ?? 0;
          return CorrectionRound(
            id: canonicalUuid('${row['correction_id']}'),
            round: round,
            state: '${row['status']}' == 'completed'
                ? StepState.completedServer
                : StepState.open,
            comment: row['comment']?.toString(),
            photoIds: remotePhotos
                .where((photo) => photo.correctionRound == round)
                .map((photo) => photo.id)
                .toList(growable: false),
          );
        })
        .toList(growable: false);
    final updated = current.copyWith(
      contractorUserId: wireOwner,
      crewId: wireCrewId,
      crew: wireCrew,
      contractorName:
          '${detail['contractor_name'] ?? detail['contractorName'] ?? current.contractorName}',
      accountNumber: mergeAccountNumber(current.accountNumber, detail),
      status: pending ? current.status : _status('${detail['status']}'),
      currentStep: pending
          ? current.currentStep
          : (detail['current_step'] as num?)?.toInt(),
      steps: steps,
      corrections: pending && corrections.isEmpty
          ? current.corrections
          : corrections,
      remotePhotos: remotePhotos,
      updatedAt:
          DateTime.tryParse('${detail['updated_at'] ?? detail['updatedAt']}') ??
          current.updatedAt,
    );
    await _replaceSurvey(updated);
  }

  Future<Uint8List> remotePhotoBytes(
    RemoteConstructionPhoto photo, {
    required bool original,
  }) async {
    if (!canCurrentSessionViewSurveyId(photo.surveyId)) {
      throw StateError('No tienes acceso a esta fotografía.');
    }
    final key = '${photo.id}:${original ? 'original' : 'thumb'}';
    final cached = _remotePhotoBytes[key];
    if (cached != null) return cached;
    final bytes = await remote.photoContent(
      photo.surveyId,
      photo.id,
      original: original,
    );
    _remotePhotoBytes[key] = bytes;
    return bytes;
  }

  Future<void> _adoptProfileCrew() async {
    final current = session;
    final profileCrew = profile?.crew.trim() ?? '';
    if (current == null ||
        current.kind != SessionKind.field ||
        profileCrew.isEmpty) {
      return;
    }
    if (current.crew != profileCrew || current.crewId != profile?.crewId) {
      session = current.copyWith(crew: profileCrew, crewId: profile?.crewId);
    }
    await sessions.save(session!);
  }

  void _reportUnownedPendingWork() {
    if (profile?.role == ConstructionRole.contractor &&
        unownedPendingCount > 0) {
      message =
          'Hay operaciones legacy con propietario desconocido. Se conservaron sin enviar para revisión.';
    }
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
      actorUserId: currentUserId,
      crew: currentCrew,
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
      actorUserId: currentUserId,
      crew: currentCrew,
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

int _newestStep(int localStep, int? remoteStep) =>
    remoteStep != null && remoteStep > localStep ? remoteStep : localStep;
