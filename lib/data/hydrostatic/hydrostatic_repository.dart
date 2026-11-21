import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../../core/hydrostatic/hydrostatic_contracts.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';
import '../../domain/hydrostatic/hydrostatic_approval_policy.dart';
import 'hydrostatic_store.dart';

class HydrostaticRepository {
  HydrostaticRepository({
    required this.store,
    required this.clock,
    required this.access,
    required this.files,
    this.development = const HydrostaticDevelopmentPolicy(),
    this.isCapturing = _notCapturing,
    this.approvalPolicy = HydrostaticApprovalPolicy.approved,
  });
  static bool _notCapturing(String _) => false;
  final HydrostaticApprovalPolicy approvalPolicy;
  final HydrostaticStore store;
  final HydrostaticClock clock;
  final HydrostaticAccess Function() access;
  final HydrostaticEvidenceFiles files;
  final HydrostaticDevelopmentPolicy development;
  final bool Function(String) isCapturing;
  HydrostaticOperationJournal get journal => HydrostaticOperationJournal(store);
  HydrostaticSequenceStore get sequences => HydrostaticSequenceStore(store);

  HydrostaticTest? get(String id) {
    hydroUuid(id);
    final test = store.test(id);
    if (test != null) {
      access().requireUser(test.actor.userId);
    } else {
      access().requireUser(access().actor.userId);
    }
    if (store.read(store.metadata, 'delete:$id') != null) return null;
    return test;
  }

  List<HydrostaticTest> forUser() {
    final a = access();
    a.requireUser(a.actor.userId);
    return store
        .all()
        .where(
          (t) =>
              t.actor.userId == a.actor.userId &&
              store.read(store.metadata, 'delete:${t.id}') == null,
        )
        .toList();
  }

  List<HydrostaticTest> forCabinet(String uid) =>
      forUser()
          .where((t) => t.cabinet.uid == uid && t.attemptNumber != null)
          .toList()
        ..sort((a, b) => a.attemptNumber!.compareTo(b.attemptNumber!));
  HydrostaticElapsed elapsed(String id) {
    final t = get(id)!;
    hydroRequire(t.startedAt != null, 'INVALID_STATE', 'Prueba no iniciada.');
    if (t.endedAt != null) {
      return HydrostaticElapsed(
        t.durationMs!,
        t.timeState,
        List<String>.from(t.toJson()['anomalies']),
      );
    }
    return HydrostaticElapsed.between(
      HydrostaticClockReading.fromJson(hydroObject(t.toJson()['startClock'])),
      clock.now(),
    );
  }

  HydrostaticElapsed _sinceEnd(HydrostaticTest t) => HydrostaticElapsed.between(
    HydrostaticClockReading.fromJson(hydroObject(t.toJson()['endClock'])),
    clock.now(),
  );
  HydrostaticElapsed resultRemaining(String id) {
    final t = get(id)!;
    hydroRequire(t.endedAt != null, 'INVALID_STATE', 'Sin fin registrado.');
    final elapsed = _sinceEnd(t);
    final maximum = approvalPolicy.maximumFinalDelay!.inMilliseconds;
    return HydrostaticElapsed(
      (maximum - elapsed.milliseconds).clamp(0, maximum).toInt(),
      requiresTimeReview(t) ? HydrostaticTimeState.needsReview : elapsed.state,
      elapsed.anomalies,
    );
  }

  bool requiresTimeReview(HydrostaticTest t) =>
      t.endedAt != null &&
      t.closedAt == null &&
      !t.isDiscarded &&
      (t.timeState == HydrostaticTimeState.needsReview ||
          _sinceEnd(t).state == HydrostaticTimeState.needsReview);

  Future<HydrostaticTest> reviewClock(String id, String op) =>
      _command(op, id, 'reviewClock', {}, (t, now) async {
        hydroRequire(
          t != null && requiresTimeReview(t),
          'INVALID_STATE',
          'Sin anomalía temporal.',
        );
        if (t!.toJson()['temporalReview'] != null) return t.toJson();
        return _update(t, now, {
          'executionTimeState': hydroWire(t.timeState),
          'timeState': 'NEEDS_REVIEW',
          'temporalReview': {
            'reason': 'CLOCK_INCONSISTENT',
            'observedAt': now.utc.toIso8601String(),
          },
          'anomalies': [
            ...List<String>.from(t.toJson()['anomalies']),
            'CLOSURE_CLOCK_INCONSISTENT',
          ],
        });
      });

  bool resultExpired(HydrostaticTest t) =>
      t.isDiscarded ||
      (t.endedAt != null &&
          t.closedAt == null &&
          !requiresTimeReview(t) &&
          approvalPolicy.maximumFinalDelay != null &&
          _sinceEnd(t).milliseconds >
              approvalPolicy.maximumFinalDelay!.inMilliseconds);

