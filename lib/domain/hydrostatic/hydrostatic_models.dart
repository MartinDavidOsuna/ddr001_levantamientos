import 'dart:convert';
import '../cabinets/cabinet_models.dart' show cabinetUid;

typedef HydroJson = Map<String, dynamic>;

class HydrostaticException implements Exception {
  const HydrostaticException(this.code, this.message);
  final String code, message;
  @override
  String toString() => '$code: $message';
}

void hydroRequire(bool condition, String code, String message) {
  if (!condition) throw HydrostaticException(code, message);
}

String hydroUuid(String value) {
  hydroRequire(
    RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).hasMatch(value),
    'INVALID_ID',
    'UUID v4 canónico requerido.',
  );
  return value;
}

/// Existing server identities are SQL GUIDs, not necessarily RFC UUID v4.
/// Validate their canonical representation without changing identity bytes.
/// Locally generated test/operation/evidence/installation IDs use hydroUuid.
String hydroIdentityGuid(String value, {required String field}) {
  hydroRequire(
    RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(value) &&
        value != '00000000-0000-0000-0000-000000000000',
    'INVALID_ID',
    'GUID canónico requerido para $field.',
  );
  return value;
}

DateTime hydroDate(Object? value) {
  final date = DateTime.parse(value as String);
  hydroRequire(date.isUtc, 'INVALID_TIME', 'Se requiere timestamp UTC.');
  return date;
}

HydroJson hydroObject(Object? v) => Map<String, dynamic>.from(v as Map);
String canonicalHydroJson(Object? value) {
  Object? sort(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: sort(v[k])};
    }
    if (v is List) return v.map(sort).toList();
    return v;
  }

  return jsonEncode(sort(value));
}

// Wire values are explicit and stable, independent of display translations.
enum HydrostaticTestState {
  preparation,
  starting,
  active,
  endedPendingResult,
  leakDetailsPending,
  approvalEvidencePending,
  failed,
  passed,
}

enum HydrostaticResult { pending, leak, pass }

enum HydrostaticEvidenceState {
  expected,
  capturing,
  pendingMetadata,
  ready,
  ambiguous,
}

enum HydrostaticIntegrity { unknown, verified, missing, corrupt }

enum HydrostaticVideoState { notApplicable, pending, declaredSent }

enum HydrostaticSyncState { localOnly }

enum HydrostaticDeletionState { none, requested, filesRemoved, completed }

enum HydrostaticTimeState { consistent, reconstructed, needsReview }

enum HydrostaticRecoveryState { clean, recovered, needsReview }

enum HydrostaticEvidenceRole {
  initialSetup,
  manometer5Bar,
  final4Bar,
  leakEvidence,
}

enum HydrostaticCaptureTimeSource { cameraMetadata, estimated, unknown }

enum HydrostaticLocationState { validated, pending, invalid }

String hydroWire(Enum e) =>
    e.name.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]}').toUpperCase();
T hydroEnum<T extends Enum>(Iterable<T> values, Object? name) =>
    values.firstWhere(
      (v) => hydroWire(v) == name,
      orElse: () => throw const HydrostaticException(
        'INVALID_DOCUMENT',
        'Estado desconocido.',
      ),
    );

class HydrostaticJoint {
  const HydrostaticJoint(this.code, this.name);
  final String code, name;
  static const version = 'hydrostatic-joints-v1';
  static const catalog = [
    HydrostaticJoint('J01', 'Conexión en bee principal'),
    HydrostaticJoint('J02', 'Juntas vitaulic'),
    HydrostaticJoint('J03', 'Conexiones v. angular'),
    HydrostaticJoint('J04', 'Conexión bee usuario'),
    HydrostaticJoint('J05', 'Manómetros'),
    HydrostaticJoint('J06', 'Filtro'),
    HydrostaticJoint('J07', 'Abrazadera venturi'),
    HydrostaticJoint('J08', 'Venturi'),
    HydrostaticJoint('J09', 'Accesorios'),
    HydrostaticJoint('J10', 'Válvulas parcelarias'),
    HydrostaticJoint('J11', 'Otro'),
  ];
}

