import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../../domain/cabinets/cabinet_models.dart';
import '../../recovery/cabinet_backup.dart' show payloadHash;
import 'cabinet_api.dart';
import 'cabinet_controller.dart';
import 'cabinet_legacy_scope.dart';
import 'legacy_cabinet_snapshot.dart';
import 'legacy_operation_diagnostic.dart';
import 'legacy_photo_diagnostic.dart';
import 'legacy_photo_confirmation.dart';
import 'legacy_receipt_confirmation.dart';
import 'legacy_checklist_confirmation.dart';
import 'legacy_checklist_plan.dart';
import 'legacy_derivative_evidence.dart';

class LegacyCabinetRecovery {
  LegacyCabinetRecovery(
    this.controller,
    this.cabinetId, {
    required Set<String> cabinetAllowlist,
    this.onProgress,
    this.automaticBatchPermit,
    this.derivativeEncoder = encodeLegacyJpeg,
  }) : _cabinetAllowlist = Set.unmodifiable(cabinetAllowlist);
  final Object? automaticBatchPermit;
  bool get automaticMode => automaticBatchPermit != null;
  int _historicalLength = 4;
  final void Function()? onProgress;
  final LegacyJpegEncoder derivativeEncoder;
  bool derivativeMode = false;
  final Map<String, LegacyDerivativeEvidence> derivatives = {};
  static const pilotOperations = [
    '37ad7f83-cfb9-4c88-a65b-cbe677034351',
    'e021bff6-edd1-452a-a4ac-a2772adb019b',
    '33718abb-9fb0-44ea-ba9b-609b10222e64',
    '3b078e96-2ea5-4405-b516-bf8fc5b04e89',
  ];
  final _existingHistoricalUploads = <String>{};
  Json _transport(Json photo) =>
      _existingHistoricalUploads.contains(photo['id'])
      ? photo
      : derivatives['${photo['id']}']?.transport ?? photo;

  final CabinetController controller;
  final String cabinetId;
  final Set<String> _cabinetAllowlist;
  Object? _lease;
  String? _actor, _session, _expectedRaw;
  late CabinetRemote _remote;
  LegacyCabinetSnapshot? backup;
  Json? server;
  final List<Json> _sequence = [];
  final List<String> blockers = [];
  LegacyChecklistPlan? checklistPlan;
  final Map<String, int> confirmedVersions = {};
  Json? _latestConfirmed;
  final List<String> results = [];
  final List<String> photoDiagnostics = [];
  final List<LegacyOperationDiagnostic> operationDiagnostics = [];
  List<Json> get sequence => _sequence.map(clone).toList();
  Set<String> get operationAllowlist =>
      _sequence.map((o) => '${object(o['body'])['operationId']}').toSet();
  bool busy = false, prepared = false, completed = false;
  bool metricsOnly = false;
  String get photoMetricsSummary =>
      "Métricas locales de fotografías · sin envío\nLímite productivo NO CERTIFICADO\n\n${photoDiagnostics.join("\n\n")}";
  bool _newStagesEligible = false;
  String? _reviewPolicy;
  bool get canPrepareNewStages =>
      !metricsOnly &&
      prepared &&
      !busy &&
      !completed &&
      _newStagesEligible &&
      _sequence.isEmpty;
  int? remoteVerifiedPhotos;
  int remoteMatchedPhotos = 0;
  bool remoteInventoryRead = false;
  String preparationPhase = 'antes de consultar el servidor';
  final _verifiedPhotoIds = <String>{};
  bool get canExecute =>
      !metricsOnly &&
      prepared &&
      blockers.isEmpty &&
      !busy &&
      !completed &&
      _sequence.isNotEmpty;
  String? get backupPath => backup?.directory.path;
  Json get local => controller.store.read(cabinetId)?.working ?? {};
  final _approvedHashes = <String, String>{};
  final _registerReceipts = <String, Json>{};

  void _check() {
    if (controller.actor != _actor ||
        controller.app.session?.sessionId != _session) {
      throw StateError('SUPPORT_SESSION_CHANGED');
    }
    if (!controller.allowed) throw StateError('SUPPORT_ROLE_DENIED');
    if (automaticMode) {
      controller.checkAutomaticHistoricalBatch(automaticBatchPermit!);
    }
    if (_lease == null || !controller.ownsLegacySupport(_lease!)) {
      throw StateError('SUPPORT_LOCK_LOST');
    }
    if (_cabinetAllowlist.length != 1 ||
        !_cabinetAllowlist.contains(cabinetId)) {
      throw StateError('SUPPORT_SCOPE_DENIED');
    }
    if (_expectedRaw != null &&
        controller.store.box.get('cabinet:$cabinetId') != _expectedRaw) {
      throw StateError('El expediente cambió fuera de la recuperación.');
    }
  }

  Future<Json> _get(String path, [Json? query]) async {
    _check();
    final result = await _remote.get(path, query);
    _check();
    return clone(result);
  }

  void _identity(Json remote) {
    final r = controller.store.read(cabinetId)!;
    if (automaticMode &&
        (remote['model'] != r.working['model'] ||
            remote['automated'] != r.working['automated'] ||
            remote['catalogVersion'] != r.working['catalogVersion'])) {
      throw StateError('LEGACY_MODEL_CATALOG_MISMATCH');
    }
    if ('${remote['cabinetId']}'.toLowerCase() != cabinetId ||
        remote['uid'] != r.working['uid']) {
      throw StateError(
        'UID/cabinetId remoto no corresponde; no se crea otro expediente.',
      );
    }
  }