  Future<HydrostaticTest> discardExpired(String id, String op) =>
      _command(op, id, 'discardExpired', {}, (t, now) async {
        hydroRequire(
          t != null && resultExpired(t),
          'INVALID_STATE',
          'El intento no ha vencido.',
        );
        if (t!.isDiscarded) return t.toJson();
        return _update(t, now, {
          'discardedAt': t.endedAt!
              .add(approvalPolicy.maximumFinalDelay!)
              .toUtc()
              .toIso8601String(),
          'discardDetectedAt': now.utc.toIso8601String(),
          'discardedFromState': hydroWire(t.state),
          'discardReason': 'RESULT_DEADLINE_EXCEEDED',
          'discardPolicy': approvalPolicy.toJson(),
        });
      });

  Future<HydrostaticTest> _command(
    String op,
    String id,
    String type,
    HydroJson input,
    Future<HydroJson> Function(HydrostaticTest?, HydrostaticClockReading)
    reduce, {
    int? expectedRevision,
  }) async {
    final origin = access().actor;
    return store.serial(() async {
      hydroUuid(op);
      hydroUuid(id);
      final session = access();
      session.requireUser(origin.userId);
      hydroRequire(
        session.actor.sessionId == origin.sessionId &&
            session.actor.deviceInstallationId == origin.deviceInstallationId,
        'ACTOR_CHANGED',
        'La sesión cambió antes de ejecutar la operación.',
      );
      hydroRequire(
        !store.recoveryRequired,
        'RECOVERY_REQUIRED',
        'Recupera el journal antes de continuar.',
      );
      hydroRequire(
        store.read(store.metadata, 'delete:$id') == null,
        'DELETED',
        'Expediente descartado.',
      );
      final hash = sha256
          .convert(
            utf8.encode(
              canonicalHydroJson({
                'id': id,
                'type': type,
                'input': input,
                'actor': session.actor.userId,
                'expectedRevision': expectedRevision,
              }),
            ),
          )
          .toString();
      final previous = journal.get(op);
      if (previous != null) {
        hydroRequire(
          previous['fingerprint'] == hash &&
              previous['actor'] == session.actor.userId,
          'IDEMPOTENCY_CONFLICT',
          'La operación ya tiene otro contenido/actor.',
        );
        if (previous['phase'] == 'APPLIED') {
          hydroRequire(
            previous['type'] != 'timeReview',
            'CLOCK_REVIEW_REQUIRED',
            'El compromiso requiere revisión temporal.',
          );
          return HydrostaticTest.fromJson(hydroObject(previous['after']));
        }
      }
      final before = store.test(id);
      if (before != null) {
        session.requireUser(before.actor.userId);
        hydroRequire(
          expectedRevision == null || expectedRevision == before.revision,
          'REVISION_CONFLICT',
          'Documento modificado.',
        );
      }
      if (before != null &&
          ['answer', 'changeAnswer', 'closeLeak', 'closePass'].contains(type)) {
        hydroRequire(
          !resultExpired(before),
          'RESULT_EXPIRED',
          'Prueba descartada: venció el plazo para finalizar. Historial y fotos conservados. Inicia un nuevo intento.',
        );
      }
      final stamp = clock.now();
      // Business validation before recording a prepared operation.
      final after = HydrostaticTest.fromJson(await reduce(before, stamp));
      final current = access();
      current.requireUser(session.actor.userId);
      hydroRequire(
        current.actor.sessionId == session.actor.sessionId,
        'ACTOR_CHANGED',
        'La sesión cambió durante la operación.',
      );
      if (before != null &&
          canonicalHydroJson(after.toJson()) ==
              canonicalHydroJson(before.toJson())) {
        return before;
      }
      final entry = <String, dynamic>{
        'operationId': op,
        'testId': id,
        'actor': session.actor.userId,
        'fingerprint': hash,
        'type': type,
        'phase': 'PREPARED',
        'after': after.toJson(),
        'beforeRevision': before?.revision,
        'sequence': type == 'start'
            ? {'uid': after.cabinet.uid, 'number': after.attemptNumber}
            : null,
      };
      try {
        await journal.save(entry, 'prepared');
        // Recheck identity after asynchronous durable preparation, before commitment.
        final a = access();
        a.requireUser(session.actor.userId);
        hydroRequire(
          a.actor.sessionId == session.actor.sessionId,
          'ACTOR_CHANGED',
          'La sesión cambió.',
        );
        if (type == 'closePass' || type == 'closeLeak') {
          // A candidate alone is not a certified close. Observe time only after
          // its payload has flushed, then persist that witness for exact replay.
          entry['phase'] = 'CLOSE_PENDING_TIME';
          await journal.save(entry, 'ready');
          final observed = clock.now();
          final elapsed = HydrostaticElapsed.between(
            HydrostaticClockReading.fromJson(
              hydroObject(before!.toJson()['endClock']),
            ),
            observed,
          );
          final identity = access();
          identity.requireUser(session.actor.userId);
          hydroRequire(
            identity.actor.sessionId == session.actor.sessionId,
            'ACTOR_CHANGED',
            'La sesión cambió.',
          );
          if (elapsed.state == HydrostaticTimeState.needsReview) {
            await _uncertainClose(entry, 'CLOCK_INCONSISTENT');
            throw const HydrostaticException(
              'CLOCK_REVIEW_REQUIRED',
              'Cierre pendiente de revisión temporal.',
            );
          }
          if (elapsed.milliseconds >
              approvalPolicy.maximumFinalDelay!.inMilliseconds) {
            await journal.save({
              ...entry,
              'phase': 'ERROR',
              'error': 'CLOSE_COMMIT_EXPIRED',
            }, 'closeRejected');
            throw const HydrostaticException(
              'RESULT_EXPIRED',
              'El compromiso de cierre excedió el plazo.',
            );
          }
          entry['closeWitness'] = {
            'observedClock': observed.toJson(),
            'elapsedMs': elapsed.milliseconds,
            'maximumMs': approvalPolicy.maximumFinalDelay!.inMilliseconds,
            'policy': approvalPolicy.toJson(),
          };
          entry['after'] = {
            ...after.toJson(),
            'closedAt': observed.utc.toIso8601String(),
            'closeWitness': entry['closeWitness'],
          };
          entry['phase'] = 'APPLY_READY';
          await journal.save(entry, 'closeWitness');
        } else {
          entry['phase'] = 'APPLY_READY';
          await journal.save(entry, 'ready');
        }
        await _apply(entry);
        return HydrostaticTest.fromJson(hydroObject(entry['after']));
      } catch (_) {
        store.recoveryRequired = true;
        rethrow;
      }
    });
  }