int parseHydrostaticBar(String text) {
  final match = RegExp(r'^(\d+)(?:[.,](\d{1,3}))?$').firstMatch(text.trim());
  hydroRequire(
    match != null,
    'INVALID_PRESSURE',
    'Presión decimal de hasta tres decimales.',
  );
  final n = int.tryParse(match![1]!);
  hydroRequire(n != null && n <= 5, 'INVALID_PRESSURE', 'Rango 1–5 bar.');
  final value = n! * 1000 + int.parse((match[2] ?? '').padRight(3, '0'));
  hydroRequire(
    value >= 1000 && value <= 5000,
    'INVALID_PRESSURE',
    'Rango 1–5 bar.',
  );
  return value;
}

class HydrostaticCabinetSnapshot {
  HydrostaticCabinetSnapshot({
    required this.uid,
    required this.model,
    required this.automated,
    this.cabinetId,
    this.sourceVersion,
    this.knownStatus,
  }) {
    hydroRequire(
      cabinetUid(uid) == uid,
      'INVALID_UID',
      'UID canónico requerido.',
    );
    hydroRequire(
      ['A1', 'A2', 'A3', 'A4'].contains(model),
      'INVALID_MODEL',
      'Modelo inválido.',
    );
    if (cabinetId != null) hydroUuid(cabinetId!);
  }
  final String uid, model;
  final bool automated;
  final String? cabinetId;
  final int? sourceVersion;
  final String? knownStatus;
  HydroJson toJson() => {
    'uid': uid,
    'model': model,
    'automated': automated,
    'cabinetId': cabinetId,
    'sourceVersion': sourceVersion,
    'knownStatus': knownStatus,
  };
  factory HydrostaticCabinetSnapshot.fromJson(HydroJson j) =>
      HydrostaticCabinetSnapshot(
        uid: j['uid'],
        model: j['model'],
        automated: j['automated'],
        cabinetId: j['cabinetId'],
        sourceVersion: j['sourceVersion'],
        knownStatus: j['knownStatus'],
      );
}

class HydrostaticActorSnapshot {
  HydrostaticActorSnapshot({
    required this.userId,
    required this.name,
    required this.sessionId,
    required this.deviceInstallationId,
  }) {
    hydroIdentityGuid(userId, field: 'userId');
    hydroIdentityGuid(sessionId, field: 'sessionId');
    hydroUuid(deviceInstallationId);
    hydroRequire(name.trim().isNotEmpty, 'INVALID_ACTOR', 'Nombre requerido.');
  }
  final String userId, name, sessionId, deviceInstallationId;
  HydroJson toJson() => {
    'userId': userId,
    'name': name,
    'sessionId': sessionId,
    'deviceInstallationId': deviceInstallationId,
  };
  factory HydrostaticActorSnapshot.fromJson(HydroJson j) =>
      HydrostaticActorSnapshot(
        userId: j['userId'],
        name: j['name'],
        sessionId: j['sessionId'],
        deviceInstallationId: j['deviceInstallationId'],
      );
}

class HydrostaticLocation {
  const HydrostaticLocation({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.fixAt,
    required this.acquiredAt,
    required this.source,
    this.state = HydrostaticLocationState.validated,
  });
  final double latitude, longitude, accuracy;
  final DateTime fixAt, acquiredAt;
  final String source;
  final HydrostaticLocationState state;
  bool validAt(DateTime at, {bool photo = false}) =>
      state == HydrostaticLocationState.validated &&
      latitude.isFinite &&
      longitude.isFinite &&
      accuracy.isFinite &&
      latitude.abs() <= 90 &&
      longitude.abs() <= 180 &&
      accuracy > 0 &&
      accuracy <= 100 &&
      source.trim().isNotEmpty &&
      fixAt.isUtc &&
      acquiredAt.isUtc &&
      !acquiredAt.isBefore(fixAt) &&
      fixAt.difference(at).inMilliseconds >= -60000 &&
      fixAt.difference(at).inMilliseconds <= (photo ? 120000 : 0) &&
      (photo || !acquiredAt.isAfter(at));
  HydroJson toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    'fixAt': fixAt.toUtc().toIso8601String(),
    'acquiredAt': acquiredAt.toUtc().toIso8601String(),
    'source': source,
    'state': hydroWire(state),
  };
  factory HydrostaticLocation.fromJson(HydroJson j) => HydrostaticLocation(
    latitude: (j['latitude'] as num).toDouble(),
    longitude: (j['longitude'] as num).toDouble(),
    accuracy: (j['accuracy'] as num).toDouble(),
    fixAt: hydroDate(j['fixAt']),
    acquiredAt: hydroDate(j['acquiredAt']),
    source: j['source'],
    state: hydroEnum(HydrostaticLocationState.values, j['state']),
  );
}