  Future<Json?> _receipt(Json body) async {
    try {
      return await _get('/$cabinetId/operations/${body['operationId']}');
    } on DioException catch (e) {
      if (e.response?.statusCode == 404 &&
          CabinetController.problemData(e.response?.data)['code'] ==
              'OPERATION_NOT_FOUND') {
        return null;
      }
      rethrow;
    }
  }

  void _validateReceipt(Json receipt, Json body, {bool requireStage = true}) {
    final c = object(receipt['cabinet']);
    _identity(c);
    if (c['version'] != (body['expectedVersion'] as num) + 1) {
      throw StateError('Recibo incompatible con versión original.');
    }
    if (!requireStage) return;
    if (derivativeMode &&
        body['type'] == 'registration_close' &&
        payloadHash(c['registrationEvidence']) !=
            payloadHash(body['evidence'])) {
      throw StateError('LEGACY_RECEIPT_EVIDENCE_MISMATCH');
    }
    if (derivativeMode && body['type'] == 'parts_save') {
      final differences = legacyChecklistDifferences(body['parts'], c['parts']);
      if (differences.isNotEmpty) {
        throw StateError(
          'LEGACY_RECEIPT_CHECKLIST_MISMATCH: ${differences.take(8).join('; ')}; '
          'diferencias=${differences.length}. Recibo conservado; no se continúa.',
        );
      }
      if (c['status'] != 'incomplete') {
        throw StateError('LEGACY_RECEIPT_STAGE_MISMATCH');
      }
    }
    if (body['type'] == 'registration_close' && c['status'] != 'registered') {
      throw StateError('Recibo sin cierre de registro.');
    }
    if (body['type'] == 'parts_validate' &&
        (c['status'] != 'validated' || c['partsValidated'] != true)) {
      throw StateError(
        'El servidor no validó la revisión; no se fuerza el estado.',
      );
    }
  }

  void _requireCurrentReceipt(Json current, Json? receipt) {
    if (current['version'] == 1) return;
    if (receipt == null ||
        receipt['version'] != current['version'] ||
        receipt['status'] != current['status'] ||
        receipt['partsValidated'] != current['partsValidated'] ||
        legacyChecklistDifferences(
          receipt['parts'],
          current['parts'],
        ).isNotEmpty ||
        legacyChecklistDifferences(
          current['parts'],
          receipt['parts'],
        ).isNotEmpty ||
        payloadHash(receipt['registrationEvidence']) !=
            payloadHash(current['registrationEvidence'])) {
      throw StateError('LEGACY_CURRENT_RECEIPT_MISMATCH');
    }
  }

  void _requireFinalChecklist(Json received) {
    if (checklistPlan == null ||
        legacyChecklistDifferences(
          checklistPlan!.merged,
          received['parts'],
        ).isNotEmpty ||
        legacyChecklistDifferences(
          received['parts'],
          checklistPlan!.merged,
        ).isNotEmpty ||
        partsPending(received).isNotEmpty) {
      throw StateError('LEGACY_CHECKLIST_FINAL_COVERAGE_MISMATCH');
    }
  }

  Set<String> _photoIds(Object? v) {
    final ids = <String>{};
    void walk(Object? x) {
      if (x is Map) {
        if (x['photoId'] is String) ids.add(x['photoId']);
        for (final y in x.values) {
          walk(y);
        }
      }
      if (x is List) {
        for (final y in x) {
          walk(y);
        }
      }
    }

    walk(v);
    return ids;
  }

  Future<List<Json>> _remotePhotos() async {
    final all = <Json>[];
    var page = 1;
    while (true) {
      final data = await _get('/$cabinetId/photos', {
        'page': page,
        'limit': 100,
      });
      final rows = objects(data['items']);
      all.addAll(rows);
      if (rows.length < 100) break;
      if (++page > 100) throw StateError('Inventario fotográfico incompleto.');
    }
    return all;
  }

  bool _matchingOriginal(Json row, Json photo) {
    Object? stable(Object? v) {
      if (v is num) return v.toDouble();
      if (v is Map) {
        final keys = v.keys.map((k) => '$k').toList()..sort();
        return {for (final k in keys) k: stable(v[k])};
      }
      if (v is List) return v.map(stable).toList();
      return v;
    }

    if (automaticMode &&
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch('${row['server_sha256']}')) {
      return false;
    }
    return '${row['client_sha256']}'.toLowerCase() ==
            object(photo['metadata'])['clientSha256'] &&
        '${row['actor_user_id']}'.toLowerCase() ==
            '${photo['actor']}'.toLowerCase() &&
        jsonEncode(stable(row['metadata'])) ==
            jsonEncode(stable(photo['metadata']));
  }