  HydroJson _update(
    HydrostaticTest t,
    HydrostaticClockReading now,
    HydroJson patch,
  ) => {
    ...t.toJson(),
    ...patch,
    'revision': t.revision + 1,
    'updatedAt': now.utc.toUtc().toIso8601String(),
  };
  void _state(HydrostaticTest? t, HydrostaticTestState state) => hydroRequire(
    t != null && t.state == state,
    'INVALID_STATE',
    'Estado requerido: ${hydroWire(state)}.',
  );
  void _transition(HydrostaticTest t, HydrostaticTestState to) =>
      HydrostaticStateMachine.requireTransition(t.state, to);

  Future<HydrostaticTest> prepare({
    required String operationId,
    required String testId,
    required HydrostaticCabinetSnapshot cabinet,
  }) {
    // Bind the initiating identity before entering the serialized writer. A
    // queued preparation must never migrate to a newly signed-in user.
    final origin = access().actor;
    return _command(operationId, testId, 'prepare', cabinet.toJson(), (
      before,
      now,
    ) async {
      hydroRequire(before == null, 'ALREADY_EXISTS', 'UUID ya utilizado.');
      final actor = access().actor;
      hydroRequire(
        actor.userId == origin.userId &&
            actor.sessionId == origin.sessionId &&
            actor.deviceInstallationId == origin.deviceInstallationId,
        'ACTOR_CHANGED',
        'La sesión cambió mientras esperaba el guardado.',
      );
      return {
        'id': testId,
        'schemaVersion': 1,
        'revision': 0,
        'cabinet': cabinet.toJson(),
        'actor': actor.toJson(),
        'catalogVersion': HydrostaticJoint.version,
        'state': 'PREPARATION',
        'result': 'PENDING',
        'attemptNumber': null,
        'createdAt': now.utc.toUtc().toIso8601String(),
        'updatedAt': now.utc.toUtc().toIso8601String(),
        'startedAt': null,
        'endedAt': null,
        'closedAt': null,
        'durationMs': null,
        'location': null,
        'startClock': null,
        'endClock': null,
        'targetMilliBar': 5000,
        'finalMilliBar': 4000,
        'leaks': <HydroJson>[],
        'evidence': <HydroJson>[],
        'video': const HydrostaticVideoDeclaration(
          HydrostaticVideoState.notApplicable,
        ).toJson(),
        'hadLeaks': null,
        'timeState': 'CONSISTENT',
        'recoveryState': 'CLEAN',
        'syncState': 'LOCAL_ONLY',
        'deletionState': 'NONE',
        'anomalies': <String>[],
      };
    });
  }