class HydrostaticLeak {
  HydrostaticLeak({
    required this.id,
    required this.jointCode,
    required this.pressureMilliBar,
    this.description = '',
  }) {
    hydroUuid(id);
    hydroRequire(
      HydrostaticJoint.catalog.any((j) => j.code == jointCode),
      'INVALID_JOINT',
      'Unión desconocida.',
    );
    hydroRequire(
      pressureMilliBar >= 1000 && pressureMilliBar <= 5000,
      'INVALID_PRESSURE',
      'Rango 1–5 bar.',
    );
  }
  final String id, jointCode, description;
  final int pressureMilliBar;
  bool get complete => jointCode != 'J11' || description.trim().isNotEmpty;
  HydroJson toJson() => {
    'id': id,
    'jointCode': jointCode,
    'pressureMilliBar': pressureMilliBar,
    'description': description,
  };
  factory HydrostaticLeak.fromJson(HydroJson j) => HydrostaticLeak(
    id: j['id'],
    jointCode: j['jointCode'],
    pressureMilliBar: j['pressureMilliBar'],
    description: j['description'],
  );
}

class HydrostaticEvidence {
  HydrostaticEvidence({
    required this.id,
    required this.testId,
    required this.captureIntentId,
    required this.actorId,
    required this.role,
    required this.originalPath,
    required this.sha256,
    required this.byteLength,
    required this.capturedAt,
    required this.timeSource,
    this.returnedAt,
    this.recovered = false,
    this.location,
    this.state = HydrostaticEvidenceState.expected,
    this.integrity = HydrostaticIntegrity.unknown,
    List<String> jointCodes = const [],
  }) : jointCodes = List.unmodifiable(jointCodes) {
    hydroUuid(id);
    hydroUuid(testId);
    hydroUuid(captureIntentId);
    hydroIdentityGuid(actorId, field: 'actorId');
    hydroRequire(
      RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) && byteLength > 0,
      'INVALID_EVIDENCE',
      'Hash/tamaño inválidos.',
    );
    hydroRequire(
      capturedAt.isUtc &&
          originalPath.startsWith('hydrostatic/$testId/evidence/') &&
          !originalPath.contains('..') &&
          !originalPath.contains('\\') &&
          originalPath.split('/').length == 4 &&
          originalPath.split('/').last.isNotEmpty,
      'INVALID_PATH',
      'Ruta exclusiva de la prueba requerida.',
    );
    hydroRequire(
      jointCodes.toSet().length == jointCodes.length &&
          jointCodes.every(
            (c) => HydrostaticJoint.catalog.any((j) => j.code == c),
          ),
      'INVALID_JOINT',
      'Relación de evidencia inválida.',
    );
  }
  final String id, testId, captureIntentId, actorId, originalPath, sha256;
  final int byteLength;
  final DateTime capturedAt;
  final DateTime? returnedAt;
  final bool recovered;
  final HydrostaticEvidenceRole role;
  final HydrostaticCaptureTimeSource timeSource;
  final HydrostaticLocation? location;
  final HydrostaticEvidenceState state;
  final HydrostaticIntegrity integrity;
  final List<String> jointCodes;
  bool get ready =>
      state == HydrostaticEvidenceState.ready &&
      integrity == HydrostaticIntegrity.verified &&
      timeSource != HydrostaticCaptureTimeSource.unknown;
  HydroJson toJson() => {
    'id': id,
    'testId': testId,
    'captureIntentId': captureIntentId,
    'actorId': actorId,
    'role': hydroWire(role),
    'originalPath': originalPath,
    'sha256': sha256,
    'byteLength': byteLength,
    'capturedAt': capturedAt.toIso8601String(),
    'returnedAt': returnedAt?.toUtc().toIso8601String(),
    'recovered': recovered,
    'timeSource': hydroWire(timeSource),
    'location': location?.toJson(),
    'state': hydroWire(state),
    'integrity': hydroWire(integrity),
    'jointCodes': jointCodes,
  };
  factory HydrostaticEvidence.fromJson(HydroJson j) => HydrostaticEvidence(
    id: j['id'],
    testId: j['testId'],
    captureIntentId: j['captureIntentId'],
    actorId: j['actorId'],
    role: hydroEnum(HydrostaticEvidenceRole.values, j['role']),
    originalPath: j['originalPath'],
    sha256: j['sha256'],
    byteLength: j['byteLength'],
    capturedAt: hydroDate(j['capturedAt']),
    returnedAt: j['returnedAt'] == null ? null : hydroDate(j['returnedAt']),
    recovered: j['recovered'] == true,
    timeSource: hydroEnum(HydrostaticCaptureTimeSource.values, j['timeSource']),
    location: j['location'] == null
        ? null
        : HydrostaticLocation.fromJson(hydroObject(j['location'])),
    state: hydroEnum(HydrostaticEvidenceState.values, j['state']),
    integrity: hydroEnum(HydrostaticIntegrity.values, j['integrity']),
    jointCodes: (j['jointCodes'] as List).cast<String>(),
  );
}