  Future<void> prepare({
    bool measureOnly = false,
    bool prepareDerivatives = false,
  }) async {
    if (busy || prepared || _lease != null) {
      throw StateError('Preparación ya iniciada.');
    }
    final initialRecord = controller.store.read(cabinetId);
    if (initialRecord == null ||
        !legacyCabinetUids.contains(initialRecord.working['uid']) ||
        ((measureOnly || prepareDerivatives) &&
            !(automaticMode
                ? legacyAutomaticUids.contains(
                    cabinetUid('${initialRecord.working['uid']}'),
                  )
                : initialRecord.working['uid'] == legacyPilotUid)) ||
        _cabinetAllowlist.length != 1 ||
        !_cabinetAllowlist.contains(cabinetId)) {
      throw StateError('Expediente fuera de soporte autorizado.');
    }
    if (automaticMode) {
      controller.checkAutomaticHistoricalBatch(automaticBatchPermit!);
      if (!prepareDerivatives || measureOnly) {
        throw StateError('AUTO_BATCH_PERMIT_REQUIRED');
      }
    }
    metricsOnly = measureOnly;
    derivativeMode = prepareDerivatives;
    if (measureOnly && prepareDerivatives) {
      throw StateError("Modes incompatibles");
    }
    busy = true;
    try {
      preparationPhase = 'adquisición de soporte; servidor no consultado';
      _actor = controller.actor;
      _session = controller.app.session?.sessionId;
      _lease = await controller.beginLegacySupport(cabinetId);
      _check();
      final record = controller.store.read(cabinetId)!;
      _expectedRaw = controller.store.box.get('cabinet:$cabinetId');
      _remote = controller.remote is CabinetApi
          ? (CabinetApi(controller.app.api)
              ..operationActor = _actor
              ..recoveryPermit = _lease
              ..recoverySessionId = _session?.toLowerCase())
          : controller.remote;
      _check();
      if (record.json['actor'] != _actor ||
          (record.json['draftActor'] != null &&
              record.json['draftActor'] != _actor)) {
        throw StateError(
          'Se requiere la sesión legítima del residente original.',
        );
      }
      if (measureOnly) {
        preparationPhase = 'medición local; servidor no consultado';
        final support = await controller.camera.supportDirectory();
        final directory = Directory('${support.path}/cabinets/$cabinetId');
        if (!await directory.exists()) {
          photoDiagnostics.add(
            'Directorio fotográfico no disponible; no se crea ni repara.',
          );
          prepared = true;
          return;
        }
        final root = await directory.resolveSymbolicLinks();
        final supportRoot = await support.resolveSymbolicLinks();
        if (root != '$supportRoot/cabinets/$cabinetId') {
          throw StateError(
            'Directorio fuera del expediente; no se realiza lectura.',
          );
        }
        for (final photo in record.photos) {
          _check();
          final journal = controller.store.media.journal.find('${photo['id']}');
          final source =
              journal?.sourcePath ?? '$root/evidence/${photo['id']}.source.jpg';
          var safe = true;
          for (final path in [source, photo['localPath']].whereType<String>()) {
            final file = File(path);
            if (!await file.exists()) continue;
            if (await FileSystemEntity.type(path, followLinks: false) !=
                    FileSystemEntityType.file ||
                !(await file.resolveSymbolicLinks()).startsWith('$root/')) {
              safe = false;
            }
          }
          if (!safe) {
            photoDiagnostics.add(
              'Archivo fuera del expediente o enlace no permitido; no se leyó.',
            );
            continue;
          }
          try {
            photoDiagnostics.add(
              await legacyPhotoDiagnostic(photo, File(source)),
            );
          } on FileSystemException {
            photoDiagnostics.add(
              'Lectura local no disponible; no se reparan archivos. Medición incompleta.',
            );
          }
          _check();
        }
        preparationPhase = 'medición local terminada; sin consultas ni envíos';
        prepared = true;
        return;
      }
      if (derivativeMode) {
        final historical = record.operations
            .where((o) => object(o['body'])['type'] != 'register')
            .toList();
        _historicalLength = historical.length;
        if (automaticMode) {
          if (historical.length < 3 ||
              historical.length > 100 ||
              record.photos.isEmpty ||
              historical.any(
                (o) => o['actor'] != _actor || o['state'] == 'superseded',
              )) {
            throw StateError('LEGACY_SEQUENCE_OR_ACTOR_INVALID');
          }
        } else if (historical.length != 4 ||
            record.photos.length != 5 ||
            historical.asMap().entries.any(
              (e) =>
                  object(e.value['body'])['operationId'] !=
                      pilotOperations[e.key] ||
                  object(e.value['body'])['expectedVersion'] != e.key + 1 ||
                  e.value['actor'] != _actor,
            ) ||
            object(historical.first['diagnostic'])['httpStatus'] != 413 ||
            !'${object(historical.first['diagnostic'])['path']}'.endsWith(
              '/photos',
            )) {
          throw StateError(
            'LEGACY_413_PLAN_MISMATCH: historial exacto o actor no corresponde.',
          );
        }
      }
      preparationPhase = 'consulta remota iniciada';
      final resolved = object(
        (await _get('/resolve', {'uid': record.working['uid']}))['cabinet'],
      );
      _identity(resolved);
      server = object((await _get('/$cabinetId'))['cabinet']);
      _identity(server!);
      if (derivativeMode) {
        if (server!['version'] is! int ||
            server!['version'] < 1 ||
            server!['version'] > _historicalLength + 1 ||
            resolved['version'] != server!['version'] ||
            resolved['status'] != server!['status']) {
          throw StateError('LEGACY_REMOTE_PROGRESS_MISMATCH');
        }
      } else if (server!['status'] != 'draft' ||
          server!['version'] != 1 ||
          resolved['version'] != 1 ||
          resolved['status'] != 'draft') {
        throw StateError(
          'Servidor fuera de draft/v1: revisar recibos y avance antes de otra recuperación.',
        );
      }
      preparationPhase = 'respaldo local; identidad remota consultada';
      backup = await LegacyCabinetSnapshot.create(
        store: controller.store,
        id: cabinetId,
        support: await controller.camera.supportDirectory(),
        assertLease: _check,
      );
      _check();
      for (final photo in record.photos) {
        final journal = controller.store.media.journal.find('${photo['id']}');
        final original = File(
          journal?.sourcePath ??
              '${(await controller.camera.supportDirectory()).path}/cabinets/$cabinetId/evidence/${photo['id']}.source.jpg',
        );
        photoDiagnostics.add(await legacyPhotoDiagnostic(photo, original));
        _check();
      }
      await backup!.verify();
      _check();
      if (derivativeMode) {
        final inventory = await _remotePhotos();
        final support = await controller.camera.supportDirectory();
        for (final photo in record.photos) {
          final id = '${photo['id']}';
          final row = inventory
              .where(
                (r) => '${r['photo_id'] ?? r['photoId']}'.toLowerCase() == id,
              )
              .firstOrNull;
          // A previously received historical upload can be retained with its exact
          // original metadata/hash. Never upload those oversized bytes again.
          if (automaticMode && row != null && _matchingOriginal(row, photo)) {
            _existingHistoricalUploads.add(id);
          }
          if (row != null && _matchingOriginal(row, _transport(photo))) {
            continue;
          }
          final journal = controller.store.media.journal.find(id);
          final source = File(
            journal?.sourcePath ??
                '${support.path}/cabinets/$cabinetId/evidence/$id.source.jpg',
          );
          derivatives[id] = await LegacyDerivativeEvidence.prepare(
            support: support,
            cabinetId: cabinetId,
            photo: photo,
            source: source,
            assertLease: _check,
            encoder: derivativeEncoder,
          );
          if (row != null && !_matchingOriginal(row, _transport(photo))) {
            throw StateError(
              'LEGACY_REMOTE_PHOTO_CONFLICT: no se sustituye evidencia existente.',
            );
          }
          await backup!.verify();
        }
      }
      final catalog = CabinetCatalog(
        await _get('/catalog', {'version': record.working['catalogVersion']}),
      );
      if (catalog.version != record.working['catalogVersion']) {
        blockers.add('Catálogo remoto distinto: revisar compatibilidad.');
      }
      if (!(automaticMode
          ? legacyAutomaticUids.contains(record.working['uid'])
          : record.working['uid'] == legacyPilotUid)) {
        blockers.add(
          'En esta candidata sólo se habilita el piloto AQ26-00006-8.',
        );
      }
      if (record.json['deletion'] != null ||
          record.json['archived'] == true ||
          record.photos.any((p) => p['deleting'] == true)) {
        blockers.add(
          'Hay eliminación/archivo pendiente; no se recupera automáticamente.',
        );
      }
      for (final op in record.operations) {
        final body = object(op['body']);
        if (body['type'] == 'register') {
          final result = await _receipt(body);
          if (result == null) {
            blockers.add(
              'Falta recibo original register; nunca se reenvía register.',
            );
          } else {
            _validateReceipt(result, body);
            _registerReceipts['${body['operationId']}'] = result;
          }
          continue;
        }
        if (op['state'] == 'superseded') continue;
        if (![
          'registration_close',
          'parts_save',
          'parts_validate',
        ].contains(body['type'])) {
          blockers.add(
            'Existen otras etapas históricas: requieren análisis separado.',
          );
          continue;
        }
        final diagnostic = LegacyOperationDiagnostic(
          op,
          actor: _actor,
          index: _sequence.length,
          photos: record.photos,
        );
        operationDiagnostics.add(diagnostic);
        if (derivativeMode &&
            diagnostic.compatibility.startsWith('revisar estructura')) {
          blockers.add(
            'LEGACY_PAYLOAD_INCOMPATIBLE: conservar el comando; no transmitir.',
          );
        }
        Json? result;
        try {
          result = await _receipt(body);
          diagnostic.receipt = result == null
              ? 'inexistente: 404 OPERATION_NOT_FOUND'
              : 'recibido; validación pendiente';
          if (result != null) {
            diagnostic.receipt =
                'recibido; identidad/versión/etapa por validar';
            _validateReceipt(result, body);
            confirmedVersions['${body['operationId']}'] =
                object(result['cabinet'])['version'] as int;
            _latestConfirmed = object(result['cabinet']);
            if (derivativeMode &&
                (body['expectedVersion'] as num) <
                    (server!['version'] as num)) {
              diagnostic.receipt =
                  'recibo confirmado; reconciliación sin retransmisión';
            } else {
              diagnostic.receipt =
                  'recibo válido pero discrepante con draft/v1';
              blockers.add(
                'Recibo avanzado con servidor v1: discrepancia, detener.',
              );
            }
          }
        } on DioException catch (e) {
          diagnostic.receipt =
              'consulta no concluyente: HTTP ${e.response?.statusCode ?? "sin respuesta"}';
          rethrow;
        }
        if (derivativeMode &&
            result == null &&
            (body['expectedVersion'] as num) < (server!['version'] as num)) {
          blockers.add(
            'LEGACY_RECEIPT_GAP: avance remoto sin recibo original.',
          );
        }
        final historical413 =
            derivativeMode &&
            (automaticMode
                ? body['type'] == 'registration_close' &&
                      diagnostic.http == '413' &&
                      diagnostic.historicalPhase ==
                          'carga fotográfica (antes del comando)' &&
                      (diagnostic.code == 'no conservado')
                : body['operationId'] == pilotOperations.first) &&
            op['state'] == 'conflict' &&
            result == null &&
            server!['version'] == 1 &&
            server!['status'] == 'draft';
        final restored =
            derivativeMode &&
            result != null &&
            (op['state'] == 'done' ||
                ((automaticMode
                        ? true // A compatible durable receipt proves acceptance, not a retry.
                        : body['operationId'] == pilotOperations.first) &&
                    op['state'] == 'conflict'));
        if (!['queued', 'sending'].contains(op['state']) &&
            !historical413 &&
            !restored) {
          blockers.add(
            'Comando rechazado/confirmado incompatible: conservar y revisar. Consulte el diagnóstico histórico; no se libera el conflicto.',
          );
        }
        if (op['actor'] != _actor) {
          blockers.add('Operación atribuida a otro actor.');
        }
        if (body['operationId'] is! String ||
            !RegExp(
              r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
            ).hasMatch(body['operationId'])) {
          blockers.add('operationId original no válido.');
        }
        _sequence.add(clone(op));
      }
      final types = _sequence.map((o) => object(o['body'])['type']).toList();
      if (types.length < 3 ||
          types.first != 'registration_close' ||
          types.last != 'parts_validate' ||
          types.sublist(1, types.length - 1).any((t) => t != 'parts_save')) {
        blockers.add(
          'Faltan comandos durables en orden. Conservar checklist y completar legítimamente las etapas, sin inventar eventos históricos.',
        );
      }
      var expected = 1;
      for (final op in _sequence) {
        final body = object(op['body']);
        if (body['expectedVersion'] != expected++) {
          blockers.add(
            'expectedVersion incompatible; no se reescribe el payload.',
          );
        }
        final operationId = '${body['operationId']}';
        if (_approvedHashes.containsKey(operationId)) {
          blockers.add('operationId duplicado.');
        }
        _approvedHashes[operationId] = payloadHash(body);
      }
      if (_sequence.isNotEmpty &&
          _photoIds(object(_sequence.first['body'])).isEmpty) {
        blockers.add('No existe fotografía obligatoria en el cierre original.');
      }
      if (objects(record.working['parts']).isEmpty) {
        blockers.add('No hay checklist original comprobable.');
      }
      final saves = _sequence.where(
        (o) => object(o['body'])['type'] == 'parts_save',
      );
      if (derivativeMode) {
        final policy = object(catalog.json['partsReviewPolicy']);
        checklistPlan = LegacyChecklistPlan(
          server!,
          policy.isNotEmpty ? policy : object(server!['partsReviewPolicy']),
          saves.map((o) => object(o['body'])).toList(),
          allowVariableSaves: automaticMode,
        );
        blockers.addAll(checklistPlan!.blockers);
      }
      if (!derivativeMode && saves.isNotEmpty) {
        final savedParts = object(saves.last['body'])['parts'];
        if (payloadHash(savedParts) != payloadHash(record.working['parts']) ||
            partsPending({...record.working, 'parts': savedParts}).isNotEmpty) {
          blockers.add(
            'Checklist original incompleto o distinto del comando durable; revisión humana requerida.',
          );
        }
      }
      if (_sequence.isNotEmpty &&
          objects(
            object(_sequence.first['body'])['evidence'],
          ).any((e) => e['confirmed'] != true)) {
        blockers.add('Evidencia de registro sin confirmación original.');
      }
      final remotePhotos = await _remotePhotos();
      remoteInventoryRead = true;
      final proposedPhotoIds = derivativeMode
          ? record.photos.map((p) => '${p['id']}').toSet()
          : _sequence.isNotEmpty
          ? _photoIds(_sequence)
          : _photoIds([
              record.working['registrationEvidence'],
              record.working['parts'],
            ]);
      for (final id in proposedPhotoIds) {
        final photo = record.photos.where((p) => p['id'] == id).firstOrNull;
        if (photo == null) {
          blockers.add('Referencia fotográfica sin descriptor original.');
          continue;
        }
        final meta = object(photo['metadata']);
        if (derivativeMode &&
            (meta.keys.any(
                  (k) => !{
                    'photoId',
                    'context',
                    'clientSha256',
                    'capturedAt',
                    'latitude',
                    'longitude',
                    'accuracy',
                    'altitude',
                  }.contains(k),
                ) ||
                !{
                  'registration',
                  'parts_validation',
                  'installation',
                  'final_review',
                  'correction',
                }.contains(meta['context']) ||
                !'${meta['capturedAt']}'.endsWith('Z') ||
                (meta.containsKey('altitude') &&
                    (meta['altitude'] is! num ||
                        !(meta['altitude'] as num).isFinite ||
                        meta['altitude'] < -500 ||
                        meta['altitude'] > 10000)))) {
          blockers.add(
            'LEGACY_PHOTO_METADATA_INCOMPATIBLE: no se reescriben metadatos originales.',
          );
        }
        final accuracy = meta['accuracy'],
            lat = meta['latitude'],
            lng = meta['longitude'];
        if (photo['actor'] != _actor ||
            meta['photoId'] != id ||
            meta['context'] is! String ||
            DateTime.tryParse('${meta['capturedAt']}') == null ||
            accuracy is! num ||
            !accuracy.isFinite ||
            accuracy <= 0 ||
            accuracy > 100 ||
            lat is! num ||
            !lat.isFinite ||
            lat.abs() > 90 ||
            lng is! num ||
            !lng.isFinite ||
            lng.abs() > 180) {
          blockers.add(
            'Foto sin actor/contexto/fecha/GPS original compatible; no se inventan.',
          );
        }
        if (_photoIds(object(_sequence.firstOrNull?['body'])).contains(id) &&
            meta['context'] != 'registration') {
          blockers.add('Foto de cierre con contexto distinto.');
        }
        final row = remotePhotos
            .where(
              (p) => '${p['photo_id'] ?? p['photoId']}'.toLowerCase() == id,
            )
            .firstOrNull;
        // A previously received historical upload can be retained with its exact
        // original metadata/hash. Never upload those oversized bytes again.
        if (automaticMode && row != null && _matchingOriginal(row, photo)) {
          _existingHistoricalUploads.add(id);
        }
        if (row != null && _matchingOriginal(row, _transport(photo))) {
          remoteMatchedPhotos++;
        }
        if (row != null && !_matchingOriginal(row, _transport(photo))) {
          blockers.add(
            'Foto remota con hash de origen, actor o metadatos distintos: no sobrescribir.',
          );
        }
      }
      if (derivativeMode) {
        _requireCurrentReceipt(server!, _latestConfirmed);
        if (server!['version'] > 1 &&
            remoteMatchedPhotos != record.photos.length) {
          blockers.add('LEGACY_CONFIRMED_PHOTO_INVENTORY_MISSING');
        }
      }
      final originalEvidence = objects(record.working['registrationEvidence']);
      final registrationIds = _photoIds(originalEvidence);
      final evidenceIds = _photoIds([
        originalEvidence,
        record.working['parts'],
      ]);
      final currentDefinition = {
        ...record.working,
        'partDefinitions': catalog.parts(
          record.working['model'],
          record.working['automated'] == true,
        ),
        'partsReviewPolicy': catalog.json['partsReviewPolicy'],
      };
      currentDefinition['partDefinitions'] = cabinetReviewDefinitions(
        currentDefinition,
        object(catalog.json['partsReviewPolicy']),
      );
      _reviewPolicy =
          object(catalog.json['partsReviewPolicy'])['version'] as String?;
      _newStagesEligible =
          !automaticMode &&
          blockers.length == 1 &&
          _sequence.isEmpty &&
          record.operations.every(
            (o) => object(o['body'])['type'] == 'register',
          ) &&
          record.working['uid'] == legacyPilotUid &&
          originalEvidence.isNotEmpty &&
          registrationIds.isNotEmpty &&
          originalEvidence.every((e) => e['confirmed'] == true) &&
          objects(record.working['parts']).isNotEmpty &&
          partsPending(currentDefinition).isEmpty &&
          _reviewPolicy == 'ddr001-parts-20261019-v2' &&
          record.working['model'] == server!['model'] &&
          record.working['automated'] == server!['automated'] &&
          evidenceIds.every((id) {
            final photo = record.photos.where((p) => p['id'] == id).firstOrNull;
            final m = object(photo?['metadata']);
            final row = remotePhotos
                .where(
                  (p) => '${p['photo_id'] ?? p['photoId']}'.toLowerCase() == id,
                )
                .firstOrNull;
            return photo != null &&
                (row == null || _matchingOriginal(row, _transport(photo))) &&
                photo['actor'] == _actor &&
                m['photoId'] == id &&
                (registrationIds.contains(id)
                    ? m['context'] == 'registration'
                    : [
                        'registration',
                        'parts_validation',
                        'correction',
                      ].contains(m['context'])) &&
                DateTime.tryParse('${m['capturedAt']}') != null &&
                m['accuracy'] is num &&
                (m['accuracy'] as num).isFinite &&
                m['accuracy'] > 0 &&
                m['accuracy'] <= 100 &&
                m['latitude'] is num &&
                (m['latitude'] as num).isFinite &&
                (m['latitude'] as num).abs() <= 90 &&
                m['longitude'] is num &&
                (m['longitude'] as num).isFinite &&
                (m['longitude'] as num).abs() <= 180;
          });
      preparationPhase = 'preparación terminada';
      prepared = true;
      // A blocked diagnostic must not rewrite the historical dossier merely
      // to display its rejection. The certified backup remains available.
      if (blockers.isEmpty) {
        await _audit('prepared', {
          'backup': backupPath,
          'operationIds': operationAllowlist.toList(),
          'blockers': blockers,
        });
      }
    } finally {
      busy = false;
    }
  }