  Future<HydrostaticTest> addEvidence(
    String id,
    String op,
    HydrostaticEvidence evidence, {
    int? expectedRevision,
  }) => _command(op, id, 'evidence', evidence.toJson(), (t, now) async {
    hydroRequire(
      t != null &&
          ![
            HydrostaticTestState.passed,
            HydrostaticTestState.failed,
          ].contains(t.state),
      'INVALID_STATE',
      'Prueba cerrada o ausente.',
    );
    hydroRequire(
      evidence.testId == id && evidence.actorId == t!.actor.userId,
      'INVALID_EVIDENCE',
      'Prueba/actor distintos.',
    );
    hydroRequire(
      !evidence.capturedAt.isAfter(now.utc),
      'INVALID_TIME',
      'Foto futura.',
    );
    final existing = t!.evidence.where((e) => e.id == evidence.id).firstOrNull;
    if (existing != null) {
      hydroRequire(
        canonicalHydroJson(existing.toJson()) ==
            canonicalHydroJson(evidence.toJson()),
        'EVIDENCE_CONFLICT',
        'La evidencia ya tiene otro contenido.',
      );
      return t.toJson();
    }
    if (evidence.ready) {
      hydroRequire(
        await files.verify(evidence),
        'FILE_CORRUPT',
        'Original ausente o alterado.',
      );
    }
    return _update(t, now, {
      'evidence': [...t.evidence.map((e) => e.toJson()), evidence.toJson()],
    });
  }, expectedRevision: expectedRevision);
  Future<void> _role(HydrostaticTest t, HydrostaticEvidenceRole role) async {
    final candidates = t.evidence.where((e) => e.role == role && e.ready);
    hydroRequire(
      candidates.isNotEmpty,
      'EVIDENCE_INCOMPLETE',
      'Falta ${hydroWire(role)}.',
    );
    for (final e in candidates) {
      if (await files.verify(e)) return;
    }
    throw const HydrostaticException(
      'FILE_CORRUPT',
      'Evidencia ausente o alterada.',
    );
  }