class HydrostaticVideoDeclaration {
  const HydrostaticVideoDeclaration(
    this.state, {
    this.actorId,
    this.declaredAt,
    this.operationId,
  });
  final HydrostaticVideoState state;
  final String? actorId, operationId;
  final DateTime? declaredAt;
  HydroJson toJson() => {
    'state': hydroWire(state),
    'actorId': actorId,
    'declaredAt': declaredAt?.toUtc().toIso8601String(),
    'operationId': operationId,
  };
  factory HydrostaticVideoDeclaration.fromJson(HydroJson j) {
    final state = hydroEnum(HydrostaticVideoState.values, j['state']);
    if (state == HydrostaticVideoState.declaredSent) {
      hydroIdentityGuid(j['actorId'], field: 'actorId');
      hydroUuid(j['operationId']);
      hydroDate(j['declaredAt']);
    }
    return HydrostaticVideoDeclaration(
      state,
      actorId: j['actorId'],
      declaredAt: j['declaredAt'] == null ? null : hydroDate(j['declaredAt']),
      operationId: j['operationId'],
    );
  }
}

/// Immutable validated JSON aggregate. Public access returns copies; typed views
/// never alias stored lists/maps. Schema errors are surfaced, never defaulted.
class HydrostaticTest {
  HydrostaticTest._(this._json);
  final HydroJson _json;
  factory HydrostaticTest.fromJson(HydroJson input) {
    final j = hydroObject(jsonDecode(jsonEncode(input)));
    hydroRequire(
      j['schemaVersion'] == 1,
      'SCHEMA_UNSUPPORTED',
      'Versión de documento no compatible.',
    );
    hydroUuid(j['id']);
    final actor = HydrostaticActorSnapshot.fromJson(hydroObject(j['actor']));
    HydrostaticCabinetSnapshot.fromJson(hydroObject(j['cabinet']));
    final state = hydroEnum(HydrostaticTestState.values, j['state']);
    final result = hydroEnum(HydrostaticResult.values, j['result']);
    hydroEnum(HydrostaticTimeState.values, j['timeState']);
    hydroEnum(HydrostaticRecoveryState.values, j['recoveryState']);
    hydroRequire(
      j['syncState'] == 'LOCAL_ONLY' && j['deletionState'] == 'NONE',
      'INVALID_DOCUMENT',
      'Documento de ejecución inválido.',
    );
    hydroRequire(
      j['revision'] is int &&
          j['revision'] >= 0 &&
          j['catalogVersion'] == HydrostaticJoint.version &&
          j['targetMilliBar'] == 5000 &&
          j['finalMilliBar'] == 4000,
      'INVALID_DOCUMENT',
      'Versión/presiones inválidas.',
    );
    hydroDate(j['createdAt']);
    hydroDate(j['updatedAt']);
    final started = ![
      HydrostaticTestState.preparation,
      HydrostaticTestState.starting,
    ].contains(state);
    hydroRequire(
      started == (j['startedAt'] != null) &&
          started == (j['attemptNumber'] != null),
      'INVALID_DOCUMENT',
      'Inicio y consecutivo incoherentes.',
    );
    if (started) {
      hydroDate(j['startedAt']);
      hydroRequire(
        j['attemptNumber'] is int && j['attemptNumber'] > 0,
        'INVALID_DOCUMENT',
        'Consecutivo inválido.',
      );
      HydrostaticLocation.fromJson(hydroObject(j['location']));
      hydroObject(j['startClock']);
    }
    final ended = started && state != HydrostaticTestState.active;
    hydroRequire(
      ended == (j['endedAt'] != null),
      'INVALID_DOCUMENT',
      'Fin incoherente.',
    );
    if (ended) {
      hydroDate(j['endedAt']);
      hydroRequire(
        j['durationMs'] is int,
        'INVALID_DOCUMENT',
        'Duración requerida.',
      );
    }
    hydroRequire(
      result ==
          (state == HydrostaticTestState.passed
              ? HydrostaticResult.pass
              : state == HydrostaticTestState.failed
              ? HydrostaticResult.leak
              : HydrostaticResult.pending),
      'INVALID_DOCUMENT',
      'Resultado incompatible.',
    );
    final video = HydrostaticVideoDeclaration.fromJson(hydroObject(j['video']));
    hydroRequire(
      state == HydrostaticTestState.passed
          ? video.state != HydrostaticVideoState.notApplicable
          : video.state == HydrostaticVideoState.notApplicable,
      'INVALID_DOCUMENT',
      'Video incompatible.',
    );
    final evidence = (j['evidence'] as List)
        .map((e) => HydrostaticEvidence.fromJson(hydroObject(e)))
        .toList();
    hydroRequire(
      evidence.every((e) => e.testId == j['id'] && e.actorId == actor.userId) &&
          evidence.map((e) => e.id).toSet().length == evidence.length,
      'INVALID_DOCUMENT',
      'Evidencia de otro expediente/actor o duplicada.',
    );
    final leaks = (j['leaks'] as List)
        .map((e) => HydrostaticLeak.fromJson(hydroObject(e)))
        .toList();
    hydroRequire(
      leaks.map((e) => e.jointCode).toSet().length == leaks.length,
      'INVALID_DOCUMENT',
      'Unión repetida.',
    );
    if (state == HydrostaticTestState.leakDetailsPending ||
        state == HydrostaticTestState.failed) {
      hydroRequire(
        j['hadLeaks'] == true,
        'INVALID_DOCUMENT',
        'Respuesta incompatible.',
      );
    }
    if (state == HydrostaticTestState.approvalEvidencePending ||
        state == HydrostaticTestState.passed) {
      hydroRequire(
        j['hadLeaks'] == false,
        'INVALID_DOCUMENT',
        'Respuesta incompatible.',
      );
    }
    if (j['discardedAt'] != null) {
      hydroDate(j['discardedAt']);
      hydroRequire(
        ended &&
            j['closedAt'] == null &&
            j['discardReason'] == 'RESULT_DEADLINE_EXCEEDED',
        'INVALID_DOCUMENT',
        'Descarte incompatible.',
      );
    }
    if (j['leakDraft'] != null) {
      validateHydroLeakDraft(hydroObject(j['leakDraft']));
    }
    (j['anomalies'] as List).cast<String>();
    return HydrostaticTest._(j);
  }
  HydroJson toJson() => hydroObject(jsonDecode(jsonEncode(_json)));
  String get id => _json['id'];
  int get revision => _json['revision'];
  int? get attemptNumber => _json['attemptNumber'];
  HydrostaticTestState get state =>
      hydroEnum(HydrostaticTestState.values, _json['state']);
  HydrostaticResult get result =>
      hydroEnum(HydrostaticResult.values, _json['result']);
  HydrostaticTimeState get timeState =>
      hydroEnum(HydrostaticTimeState.values, _json['timeState']);
  HydrostaticActorSnapshot get actor =>
      HydrostaticActorSnapshot.fromJson(hydroObject(_json['actor']));
  HydrostaticCabinetSnapshot get cabinet =>
      HydrostaticCabinetSnapshot.fromJson(hydroObject(_json['cabinet']));
  DateTime? get startedAt =>
      _json['startedAt'] == null ? null : hydroDate(_json['startedAt']);
  DateTime? get endedAt =>
      _json['endedAt'] == null ? null : hydroDate(_json['endedAt']);
  DateTime? get closedAt =>
      _json['closedAt'] == null ? null : hydroDate(_json['closedAt']);
  int? get durationMs => _json['durationMs'];
  bool get isDiscarded => _json['discardedAt'] != null;
  DateTime? get discardedAt =>
      _json['discardedAt'] == null ? null : hydroDate(_json['discardedAt']);
  bool? get hadLeaks => _json['hadLeaks'];
  List<HydrostaticEvidence> get evidence => List.unmodifiable(
    (_json['evidence'] as List).map(
      (v) => HydrostaticEvidence.fromJson(hydroObject(v)),
    ),
  );
  List<HydrostaticLeak> get leaks => List.unmodifiable(
    (_json['leaks'] as List).map(
      (v) => HydrostaticLeak.fromJson(hydroObject(v)),
    ),
  );
  HydrostaticVideoDeclaration get video =>
      HydrostaticVideoDeclaration.fromJson(hydroObject(_json['video']));
}