  /// New actions after explicit review; never reconstruct historical events.
  Future<void> prepareNewStages({
    required bool reviewedOriginalChecklistAndEvidence,
  }) async {
    if (!canPrepareNewStages || !reviewedOriginalChecklistAndEvidence) {
      throw StateError(
        'No hay evidencia suficiente o falta revisión explícita del residente.',
      );
    }
    busy = true;
    try {
      _check();
      await backup!.verify();
      _check();
      final current = object((await _get('/$cabinetId'))['cabinet']);
      _identity(current);
      if (current['status'] != 'draft' || current['version'] != 1) {
        throw StateError('El servidor cambió.');
      }
      final value = clone(controller.store.read(cabinetId)!.json);
      final originalWorking = object(value['working']);
      final now = DateTime.now().toUtc().toIso8601String();
      final types = ['registration_close', 'parts_save', 'parts_validate'];
      final additions = <Json>[];
      for (var i = 0; i < types.length; i++) {
        final body = <String, dynamic>{
          'operationId': const Uuid().v4(),
          'type': types[i],
          'expectedVersion': i + 1,
          'capturedAt': now,
          if (i == 0)
            'evidence': clone({
              'v': originalWorking['registrationEvidence'],
            })['v'],
          if (i == 1) 'parts': clone({'v': originalWorking['parts']})['v'],
          if (i == 1) 'partsReviewPolicyVersion': _reviewPolicy,
        };
        final op = <String, dynamic>{
          'actor': _actor,
          'state': 'queued',
          'body': body,
          'attempts': 0,
          'origin': 'explicit-resident-legacy-completion',
          'createdAt': now,
        };
        additions.add(op);
        _approvedHashes[body['operationId']] = payloadHash(body);
      }
      value['operations'] = [...objects(value['operations']), ...additions];
      // Original working/checklist/photos and historical operations are unchanged.
      await controller.store.save(value);
      _expectedRaw = controller.store.box.get('cabinet:$cabinetId');
      _sequence.addAll(additions.map(clone));
      _newStagesEligible = false;
      await _audit('new-actions-prepared', {
        'attribution': 'new actions, not historical events',
        'operationIds': operationAllowlist.toList(),
        'originalBackup': backupPath,
      });
      backup = await LegacyCabinetSnapshot.create(
        store: controller.store,
        id: cabinetId,
        support: await controller.camera.supportDirectory(),
        assertLease: _check,
      );
      blockers.clear();
      await _audit('new-actions-backed-up', {'backup': backupPath});
      onProgress?.call();
    } finally {
      busy = false;
    }
  }