  Future<bool> canStart(String id) async {
    try {
      final t = get(id);
      if (t == null ||
          t.state != HydrostaticTestState.preparation ||
          store.recoveryRequired ||
          isCapturing(id)) {
        return false;
      }
      if (store.all().any(
        (other) =>
            other.state == HydrostaticTestState.active &&
            (other.actor.userId == t.actor.userId ||
                other.cabinet.uid == t.cabinet.uid),
      )) {
        return false;
      }
      await _role(t, HydrostaticEvidenceRole.initialSetup);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<HydrostaticTest> requestStart(String id, String op) =>
      _command(op, id, 'requestStart', {}, (t, now) async {
        if (t?.state == HydrostaticTestState.starting) return t!.toJson();
        _state(t, HydrostaticTestState.preparation);
        await _role(t!, HydrostaticEvidenceRole.initialSetup);
        _transition(t, HydrostaticTestState.starting);
        return _update(t, now, {'state': 'STARTING'});
      });
  Future<HydrostaticTest> cancelStart(String id, String op) =>
      _command(op, id, 'cancelStart', {}, (t, now) async {
        _state(t, HydrostaticTestState.starting);
        _transition(t!, HydrostaticTestState.preparation);
        return _update(t, now, {'state': 'PREPARATION'});
      });
  Future<HydrostaticTest> start(
    String id,
    String op,
    HydrostaticLocation location, {
    Future<void> Function()? validateCabinet,
  }) => _command(op, id, 'start', location.toJson(), (t, now) async {
    if (t?.startedAt != null) return t!.toJson();
    _state(t, HydrostaticTestState.starting);
    hydroRequire(
      location.validAt(now.utc),
      'GPS_REQUIRED',
      'GPS inicial inválido, antiguo o posterior.',
    );
    await _role(t!, HydrostaticEvidenceRole.initialSetup);
    hydroRequire(
      !store.all().any(
        (other) =>
            other.id != id &&
            other.state == HydrostaticTestState.active &&
            (other.cabinet.uid == t.cabinet.uid ||
                other.actor.userId == t.actor.userId),
      ),
      'ACTIVE_CONFLICT',
      'Hay una prueba activa para este actor o gabinete.',
    );
    _transition(t, HydrostaticTestState.active);
    await validateCabinet?.call();
    now = clock.now();
    hydroRequire(
      location.validAt(now.utc),
      'GPS_REQUIRED',
      'GPS venció durante la validación de evidencia.',
    );
    final timestamp = now.utc.toUtc().toIso8601String();
    return _update(t, now, {
      'state': 'ACTIVE',
      'attemptNumber': sequences.last(t.cabinet.uid) + 1,
      'startedAt': timestamp,
      'startClock': now.toJson(),
      'location': location.toJson(),
      'startOperationId': op,
    });
  });
  Future<HydrostaticTest> finish(String id, String op) => _command(
    op,
    id,
    'finish',
    {},
    (t, now) async {
      if (t?.endedAt != null) return t!.toJson();
      _state(t, HydrostaticTestState.active);
      _transition(t!, HydrostaticTestState.endedPendingResult);
      final elapsed = HydrostaticElapsed.between(
        HydrostaticClockReading.fromJson(hydroObject(t.toJson()['startClock'])),
        now,
      );
      return _update(t, now, {
        'state': 'ENDED_PENDING_RESULT',
        'endedAt': now.utc.toUtc().toIso8601String(),
        'endClock': now.toJson(),
        'durationMs': elapsed.milliseconds,
        'timeState': hydroWire(elapsed.state),
        'anomalies': elapsed.anomalies,
        'endOperationId': op,
      });
    },
  );
  Future<HydrostaticTest> answerLeaks(String id, String op, bool yes) =>
      _command(op, id, 'answer', {'yes': yes}, (t, now) async {
        if (t?.hadLeaks == yes) return t!.toJson();
        _state(t, HydrostaticTestState.endedPendingResult);
        final state = yes
            ? HydrostaticTestState.leakDetailsPending
            : HydrostaticTestState.approvalEvidencePending;
        _transition(t!, state);
        return _update(t, now, {'state': hydroWire(state), 'hadLeaks': yes});
      });
  Future<HydrostaticTest> changeAnswer(
    String id,
    String op,
    bool yes, {
    required bool confirmed,
  }) => _command(op, id, 'changeAnswer', {'yes': yes, 'confirmed': confirmed}, (
    t,
    now,
  ) async {
    hydroRequire(
      confirmed,
      'CONFIRMATION_REQUIRED',
      'Confirma el cambio de respuesta.',
    );
    hydroRequire(
      t != null &&
          [
            HydrostaticTestState.leakDetailsPending,
            HydrostaticTestState.approvalEvidencePending,
          ].contains(t.state),
      'INVALID_STATE',
      'Resultado cerrado o todavía sin respuesta.',
    );
    if (t!.hadLeaks == yes) return t.toJson();
    final next = yes
        ? HydrostaticTestState.leakDetailsPending
        : HydrostaticTestState.approvalEvidencePending;
    _transition(t, next);
    return _update(t, now, {'state': hydroWire(next), 'hadLeaks': yes});
  });

  /// Raw, incomplete input is durable; canonical leaks are derived only when valid.
  Future<HydrostaticTest> saveLeakDraft(String id, String op, HydroJson draft) {
    final snapshot = hydroObject(jsonDecode(jsonEncode(draft)));
    validateHydroLeakDraft(snapshot);
    return _command(op, id, 'leakDraft', {'draft': snapshot}, (t, now) async {
      _state(t, HydrostaticTestState.leakDetailsPending);
      final leaks = <HydrostaticLeak>[];
      final leakIds = hydroObject(t!.toJson()['leakIds'] ?? {});
      for (final entry in hydroObject(snapshot['joints']).entries) {
        final row = hydroObject(entry.value);
        if (row['selected'] != true) continue;
        try {
          leaks.add(
            HydrostaticLeak(
              id: leakIds.putIfAbsent(entry.key, () => const Uuid().v4()),
              jointCode: entry.key,
              pressureMilliBar: parseHydrostaticBar(row['pressure']),
              description: row['description'],
            ),
          );
        } on HydrostaticException catch (e) {
          if (e.code != 'INVALID_PRESSURE') rethrow;
        }
      }
      return _update(t, now, {
        'leakIds': leakIds,
        'leakDraft': snapshot,
        'leaks': leaks.map((e) => e.toJson()).toList(),
      });
    });
  }

  Future<HydrostaticTest> linkLeakEvidence(
    String id,
    String op,
    String evidenceId,
    List<String> codes,
  ) => _command(
    op,
    id,
    'linkLeakEvidence',
    {'evidenceId': evidenceId, 'codes': codes},
    (t, now) async {
      _state(t, HydrostaticTestState.leakDetailsPending);
      hydroRequire(
        codes.toSet().length == codes.length &&
            codes.every(
              (c) => HydrostaticJoint.catalog.any((j) => j.code == c),
            ),
        'INVALID_JOINT',
        'Unión inválida.',
      );
      hydroRequire(
        t!.evidence.any(
          (e) =>
              e.id == evidenceId &&
              e.role == HydrostaticEvidenceRole.leakEvidence,
        ),
        'INVALID_EVIDENCE',
        'Fotografía de fuga no encontrada.',
      );
      return _update(t, now, {
        'evidence': t.evidence
            .map(
              (e) => e.id == evidenceId
                  ? {...e.toJson(), 'jointCodes': codes}
                  : e.toJson(),
            )
            .toList(),
      });
    },
  );

  Future<HydrostaticTest> saveLeaks(
    String id,
    String op,
    List<HydrostaticLeak> leaks, {
    int? expectedRevision,
  }) => _command(
    op,
    id,
    'leaks',
    {'leaks': leaks.map((e) => e.toJson()).toList()},
    (t, now) async {
      _state(t, HydrostaticTestState.leakDetailsPending);
      hydroRequire(
        leaks.map((e) => e.jointCode).toSet().length == leaks.length,
        'INVALID_JOINT',
        'Una entrada por unión.',
      );
      return _update(t!, now, {'leaks': leaks.map((e) => e.toJson()).toList()});
    },
    expectedRevision: expectedRevision,
  );
  Future<HydrostaticTest> closeLeak(String id, String op) =>
      _command(op, id, 'closeLeak', {}, (t, now) async {
        if (t?.state == HydrostaticTestState.failed) return t!.toJson();
        _state(t, HydrostaticTestState.leakDetailsPending);
        await validateLeak(t!);
        hydroRequire(
          !resultExpired(t),
          'RESULT_EXPIRED',
          'Venció el plazo durante la validación.',
        );
        now = clock.now();
        _transition(t, HydrostaticTestState.failed);
        return _update(t, now, {
          'state': 'FAILED',
          'result': 'LEAK',
          'closedAt': now.utc.toUtc().toIso8601String(),
        });
      });
  void _closureReady(String id) {
    hydroRequire(
      !store.recoveryRequired &&
          !isCapturing(id) &&
          !store.metadata.keys
              .where((key) => '$key'.startsWith('capture:'))
              .map((key) => store.read(store.metadata, '$key')!)
              .any(
                (r) =>
                    r['testId'] == id &&
                    !['LINKED', 'CANCELLED'].contains(r['state']),
              ),
      'RECOVERY_PENDING',
      'Hay capturas u operaciones pendientes de recuperación.',
    );
  }

  Future<void> validateLeak(HydrostaticTest t) async {
    access().requireUser(t.actor.userId);
    _closureReady(t.id);
    hydroRequire(
      !resultExpired(t),
      'RESULT_EXPIRED',
      'Prueba descartada: plazo de cierre vencido.',
    );
    _state(t, HydrostaticTestState.leakDetailsPending);
    if (t.toJson()['leakDraft'] != null) {
      final rows = hydroObject(
        hydroObject(t.toJson()['leakDraft'])['joints'],
      ).values.map(hydroObject).where((r) => r['selected'] == true).toList();
      hydroRequire(
        rows.length == t.leaks.length && rows.isNotEmpty,
        'LEAK_INCOMPLETE',
        'Completa la presión de cada unión seleccionada.',
      );
      for (final entry in hydroObject(
        hydroObject(t.toJson()['leakDraft'])['joints'],
      ).entries) {
        final row = hydroObject(entry.value);
        if (row['selected'] != true) continue;
        final leak = t.leaks.where((l) => l.jointCode == entry.key).firstOrNull;
        hydroRequire(
          leak != null &&
              leak.pressureMilliBar == parseHydrostaticBar(row['pressure']) &&
              leak.description == row['description'],
          'LEAK_INCOMPLETE',
          'El borrador y las uniones no coinciden.',
        );
      }
    }
    _validTime(t);
    hydroRequire(
      t.hadLeaks == true &&
          t.leaks.isNotEmpty &&
          t.leaks.every((e) => e.complete),
      'LEAK_INCOMPLETE',
      'Faltan uniones, presión o descripción de Otro.',
    );
    await _role(t, HydrostaticEvidenceRole.initialSetup);
    await _role(t, HydrostaticEvidenceRole.leakEvidence);
  }

  void _validTime(HydrostaticTest t) => hydroRequire(
    t.endedAt != null &&
        t.durationMs != null &&
        t.durationMs! >= 0 &&
        t.timeState != HydrostaticTimeState.needsReview &&
        _sinceEnd(t).state != HydrostaticTimeState.needsReview,
    'CLOCK_REVIEW_REQUIRED',
    'Duración pendiente de revisión.',
  );
  Future<void> validatePass(HydrostaticTest t) async {
    access().requireUser(t.actor.userId);
    _closureReady(t.id);
    hydroRequire(
      !resultExpired(t),
      'RESULT_EXPIRED',
      'Prueba descartada: plazo de cierre vencido.',
    );
    _state(t, HydrostaticTestState.approvalEvidencePending);
    approvalPolicy.requireConfigured();
    _validTime(t);
    for (final role in [
      HydrostaticEvidenceRole.initialSetup,
      HydrostaticEvidenceRole.manometer5Bar,
      HydrostaticEvidenceRole.final4Bar,
    ]) {
      await _role(t, role);
    }
    final valid = <HydrostaticEvidence>[];
    for (final e in t.evidence) {
      if (e.ready && await files.verify(e)) valid.add(e);
    }
    final initials = valid.where(
      (e) =>
          e.role == HydrostaticEvidenceRole.initialSetup &&
          !e.capturedAt.isAfter(t.startedAt!),
    );
    final fives = valid.where(
      (e) =>
          e.role == HydrostaticEvidenceRole.manometer5Bar &&
          !e.capturedAt.isBefore(t.startedAt!) &&
          !e.capturedAt.isAfter(t.endedAt!) &&
          e.location?.validAt(e.capturedAt, photo: true) == true,
    );
    final finals = valid.where(
      (e) =>
          e.role == HydrostaticEvidenceRole.final4Bar &&
          approvalPolicy.accepts(t.endedAt!, e.capturedAt),
    );
    final coherent = initials.any(
      (initial) => fives.any(
        (five) => finals.any(
          (last) =>
              five.captureIntentId != last.captureIntentId &&
              five.originalPath != last.originalPath &&
              five.sha256 != last.sha256 &&
              initial.captureIntentId != five.captureIntentId &&
              !last.capturedAt.isBefore(five.capturedAt),
        ),
      ),
    );
    hydroRequire(
      coherent,
      'EVIDENCE_CHRONOLOGY',
      'Secuencia inicial/5 bar/4 bar, capturas distintas y GPS requeridos.',
    );
  }

  Future<HydrostaticTest> closePass(String id, String op) =>
      _command(op, id, 'closePass', {}, (t, now) async {
        if (t?.state == HydrostaticTestState.passed) return t!.toJson();
        _state(t, HydrostaticTestState.approvalEvidencePending);
        await validatePass(t!);
        hydroRequire(
          !resultExpired(t),
          'RESULT_EXPIRED',
          'Venció el plazo durante la validación.',
        );
        now = clock.now();
        _transition(t, HydrostaticTestState.passed);
        return _update(t, now, {
          'state': 'PASSED',
          'approvalPolicy': approvalPolicy.toJson(),
          'result': 'PASS',
          'closedAt': now.utc.toUtc().toIso8601String(),
          'video': const HydrostaticVideoDeclaration(
            HydrostaticVideoState.pending,
          ).toJson(),
        });
      });
  Future<HydrostaticTest> declareVideoSent(String id, String op) =>
      _command(op, id, 'video', {}, (t, now) async {
        _state(t, HydrostaticTestState.passed);
        if (t!.video.state == HydrostaticVideoState.declaredSent) {
          return t.toJson();
        }
        return _update(t, now, {
          'video': HydrostaticVideoDeclaration(
            HydrostaticVideoState.declaredSent,
            actorId: t.actor.userId,
            declaredAt: now.utc,
            operationId: op,
          ).toJson(),
        });
      });

  Future<void> _uncertainClose(HydroJson entry, String reason) async {
    final current = store.test(entry['testId'])!;
    final after = _update(current, clock.now(), {
      'executionTimeState': hydroWire(current.timeState),
      'timeState': 'NEEDS_REVIEW',
      'temporalReview': {'reason': reason, 'operationId': entry['operationId']},
      'anomalies': [
        ...List<String>.from(current.toJson()['anomalies']),
        reason,
      ],
    });
    final review = {
      ...entry,
      'type': 'timeReview',
      'uncertainCloseCandidate': {
        'type': entry['type'],
        'after': entry['after'],
      },
      'phase': 'RECOVERABLE',
      'after': after,
    };
    await journal.save(review, 'reviewReady');
    await _apply(review);
  }

  Future<void> _apply(HydroJson entry) async {
    if (entry['type'] == 'delete') {
      await _applyDelete(entry);
      return;
    }
    final after = HydrostaticTest.fromJson(hydroObject(entry['after']));
    final current = store.test(after.id);
    hydroRequire(
      current == null ||
          current.revision == entry['beforeRevision'] ||
          canonicalHydroJson(current.toJson()) ==
              canonicalHydroJson(after.toJson()),
      'RECOVERY_CONFLICT',
      'El documento difiere del journal comprometido.',
    );
    if (entry['sequence'] != null) {
      final seq = hydroObject(entry['sequence']);
      await sequences.reserve(seq['uid'], seq['number']);
    }
    await store.write(
      store.documents,
      'test:${after.id}',
      after.toJson(),
      'document',
    );
    await _index();
    await journal.save({...entry, 'phase': 'APPLIED'}, 'applied');
  }

  Future<void> _index() async {
    final byCabinet = <String, List<String>>{},
        byActor = <String, List<String>>{};
    for (final t in store.all()) {
      if (store.read(store.metadata, 'delete:${t.id}') != null) continue;
      (byActor[t.actor.userId] ??= []).add(t.id);
      if (t.attemptNumber != null) (byCabinet[t.cabinet.uid] ??= []).add(t.id);
    }
    await store.write(store.metadata, 'indexes', {
      'byCabinet': byCabinet,
      'byActor': byActor,
    }, 'indexes');
  }

  Future<void> rebuildIndexes() => store.serial(_index);

  /// Replays committed local operations under their original attribution; it
  /// never executes a new business command or accesses a remote service.
  Future<void> recover() => store.serial(() async {
    try {
      for (final entry in journal.entries) {
        if (entry['phase'] == 'APPLIED' || entry['phase'] == 'ERROR') continue;
        if (entry['phase'] == 'PREPARED') {
          await journal.save({
            ...entry,
            'phase': 'ERROR',
            'error': 'INTERRUPTED_BEFORE_COMMIT',
          }, 'abandoned');
        } else if (entry['phase'] == 'CLOSE_PENDING_TIME') {
          await _uncertainClose(entry, 'CLOSE_COMMIT_TIME_UNKNOWN');
        } else if (['APPLY_READY', 'RECOVERABLE'].contains(entry['phase'])) {
          if (['closePass', 'closeLeak'].contains(entry['type']) &&
              entry['closeWitness'] == null &&
              store.test(entry['testId'])?.closedAt == null) {
            await _uncertainClose(entry, 'LEGACY_CLOSE_TIME_UNVERIFIABLE');
          } else {
            await _apply(entry);
          }
        } else {
          throw const HydrostaticException(
            'CORRUPT_JOURNAL',
            'Fase desconocida.',
          );
        }
      }
      await _index();
      store.recoveryRequired = false;
    } catch (_) {
      store.recoveryRequired = true;
      rethrow;
    }
  });

  Future<HydrostaticDeleteReceipt> deleteLocal(
    String id,
    String op, {
    required String confirmedTestId,
  }) => store.serial(() async {
    hydroUuid(id);
    hydroUuid(op);
    development.requireDeletion();
    final a = access();
    a.requireUser(a.actor.userId);
    hydroRequire(
      confirmedTestId == id,
      'CONFIRMATION_REQUIRED',
      'Confirma el UUID exacto.',
    );
    hydroRequire(
      store.read(store.metadata, 'syncProtected:$id') == null,
      'SYNC_PROTECTED',
      'El expediente tiene entrega pendiente o recibos remotos; no puede eliminarse localmente.',
    );
    final old = store.read(store.metadata, 'delete:$id');
    if (old != null) {
      a.requireUser(old['actorId']);
      hydroRequire(
        old['state'] == 'COMPLETED',
        'RECOVERY_REQUIRED',
        'Eliminación en recuperación.',
      );
      return HydrostaticDeleteReceipt.fromJson(old);
    }
    hydroRequire(
      !store.recoveryRequired,
      'RECOVERY_REQUIRED',
      'Recupera operaciones pendientes.',
    );
    final t = store.test(id);
    hydroRequire(t != null, 'NOT_FOUND', 'Prueba ausente.');
    a.requireUser(t!.actor.userId);
    hydroRequire(
      ![
            HydrostaticTestState.active,
            HydrostaticTestState.starting,
          ].contains(t.state) &&
          !isCapturing(id),
      'BUSY',
      'Prueba/captura activa.',
    );
    final previous = journal.get(op);
    hydroRequire(
      previous == null ||
          (previous['phase'] == 'ERROR' &&
              previous['type'] == 'delete' &&
              previous['testId'] == id &&
              previous['actor'] == a.actor.userId),
      'IDEMPOTENCY_CONFLICT',
      'Operación ya utilizada.',
    );
    final receipt = HydrostaticDeleteReceipt(
      testId: id,
      operationId: op,
      actorId: a.actor.userId,
      state: HydrostaticDeletionState.requested,
      uid: t.cabinet.uid,
      number: t.attemptNumber,
    );
    final entry = <String, dynamic>{
      'operationId': op,
      'testId': id,
      'actor': a.actor.userId,
      'type': 'delete',
      'phase': 'PREPARED',
      'receipt': receipt.toJson(),
      'evidence': t.evidence.map((e) => e.toJson()).toList(),
    };
    try {
      await journal.save(entry, 'prepared');
      access().requireUser(a.actor.userId);
      await journal.save({...entry, 'phase': 'APPLY_READY'}, 'ready');
      await _applyDelete({...entry, 'phase': 'APPLY_READY'});
      return HydrostaticDeleteReceipt.fromJson(
        store.read(store.metadata, 'delete:$id')!,
      );
    } catch (_) {
      store.recoveryRequired = true;
      rethrow;
    }
  });
  Future<void> _applyDelete(HydroJson entry) async {
    development.requireDeletion();
    final receipt = hydroObject(entry['receipt']);
    final id = receipt['testId'] as String;
    hydroRequire(!isCapturing(id), 'BUSY', 'Captura activa.');
    await store.write(store.metadata, 'delete:$id', receipt, 'deleteRequested');
    final evidence = (entry['evidence'] as List)
        .map((e) => HydrostaticEvidence.fromJson(hydroObject(e)))
        .toList();
    final protected = store
        .all()
        .where((t) => t.id != id)
        .expand((t) => t.evidence.map((e) => e.originalPath))
        .toSet();
    await store.fault?.call('before:files');
    await files.removeExclusive(id, evidence, protected);
    await store.fault?.call('after:files');
    await store.write(store.metadata, 'delete:$id', {
      ...receipt,
      'state': 'FILES_REMOVED',
    }, 'filesRemoved');
    await store.remove(store.documents, 'test:$id', 'deleteDocument');
    // Remove payloads/photos from old receipts, retaining minimal idempotency markers.
    for (final previous in journal.entries.where(
      (e) => e['testId'] == id && e['operationId'] != entry['operationId'],
    )) {
      await journal.save({
        'operationId': previous['operationId'],
        'testId': id,
        'actor': previous['actor'],
        'type': 'deleted',
        'phase': 'APPLIED',
      }, 'scrub');
    }
    await _index();
    final completed = {...receipt, 'state': 'COMPLETED'};
    await store.write(
      store.metadata,
      'delete:$id',
      completed,
      'deleteCompleted',
    );
    await journal.save({
      'operationId': entry['operationId'],
      'testId': id,
      'actor': entry['actor'],
      'type': 'deleted',
      'phase': 'APPLIED',
      'receipt': completed,
    }, 'applied');
  }
}