class HydrostaticStateMachine {
  static const transitions = {
    HydrostaticTestState.preparation: {HydrostaticTestState.starting},
    HydrostaticTestState.starting: {
      HydrostaticTestState.preparation,
      HydrostaticTestState.active,
    },
    HydrostaticTestState.active: {HydrostaticTestState.endedPendingResult},
    HydrostaticTestState.endedPendingResult: {
      HydrostaticTestState.leakDetailsPending,
      HydrostaticTestState.approvalEvidencePending,
    },
    HydrostaticTestState.leakDetailsPending: {
      HydrostaticTestState.failed,
      HydrostaticTestState.approvalEvidencePending,
    },
    HydrostaticTestState.approvalEvidencePending: {
      HydrostaticTestState.passed,
      HydrostaticTestState.leakDetailsPending,
    },
  };
  static void requireTransition(
    HydrostaticTestState from,
    HydrostaticTestState to,
  ) => hydroRequire(
    transitions[from]?.contains(to) == true,
    'INVALID_STATE',
    'Transición no permitida: ${hydroWire(from)} → ${hydroWire(to)}.',
  );
}

/// Versioned raw editor input; invalid pressures are intentionally preservable.
void validateHydroLeakDraft(HydroJson draft) {
  hydroRequire(
    draft['version'] == 1 &&
        draft['observation'] is String &&
        draft['joints'] is Map,
    'INVALID_DRAFT',
    'Borrador inválido.',
  );
  for (final entry in hydroObject(draft['joints']).entries) {
    final row = hydroObject(entry.value);
    hydroRequire(
      HydrostaticJoint.catalog.any((j) => j.code == entry.key) &&
          row['selected'] is bool &&
          row['pressure'] is String &&
          row['description'] is String,
      'INVALID_DRAFT',
      'Unión de borrador inválida.',
    );
  }
}