  Future<void> _audit(
    String stage,
    Json detail, {
    Json? receipt,
    Json? body,
  }) async {
    _check();
    final value = clone(controller.store.read(cabinetId)!.json);
    final history = objects(value['legacyRecoveryEvents']);
    history.add({
      'at': DateTime.now().toUtc().toIso8601String(),
      'actor': _actor,
      'stage': stage,
      ...detail,
    });
    value['legacyRecoveryEvents'] = history;
    if (receipt != null && body != null) {
      _validateReceipt(receipt, body, requireStage: false);
      final ops = objects(value['operations']);
      final op = ops
          .where((o) => object(o['body'])['operationId'] == body['operationId'])
          .single;
      if (payloadHash(object(op['body'])) != payloadHash(body)) {
        throw StateError('Payload cambió.');
      }
      // Preserve historical errors/attempts/body/actor. Only append confirmation.
      op['state'] = 'done';
      op['result'] = receipt;
      value['operations'] = ops;
      final remote = object(receipt['cabinet']);
      if ((object(value['server'])['version'] as num? ?? 0) <=
          (remote['version'] as num)) {
        value['server'] = remote;
      }
    }
    if (stage == 'photo-verified') {
      final photos = objects(value['photos']);
      final photo = photos.singleWhere((p) => p['id'] == detail['photoId']);
      photo['verified'] = true;
      value['photos'] = photos;
    }
    if (stage == 'completed') {
      value['legacyRecoveryVerified'] = true;
      final record = CabinetRecord(value);
      // Automatic mode can resume only with no remaining historical commands/photos.
      value['legacyRecoveryCompleted'] =
          record.pending.isEmpty &&
          record.photos.every((p) => p['verified'] == true) &&
          value['deletion'] == null;
    }
    await controller.store.save(value);
    _expectedRaw = controller.store.box.get('cabinet:$cabinetId');
  }

