import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../core/hydrostatic/hydrostatic_contracts.dart';
import '../../data/hydrostatic/hydrostatic_repository.dart';
import '../../data/hydrostatic/hydrostatic_sync.dart';
import '../../domain/cabinets/cabinet_models.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';

/// Local UI coordinator. Camera/GPS use injected adapters; no remote operations.
class HydrostaticController extends ChangeNotifier {
  HydrostaticController({
    required this.openRepository,
    required this.access,
    required this.verifySession,
    required this.sessionChanges,
    required this.lookup,
    this.photos,
    this.locations,
    this.evidencePath,
  }) {
    sessionChanges.addListener(_sessionChanged);
  }
  final Future<HydrostaticRepository> Function() openRepository;
  final HydrostaticAccess Function() access;
  final Future<void> Function() verifySession;
  final Listenable sessionChanges;
  final HydrostaticCabinetLookup lookup;
  HydrostaticPhotoCoordinator? photos;
  HydrostaticLocationProvider? locations;
  String Function(HydrostaticEvidence)? evidencePath;
  final Map<String, String> _operations = {};
  String _operation(String key) =>
      _operations.putIfAbsent(key, () => const Uuid().v4());
  HydrostaticRepository? _repo;
  HydrostaticSync? sync;
  Future<void> Function()? initializeSync;
  String? syncSetupError;
  void Function()? disposeSyncRunner;
  bool syncOnStartup = false;
  String? _syncIdentity;
  void attachSync(HydrostaticSync value) {
    sync = value;
    value.addListener(_notify);
  }

  String syncLabel(String id) =>
      syncSetupError ??
      sync?.label(document(id)) ??
      'Sólo local · sincronización no habilitada';
  Future<void> retrySync() async {
    await _setupSync();
    await sync?.run(manual: true);
    _notify();
  }

  Future<void>? _initializing;
  Future<String>? _preparing;
  bool _disposed = false;
  Future<void>? _syncOpening;
  Future<void> _setupSync() =>
      _syncOpening ??= _openSync().whenComplete(() => _syncOpening = null);
  Future<void> _openSync() async {
    if (sync != null || initializeSync == null) return;
    try {
      await initializeSync!();
      syncSetupError = null;
    } catch (_) {
      syncSetupError =
          'Outbox no disponible; captura local conservada. Reintenta sincronización.';
    }
  }

  String? error;
  String? cameraRecoveryError;
  bool busy = false;
  int _evidenceValidationRevision = 0;
  int get evidenceValidationRevision => _evidenceValidationRevision;

  // Invalidates only UI prevalidation; durable closure always rechecks originals.
  void recheckEvidence() {
    _evidenceValidationRevision++;
    _evidenceChecks.clear();
    _notify();
  }

  String? get identity {
    try {
      final a = access();
      a.requireUser(a.actor.userId);
      return '${a.actor.userId}:${a.actor.sessionId}';
    } catch (_) {
      return null;
    }
  }

  /// Explain a blocked entry without opening storage or contacting the API.
  String? get accessIssue {
    try {
      final value = access();
      value.requireUser(value.actor.userId);
      return null;
    } on HydrostaticException catch (e) {
      return e.message;
    } catch (_) {
      return 'No se pudo verificar la autorización local. Vuelve a Inicio.';
    }
  }

  bool get allowed => identity != null;
  bool get ready => _repo != null && !_repo!.store.recoveryRequired;
  void requireIdentity(String? expected) => hydroRequire(
    expected != null && expected == identity,
    'SESSION_CHANGED',
    'La sesión cambió. Vuelve a Inicio.',
  );
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _sessionChanged() {
    _evidenceValidationRevision++;
    _evidenceChecks.clear();
    error = null;
    if (syncOnStartup && identity != null && _syncIdentity != identity) {
      _syncIdentity = identity;
      unawaited(initialize().catchError((Object _) {}));
    }
    _notify();
  }

  Future<void> initialize() =>
      _initializing ??= _initialize().whenComplete(() => _initializing = null);
  Future<void> _initialize() async {
    _evidenceValidationRevision++;
    _evidenceChecks.clear();
    final key = identity;
    requireIdentity(key);
    await verifySession();
    requireIdentity(key);
    _repo ??= await openRepository();
    requireIdentity(key);
    if (_repo!.store.recoveryRequired) await _repo!.recover();
    requireIdentity(key);
    if (!busy) {
      try {
        await photos?.recover(access());
        cameraRecoveryError = null;
      } catch (e) {
        cameraRecoveryError =
            'Recuperación de cámara pendiente. Los archivos y registros se conservan; reintenta la recuperación.';
      }
      requireIdentity(key);
      for (final t in _repo!.forUser().where(
        (t) => t.state == HydrostaticTestState.starting,
      )) {
        await _repo!.cancelStart(
          t.id,
          _operation('recoverStarting:${t.id}:${t.revision}'),
        );
      }
    }
    await expireResults();
    await _setupSync();
    unawaited(sync?.run());
    error = null;
    _notify();
  }