  Future<void> _photos(Json body) async {
    for (final id in _photoIds(body)) {
      _check();
      await backup!.verify();
      await derivatives[id]?.verify();
      _check();
      final photo = controller.store
          .read(cabinetId)!
          .photos
          .singleWhere((p) => p['id'] == id);
      final row = (await _remotePhotos())
          .where((p) => '${p['photo_id'] ?? p['photoId']}'.toLowerCase() == id)
          .firstOrNull;
      if (row != null && !_matchingOriginal(row, _transport(photo))) {
        throw StateError(
          'Fotografía remota con identidad/metadata distinta; no se carga ni sobrescribe.',
        );
      }
      // An existing upload is verified before any upload; never blindly replay a photo.
      if (row == null &&
          derivativeMode &&
          (server?['version'] as int? ?? 1) > 1) {
        throw StateError('LEGACY_CONFIRMED_PHOTO_INVENTORY_MISSING');
      }
      if (row == null && _existingHistoricalUploads.contains(id)) {
        throw StateError('LEGACY_CONFIRMED_PHOTO_INVENTORY_MISSING');
      }
      if (row == null) {
        await _audit('photo-upload-intent', {
          'photoId': id,
          if (derivatives[id] != null)
            'transportManifest': derivatives[id]!.manifest,
        });
        _check();
        await _remote.upload(cabinetId, clone(_transport(photo)));
        _check();
      }
      final verified = await _remote.verify(cabinetId, [id]);
      _check();
      requireLegacyPhotoConfirmation(id, verified);
      final confirmed = (await _remotePhotos())
          .where((p) => '${p['photo_id'] ?? p['photoId']}'.toLowerCase() == id)
          .firstOrNull;
      if (confirmed == null ||
          !_matchingOriginal(confirmed, _transport(photo))) {
        throw StateError('No se confirmó hash remoto de la fotografía.');
      }
      _verifiedPhotoIds.add(id);
      remoteVerifiedPhotos = _verifiedPhotoIds.length;
      await _audit('photo-verified', {'photoId': id});
    }
  }