  List<HydrostaticTest> get documents {
    if (!allowed || !ready) return [];
    return _repo!.forUser()..sort(
      (a, b) => b.toJson()['createdAt'].compareTo(a.toJson()['createdAt']),
    );
  }

  List<HydrostaticTest> get preparations =>
      documents.where((t) => t.startedAt == null).toList();
  List<HydrostaticTest> get started =>
      documents.where((t) => t.startedAt != null).toList();
  List<HydrostaticTest> history(String uid) =>
      started.where((t) => t.cabinet.uid == uid).toList()
        ..sort((a, b) => b.attemptNumber!.compareTo(a.attemptNumber!));
  HydrostaticTest document(String id) =>
      _repo?.get(id) ??
      (throw const HydrostaticException(
        'NOT_FOUND',
        'Registro no disponible para esta sesión.',
      ));
  int provisional(String id) {
    final t = document(id);
    return _repo!.sequences.last(t.cabinet.uid) + 1;
  }

  Future<String> identify(String input) {
    // Single flight also prevents repeated scanner callbacks and double taps.
    return _preparing ??= _identify(
      input,
    ).whenComplete(() => _preparing = null);
  }

  Future<String> _identify(String input) async {
    final key = identity;
    requireIdentity(key);
    final uid = cabinetUid(input.trim());
    busy = true;
    error = null;
    _notify();
    try {
      await initialize();
      requireIdentity(key);
      final cabinet = await lookup.findLocal(uid, access());
      requireIdentity(key);
      hydroRequire(
        cabinet != null,
        'CABINET_NOT_LOCAL',
        'Este gabinete no está disponible en este dispositivo. Consulta el módulo de Gabinetes y vuelve a intentarlo.',
      );
      final existing = preparations.where((t) => t.cabinet.uid == uid).toList();
      final same = existing.where(
        (t) =>
            canonicalHydroJson(t.cabinet.toJson()) ==
            canonicalHydroJson(cabinet!.toJson()),
      );
      if (same.isNotEmpty) return same.first.id;
      await verifySession();
      requireIdentity(key);
      final latest = await lookup.findLocal(uid, access());
      requireIdentity(key);
      hydroRequire(
        latest != null &&
            canonicalHydroJson(latest.toJson()) ==
                canonicalHydroJson(cabinet!.toJson()),
        'CABINET_CHANGED',
        'El gabinete cambió. Vuelve a identificarlo.',
      );
      final t = await _repo!.prepare(
        operationId: const Uuid().v4(),
        testId: const Uuid().v4(),
        cabinet: cabinet!,
      );
      requireIdentity(key);
      return t.id;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<String?> preparationWarning(String id) async {
    final key = identity;
    final t = document(id);
    final latest = await lookup.findLocal(t.cabinet.uid, access());
    requireIdentity(key);
    if (latest == null ||
        canonicalHydroJson(latest.toJson()) !=
            canonicalHydroJson(t.cabinet.toJson())) {
      return 'El gabinete cambió o ya no está disponible. Se conserva el snapshot original; revisa Gabinetes antes de continuar.';
    }
    return null;
  }

  Future<void> validateCabinet(String id) async {
    final warning = await preparationWarning(id);
    hydroRequire(
      warning == null,
      'CABINET_CHANGED',
      warning ?? 'Gabinete cambiado.',
    );
  }

  Future<bool> startAvailable(String id) async {
    if (busy ||
        photos == null ||
        cameraRecoveryError != null ||
        locations == null ||
        !ready) {
      return false;
    }
    try {
      await validateCabinet(id);
      return await _repo!.canStart(id);
    } catch (_) {
      return false;
    }
  }

  int pendingCaptures(String id) {
    final t = document(id);
    return _repo!.store.metadata.keys
        .where((key) => '$key'.startsWith('capture:'))
        .map((key) => _repo!.store.read(_repo!.store.metadata, '$key')!)
        .where(
          (r) =>
              r['testId'] == id &&
              r['actorId'] == t.actor.userId &&
              !['LINKED', 'CANCELLED'].contains(r['state']),
        )
        .length;
  }

  final Map<String, (Object, Future<bool>)> _evidenceChecks = {};
  Future<bool> evidenceValid(HydrostaticEvidence e) {
    final key = (
      identity,
      e.testId,
      e.actorId,
      evidenceValidationRevision,
      ready,
      e.originalPath,
      e.sha256,
      e.byteLength,
      e.ready,
      e.integrity,
    );
    final existing = _evidenceChecks[e.id];
    if (existing != null && existing.$1 == key) return existing.$2;
    final check = e.ready && allowed && ready
        ? _repo!.files.verify(e)
        : Future.value(false);
    _evidenceChecks[e.id] = (key, check);
    return check;
  }

  HydrostaticElapsed elapsed(String id) => _repo!.elapsed(id);
  Future<void> capturePhoto(String id, HydrostaticEvidenceRole role) async {
    if (busy) return;
    final key = identity;
    requireIdentity(key);
    hydroRequire(
      photos != null && cameraRecoveryError == null,
      'CAMERA_NOT_READY',
      'La captura segura no está disponible.',
    );
    busy = true;
    error = null;
    _notify();
    try {
      await verifySession();
      requireIdentity(key);
      final t = document(id);
      hydroRequire(
        !resultExpired(id),
        'RESULT_EXPIRED',
        'Prueba descartada por plazo vencido.',
      );
      await photos!.capture(
        HydrostaticCaptureIntent(
          id: const Uuid().v4(),
          testId: id,
          actorId: t.actor.userId,
          role: role,
          requestedAt: _repo!.clock.now().utc,
        ),
      );
      requireIdentity(key);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> start(String id) async {
    if (busy) return;
    final key = identity;
    requireIdentity(key);
    hydroRequire(
      await startAvailable(id),
      'START_NOT_READY',
      'Revisa foto inicial, gabinete y pruebas en curso.',
    );
    requireIdentity(key);
    if (busy) return;
    busy = true;
    error = null;
    _notify();
    try {
      await verifySession();
      requireIdentity(key);
      await validateCabinet(id);
      final gps = await locations!.capture();
      requireIdentity(key);
      await verifySession();
      requireIdentity(key);
      await validateCabinet(id);
      hydroRequire(
        gps.validAt(_repo!.clock.now().utc),
        'GPS_REQUIRED',
        'GPS antiguo, posterior o fuera de precisión.',
      );
      await _repo!.requestStart(
        id,
        _operation('request:$id:${document(id).revision}'),
      );
      await _repo!.start(
        id,
        _operation('start:$id:${document(id).revision}'),
        gps,
        validateCabinet: () => validateCabinet(id),
      );
      requireIdentity(key);
    } catch (_) {
      if (ready &&
          identity == key &&
          document(id).state == HydrostaticTestState.starting) {
        await _repo!.cancelStart(
          id,
          _operation('cancel:$id:${document(id).revision}'),
        );
      }
      rethrow;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> finish(String id) async {
    if (busy) return;
    final key = identity;
    requireIdentity(key);
    busy = true;
    error = null;
    _notify();
    try {
      await verifySession();
      requireIdentity(key);
      hydroRequire(
        photos?.isCapturing(id) != true,
        'CAMERA_BUSY',
        'Finaliza la captura antes de terminar.',
      );
      await _repo!.finish(id, _operation('finish:$id'));
      requireIdentity(key);
    } finally {
      busy = false;
      _notify();
    }
  }

  bool _expiring = false;
  HydrostaticElapsed resultRemaining(String id) => _repo!.resultRemaining(id);
  bool requiresTimeReview(String id) => _repo!.requiresTimeReview(document(id));
  bool resultExpired(String id) => _repo!.resultExpired(document(id));
  Future<void> expireResults() async {
    if (_expiring || busy || !ready || !allowed) return;
    final key = identity;
    _expiring = true;
    try {
      for (final t in _repo!.forUser()) {
        requireIdentity(key);
        if (t.isDiscarded ||
            t.closedAt != null ||
            photos?.isCapturing(t.id) == true) {
          continue;
        }
        if (_repo!.requiresTimeReview(t) &&
            t.toJson()['temporalReview'] == null) {
          await _repo!.reviewClock(t.id, _operation('clockReview:${t.id}'));
          requireIdentity(key);
          _notify();
        } else if (_repo!.resultExpired(t)) {
          await _repo!.discardExpired(t.id, _operation('expire:${t.id}'));
          requireIdentity(key);
          _notify();
        }
      }
    } finally {
      _expiring = false;
    }
  }

  final List<({String id, String op, String? identity, HydroJson draft})>
  _draftQueue = [];
  Future<void>? _draftDrain;
  bool get draftPending => _draftQueue.any((j) => j.identity == identity);

  HydroJson leakDraft(String id) {
    final t = document(id);
    final pending = _draftQueue
        .where((j) => j.id == id && j.identity == identity)
        .lastOrNull;
    if (pending != null) {
      return hydroObject(jsonDecode(jsonEncode(pending.draft)));
    }
    return t.toJson()['leakDraft'] == null
        ? {
            'version': 1,
            'observation': '',
            'joints': {
              for (final leak in t.leaks)
                leak.jointCode: {
                  'selected': true,
                  'pressure': '${leak.pressureMilliBar / 1000}',
                  'description': leak.description,
                },
            },
          }
        : hydroObject(t.toJson()['leakDraft']);
  }

  Future<void> saveDraft(String id, HydroJson draft) {
    final key = identity;
    requireIdentity(key);
    document(id);
    _draftQueue.add((
      id: id,
      op: const Uuid().v4(),
      identity: key,
      draft: hydroObject(jsonDecode(jsonEncode(draft))),
    ));
    return flushDrafts();
  }

  Future<void> flushDrafts() =>
      _draftDrain ??= _flushDrafts().whenComplete(() => _draftDrain = null);
  Future<void> _flushDrafts() async {
    while (_draftQueue.any((j) => j.identity == identity)) {
      final job = _draftQueue.firstWhere((j) => j.identity == identity);
      requireIdentity(job.identity);
      await verifySession();
      requireIdentity(job.identity);
      if (_repo!.store.recoveryRequired) await _repo!.recover();
      requireIdentity(job.identity);
      await _repo!.saveLeakDraft(job.id, job.op, job.draft);
      requireIdentity(job.identity);
      _draftQueue.remove(job);
      _notify();
    }
  }

  Future<void> resultAction(
    String id,
    String action, {
    bool? yes,
    bool confirmed = false,
  }) async {
    if (busy) return;
    final key = identity;
    requireIdentity(key);
    busy = true;
    _notify();
    try {
      await flushDrafts();
      await verifySession();
      requireIdentity(key);
      hydroRequire(
        pendingCaptures(id) == 0 && cameraRecoveryError == null,
        'RECOVERY_PENDING',
        'Resuelve las capturas pendientes antes de cerrar.',
      );
      final op = _operation('$action:$id:${document(id).revision}:$yes');
      switch (action) {
        case 'answer':
          await _repo!.answerLeaks(id, op, yes!);
        case 'change':
          await _repo!.changeAnswer(id, op, yes!, confirmed: confirmed);
        case 'leak':
          await _repo!.closeLeak(id, op);
        case 'pass':
          await _repo!.closePass(id, op);
        case 'video':
          hydroRequire(
            confirmed,
            'CONFIRMATION_REQUIRED',
            'Confirma que enviaste el video.',
          );
          await _repo!.declareVideoSent(id, op);
        default:
          throw StateError('Comando desconocido');
      }
      requireIdentity(key);
    } finally {
      _evidenceValidationRevision++;
      _evidenceChecks.clear();
      busy = false;
      _notify();
    }
  }

  Future<String?> closureIssue(String id) async {
    try {
      hydroRequire(
        !busy &&
            !draftPending &&
            ready &&
            pendingCaptures(id) == 0 &&
            cameraRecoveryError == null,
        'RECOVERY_PENDING',
        'Guardado o recuperación pendiente.',
      );
      final t = document(id);
      if (t.state == HydrostaticTestState.leakDetailsPending) {
        await _repo!.validateLeak(t);
      } else {
        await _repo!.validatePass(t);
      }
      return null;
    } catch (e) {
      return '$e';
    }
  }

  Future<void> linkEvidence(
    String id,
    String evidenceId,
    List<String> codes,
  ) async {
    if (busy) return;
    final key = identity;
    requireIdentity(key);
    busy = true;
    _notify();
    try {
      await flushDrafts();
      await verifySession();
      requireIdentity(key);
      await _repo!.linkLeakEvidence(
        id,
        _operation(
          'link:$id:$evidenceId:${document(id).revision}:${codes.join(',')}',
        ),
        evidenceId,
        codes,
      );
      requireIdentity(key);
    } finally {
      busy = false;
      _notify();
    }
  }

  bool canDelete(String id) {
    try {
      if (!ready || busy) return false;
      _repo!.development.requireDeletion();
      final t = document(id);
      return ![
            HydrostaticTestState.active,
            HydrostaticTestState.starting,
          ].contains(t.state) &&
          !_repo!.isCapturing(id) &&
          _repo!.store.read(_repo!.store.metadata, 'syncProtected:$id') == null;
    } catch (_) {
      return false;
    }
  }

  Future<void> delete(String id, String confirmedId) async {
    final key = identity;
    requireIdentity(key);
    await verifySession();
    requireIdentity(key);
    hydroRequire(
      canDelete(id),
      'DELETE_DISABLED',
      'Eliminación no habilitada.',
    );
    await _repo!.deleteLocal(
      id,
      const Uuid().v4(),
      confirmedTestId: confirmedId,
    );
    requireIdentity(key);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    disposeSyncRunner?.call();
    sync?.removeListener(_notify);
    sync?.dispose();
    sessionChanges.removeListener(_sessionChanged);
    super.dispose();
  }
}