  Future<void> execute({
    required Set<String> operationAllowlist,
    required bool explicitlyConfirmed,
  }) async {
    if (!canExecute ||
        !explicitlyConfirmed ||
        operationAllowlist.length != this.operationAllowlist.length ||
        !operationAllowlist.containsAll(this.operationAllowlist)) {
      throw StateError('Falta autorización explícita de la secuencia exacta.');
    }
    busy = true;
    try {
      _check();
      await backup!.verify();
      _check();
      controller.app.api.authorizeCabinetRecovery(
        _lease!,
        operations: operationAllowlist,
        photos: derivativeMode
            ? controller.store
                  .read(cabinetId)!
                  .photos
                  .map((p) => '${p["id"]}')
                  .toSet()
            : _photoIds(_sequence),
      );
      if (derivativeMode) {
        // Re-read progress and all receipts before the first upload. Preparation
        // is not authority to transmit against a subsequently changed server.
        final current = object((await _get('/$cabinetId'))['cabinet']);
        _identity(current);
        var confirmedVersion = 1;
        Json? latestReceipt;
        var gap = false;
        for (final selected in _sequence) {
          final body = object(selected['body']);
          final receipt = await _receipt(body);
          if (receipt == null) {
            gap = true;
          } else {
            if (gap) throw StateError('LEGACY_RECEIPT_GAP');
            _validateReceipt(receipt, body);
            confirmedVersion++;
            latestReceipt = object(receipt['cabinet']);
          }
        }
        final expectedStatus = confirmedVersion == 1
            ? 'draft'
            : confirmedVersion == 2
            ? 'registered'
            : confirmedVersion == _sequence.length + 1
            ? 'validated'
            : 'incomplete';
        if (current['version'] != confirmedVersion ||
            current['status'] != expectedStatus) {
          throw StateError('LEGACY_REMOTE_PROGRESS_MISMATCH');
        }
        _requireCurrentReceipt(current, latestReceipt);
        for (final derivative in derivatives.values) {
          await derivative.verify();
        }
        await _photos({
          'evidence': controller.store
              .read(cabinetId)!
              .photos
              .map((p) => {'photoId': p['id']})
              .toList(),
        });
      }
      for (final entry in _registerReceipts.entries) {
        final body = object(
          controller.store
              .read(cabinetId)!
              .operations
              .singleWhere(
                (o) => object(o['body'])['operationId'] == entry.key,
              )['body'],
        );
        await _audit(
          'register-receipt-restored',
          {'operationId': entry.key},
          receipt: entry.value,
          body: body,
        );
      }
      for (final selected in _sequence) {
        _check();
        final body = object(selected['body']),
            operationId = '${body['operationId']}';
        if (!operationAllowlist.contains(operationId) ||
            payloadHash(body) != _approvedHashes[operationId]) {
          throw StateError('Secuencia modificada.');
        }
        var receipt = await _receipt(body);
        if (receipt == null) {
          final remote = object((await _get('/$cabinetId'))['cabinet']);
          _identity(remote);
          final expectedStatus = body['type'] == 'registration_close'
              ? ['draft']
              : ['registered', 'incomplete'];
          if (remote['version'] != body['expectedVersion'] ||
              !expectedStatus.contains(remote['status'])) {
            throw StateError('Versión/etapa cambió; detener sin reescribir.');
          }
          if (derivativeMode && body['type'] == 'parts_validate') {
            _requireFinalChecklist(remote);
          }
          await _photos(body);
          await _audit('command-intent', {
            'operationId': operationId,
            'payloadSha256': _approvedHashes[operationId],
          });
          _check();
          receipt = await _remote.command(cabinetId, clone(body));
          _check();
        }
        _validateReceipt(receipt, body, requireStage: false);
        // A response alone is insufficient: recover the durable receipt before proceeding.
        final confirmed = await _receipt(body);
        if (confirmed == null ||
            !sameLegacyDurableReceipt(confirmed, receipt)) {
          throw StateError('Respuesta sin recibo durable compatible.');
        }
        await _audit(
          'command-confirmed',
          {'operationId': operationId},
          receipt: confirmed,
          body: body,
        );
        _validateReceipt(confirmed, body);
        if (derivativeMode && body['expectedVersion'] == _sequence.length - 1) {
          _requireFinalChecklist(object(confirmed['cabinet']));
        }
        results.add('${body['type']}: confirmado');
        onProgress?.call();
      }
      server = object((await _get('/$cabinetId'))['cabinet']);
      _identity(server!);
      if (server!['status'] != 'validated' ||
          server!['partsValidated'] != true ||
          server!['version'] != _sequence.length + 1) {
        throw StateError('Resultado remoto final no coincide.');
      }
      if (derivativeMode) _requireFinalChecklist(server!);
      await _audit('completed', {'remoteVersion': server!['version']});
      completed = true;
    } catch (e) {
      results.add('Detenida: ${CabinetController.explain(e)}');
      try {
        await _audit('stopped', {
          'errorType': e.runtimeType.toString(),
          if (e is DioException) 'httpStatus': e.response?.statusCode,
        });
      } catch (_) {
        /* Keep held; no writes under changed identity. */
      }
      rethrow;
    } finally {
      busy = false;
    }
  }

  Future<void> close() async {
    if (busy) throw StateError('Operación en curso.');
    if (_lease != null) {
      await controller.endLegacySupport(_lease!);
      _lease = null;
    }
  }
}
