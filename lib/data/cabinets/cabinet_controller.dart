import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import '../../core/media/photo_capture_service.dart';
import '../../core/location/location_service.dart';
import '../../core/persistence/construction_operation_journal.dart';
import '../../core/security/session_store.dart';
import '../../core/services/app_controller.dart';
import '../../domain/construction/construction_models.dart';
import '../../domain/cabinets/cabinet_models.dart';
import '../../domain/cabinets/cabinet_safety.dart';
import 'cabinet_api.dart';
import 'cabinet_store.dart';

String _stableCommand(Object? value) {
  Object? canonical(Object? item) {
    if (item is Map) {
      final keys = item.keys.map((k) => '$k').toList()..sort();
      return {for (final key in keys) key: canonical(item[key])};
    }
    if (item is List) return item.map(canonical).toList();
    return item;
  }

  return jsonEncode(canonical(value));
}

class CabinetController extends ChangeNotifier with WidgetsBindingObserver {
  CabinetController({
    required this.app,
    required this.store,
    required this.remote,
    PhotoCaptureService? camera,
  }) : camera =
           camera ??
           PhotoCaptureService(
             local: store.media,
             directoryName: 'cabinets',
             preserveOriginalUpload: true,
           ) {
    app.addListener(_appChanged);
    WidgetsBinding.instance.addObserver(this);
  }
  final AppController app;
  final CabinetStore store;
  final CabinetRemote remote;
  final PhotoCaptureService camera;
  Timer? _retry;
  StreamSubscription<LocationFix>? _cabinetFixes;
  bool _applyingGps = false;
  bool syncing = false, refreshing = false, capturing = false;
  String? message;
  final Set<String> _submitting = {};
  bool submitting(String id) =>
      _submitting.any((key) => key.startsWith('$id:'));
  Future<void> flushDrafts() => _writes;
  String? _identity;
  bool _disposed = false;
  Future<void> _writes = Future.value();
  String? get actor => app.session?.userId.toLowerCase();
  bool get eligible =>
      app.session?.kind == SessionKind.field &&
      app.profile?.role == ConstructionRole.resident &&
      app.profile?.userId.toLowerCase() == actor;
  bool get allowed => eligible && store.authorized(actor!);
  List<CabinetRecord> get records => allowed
      ? store
            .all()
            .where(
              (r) =>
                  r.json['archived'] != true &&
                  (r.server.isNotEmpty || r.json['actor'] == actor),
            )
            .toList()
      : [];
  CabinetRecord record(String id) {
    if (!allowed) {
      throw StateError(
        'Acceso exclusivo para residentes Construction habilitados.',
      );
    }
    final r = store.read(id);
    if (r == null || (r.server.isEmpty && r.json['actor'] != actor)) {
      throw StateError('Expediente no disponible para esta sesión.');
    }
    return r;
  }

  void _requireWritable(String id) {
    final r = record(id);
    if (r.json['deletion'] != null) {
      throw StateError(
        'Eliminación en curso. Reintenta la sincronización para terminar.',
      );
    }
    if (r.json['archived'] == true) {
      throw StateError(
        'Este conflicto está archivado. Sus capturas se conservan para consulta; continúa en el expediente vigente.',
      );
    }
    if (r.pending.any((o) => o['actor'] != actor) ||
        (r.json['dirty'] == true &&
            r.json['draftActor'] != null &&
            r.json['draftActor'] != actor)) {
      throw StateError(
        'Hay capturas pendientes de otro residente. Deben confirmarse con su sesión antes de continuar.',
      );
    }
  }

  CabinetCatalog catalogFor(CabinetRecord r) =>
      store.catalog(r.working['catalogVersion'] as String?) ??
      (throw StateError(
        'Conecta para descargar la versión de catálogo del expediente.',
      ));
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _writes.then((_) => action());
    _writes = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _edit(String id, void Function(Json) edit) => _serial(() async {
    final r = store.read(id) ?? (throw StateError('Expediente ausente'));
    final value = clone(r.json);
    edit(value);
    await store.save(value);
    _notify();
  });
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _appChanged() {
    final identity = '$actor:$eligible:${app.online}';
    _notify();
    if (identity != _identity) {
      _identity = identity;
      if (eligible && app.online) unawaited(refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && eligible) {
      unawaited(recoverPhotos());
      unawaited(refresh());
    }
  }

  Future<void> start() async {
    _cabinetFixes ??= app.locations.fixes.listen(
      (_) => unawaited(recoverPhotoGps()),
    );
    await recoverPhotos();
    await recoverPhotoGps();
    _appChanged();
  }

  Future<void> recoverPhotos() async {
    for (final photo in await camera.recoverPendingCaptures()) {
      final intent = object(store.read(photo.surveyId)?.json['captureIntent']);
      if (intent.isEmpty) continue;
      await _adoptPhoto(photo, intent);
    }
  }

  Future<void> refresh() async {
    if (!eligible || refreshing) return;
    final user = actor!;
    refreshing = true;
    var catalogAvailable = false;
    _notify();
    try {
      Json catalogJson;
      try {
        catalogJson = await remote.get('/catalog');
      } on DioException catch (e) {
        if ([404, 503].contains(e.response?.statusCode)) {
          throw StateError(
            'El servicio de gabinetes no está disponible en el servidor. '
            'Reintenta cuando esté habilitado. Tus datos locales se conservan.',
          );
        }
        rethrow;
      }
      final catalog = CabinetCatalog(catalogJson);
      catalogAvailable = true;
      if (!eligible || actor != user) return;
      await store.saveCatalog(catalog);
      await store.authorize(user, true);
      _notify();
      var page = 1;
      while (true) {
        final data = await remote.get('', {'page': page, 'limit': 100});
        if (!allowed || actor != user) return;
        final rows = objects(data['items']);
        for (final row in rows) {
          if (!allowed || actor != user) return;
          await pull('${row['cabinet_id']}'.toLowerCase());
        }
        if (page * 100 >= (data['total'] as num? ?? 0) || rows.isEmpty) break;
        page++;
      }
      message = null;
    } catch (e) {
      await _handleAccess(e, user);
      message = explain(e);
    } finally {
      refreshing = false;
      _notify();
    }
    if (catalogAvailable && allowed && actor == user) {
      unawaited(synchronize());
    }
  }

  Future<void> pull(String id) async {
    if (!allowed) return;
    final user = actor;
    final response = await remote.get('/$id');
    final cabinet = object(response['cabinet']);
    if (!allowed || actor != user) return;
    final version = cabinet['catalogVersion'] as String;
    if (store.catalog(version) == null ||
        object(store.catalog(version)!.json['partsReviewPolicy'])['version'] !=
            'ddr001-parts-20261019-v2') {
      await store.saveCatalog(
        CabinetCatalog(await remote.get('/catalog', {'version': version})),
        current: false,
      );
    }
    await _serial(() async {
      final old = store.read(id);
      final value = old == null
          ? {
              'id': id,
              'actor': user,
              'operations': <Json>[],
              'photos': <Json>[],
            }
          : clone(old.json);
      value['server'] = cabinet;
      if (old == null || (old.pending.isEmpty && old.json['dirty'] != true)) {
        value['working'] = cabinet;
      }
      await store.save(value);
    });
    _notify();
  }

  /// Resolves an existing dossier without creating a draft. Only 404 means absent.
  Future<String?> findForInstallation(String raw) => _serial(() async {
    if (!allowed) {
      throw StateError('Acceso exclusivo para residentes autorizados.');
    }
    final user = actor!, uid = cabinetUid(raw.trim());
    final local = records.where((r) => r.working['uid'] == uid).firstOrNull;
    if (local != null) return local.id;
    if (!app.online) {
      throw StateError(
        'El gabinete no está descargado en este teléfono. Conéctate para consultar la API.',
      );
    }
    try {
      final data = await remote.get('/resolve', {'uid': uid});
      if (!allowed || actor != user) throw StateError('La sesión cambió.');
      final cabinet = object(data['cabinet']);
      final id = cabinet['cabinetId']?.toString().toLowerCase();
      if (id == null || cabinet['uid'] != uid) {
        throw StateError(
          'La API devolvió un expediente inválido. Reintenta la consulta.',
        );
      }
      await store.save({
        'id': id,
        'actor': user,
        'working': cabinet,
        'server': cabinet,
        'operations': <Json>[],
        'photos': <Json>[],
      });
      _notify();
      return id;
    } on DioException catch (e) {
      if (!allowed || actor != user) throw StateError('La sesión cambió.');
      if (e.response?.statusCode == 404) return null;
      await _handleAccess(e, user);
      rethrow;
    }
  });

  Future<String> scan(
    String raw,
    String model,
    bool automated,
  ) => _serial(() async {
    if (!allowed) {
      throw StateError(
        'Conecta primero para verificar tu permiso y descargar el catálogo.',
      );
    }
    final user = actor!, uid = cabinetUid(raw);
    final existing = records.where((r) => r.working['uid'] == uid).firstOrNull;
    if (existing != null) return existing.id;
    if (app.online) {
      try {
        final data = await remote.get('/resolve', {'uid': uid});
        if (!allowed || actor != user) throw StateError('La sesión cambió.');
        final c = object(data['cabinet']),
            id = c['cabinetId'].toString().toLowerCase();
        await store.save({
          'id': id,
          'actor': user,
          'working': c,
          'server': c,
          'operations': <Json>[],
          'photos': <Json>[],
        });
        _notify();
        return id;
      } on DioException catch (e) {
        if (e.response?.statusCode != 404 && e.response != null) {
          await _handleAccess(e, user);
          rethrow;
        }
      }
    }
    final catalog =
        store.catalog() ?? (throw StateError('Falta descargar el catálogo.'));
    final id = const Uuid().v4();
    final working = <String, dynamic>{
      'cabinetId': id,
      'uid': uid,
      'model': model,
      'automated': automated,
      'catalogVersion': catalog.version,
      'closurePolicyVersion': catalog.policyVersion,
      'partDefinitions': catalog.parts(model, automated),
      if (app.currentCrewId != null)
        'registrationCompany': {
          'id': app.currentCrewId,
          'name': app.currentCrew,
          'source': 'local_capture',
        },
      'status': 'draft',
      'parts': <Json>[],
      'registrationEvidence': <Json>[],
      'installation': null,
    };
    final body = {
      'operationId': const Uuid().v4(),
      'expectedVersion': 0,
      'capturedAt': DateTime.now().toUtc().toIso8601String(),
      'type': 'register',
      if (object(catalog.json['capabilities'])['registrationCompany'] == true &&
          app.currentCrewId != null)
        'expectedCrewId': app.currentCrewId,
      'uid': uid,
      'model': model,
      'automated': automated,
      'catalogVersion': catalog.version,
    };
    await store.save({
      'id': id,
      'actor': user,
      'working': working,
      'server': <String, dynamic>{},
      'operations': [
        {'body': body, 'actor': user, 'state': 'queued', 'attempts': 0},
      ],
      'photos': <Json>[],
      'dirty': false,
    });
    _notify();
    unawaited(synchronize());
    return id;
  });
  Future<void> saveDraft(String id, String field, Object? value) async {
    final user = actor;
    _requireWritable(id);
    await _edit(id, (r) {
      if (!allowed || actor != user) throw StateError('La sesión cambió.');
      if (r['dirty'] == true &&
          r['draftActor'] != null &&
          r['draftActor'] != user) {
        throw StateError('Hay captura sin enviar de otro residente.');
      }
      final w = object(r['working']);
      w[field] = value;
      if (field == 'parts') w['partsValidated'] = false;
      if (['parts', 'installation'].contains(field)) {
        final review = object(r['finalReviewDraft']);
        review['fieldChecked'] = false;
        review['dossierConsulted'] = false;
        r['finalReviewDraft'] = review;
        w['installationValid'] = false;
        if (w['status'] == 'deliverable') w['status'] = 'installed';
        w['approval'] = null;
      }
      r['working'] = w;
      r['dirty'] = true;
      r['draftSavedAt'] = DateTime.now().toUtc().toIso8601String();
      r['draftActor'] = user;
    });
  }

  Future<void> patchInstallation(
    String id,
    String field,
    Object? value, {
    String? answerCode,
  }) async {
    final user = actor;
    _requireWritable(id);
    await _edit(id, (r) {
      if (!allowed || actor != user) throw StateError('La sesión cambió.');
      final w = object(r['working']);
      final installation = installationWithDefaults(
        object(w['installation']),
        objects(w['parts']),
      );
      if (answerCode != null) {
        final answers = objects(installation['answers']);
        answers.removeWhere((a) => a['code'] == answerCode);
        answers.add(object(value));
        installation['answers'] = answers;
      } else {
        installation[field] = value;
      }
      w['installation'] = installation;
      w['installationValid'] = false;
      w['approval'] = null;
      if (w['status'] == 'deliverable') w['status'] = 'installed';
      r['working'] = w;
      r['dirty'] = true;
      r['draftActor'] = user;
      r['draftSavedAt'] = DateTime.now().toUtc().toIso8601String();
      r['finalReviewDraft'] = {
        ...object(r['finalReviewDraft']),
        'fieldChecked': false,
        'dossierConsulted': false,
      };
    });
  }

  /// Apply the downloaded review policy only through an explicit save operation.
  Future<void> savePartsSide(String id, String side) async {
    _requireWritable(id);
    await flushDrafts();
    final current = record(id);
    if (current.working['status'] == 'draft') {
      throw StateError(
        'Completa primero el paso Registro con su fotografía. Las piezas capturadas se conservan.',
      );
    }
    final policy = object(catalogFor(current).json['partsReviewPolicy']);
    if (policy['version'] != 'ddr001-parts-20261019-v2') {
      throw StateError(
        'Conecta con la API actualizada para descargar la revisión de piezas por lado. Datos conservados.',
      );
    }
    final parts = objects(current.working['parts']);
    for (final definition in cabinetReviewDefinitions(
      current.working,
      policy,
    )) {
      final code = definition['code'];
      if (cabinetPartStep(definition, policy) != side) continue;
      final index = parts.indexWhere((p) => p['code'] == code);
      if (index < 0) {
        parts.add({'code': code, 'present': true, 'evidence': <Json>[]});
      } else if (parts[index]['present'] == null) {
        parts[index]['present'] = true;
      }
    }
    await enqueue(id, 'parts_save', {
      'parts': parts,
      'partsReviewPolicyVersion': policy['version'],
      if (current.working['correctionReason'] != null)
        'reason': current.working['correctionReason'],
    });
    if (side == 'automation' ||
        (side == 'producer' && current.working['automated'] != true)) {
      await enqueue(id, 'parts_validate', {});
    }
  }

  Future<void> patchPart(String id, String code, Json patch) async {
    final user = actor;
    _requireWritable(id);
    await _edit(id, (r) {
      if (!allowed || actor != user) throw StateError('La sesión cambió.');
      final w = object(r['working']);
      final parts = objects(w['parts']);
      final old =
          parts.where((p) => p['code'] == code).firstOrNull ??
          {'code': code, 'present': null, 'evidence': <Json>[]};
      parts.removeWhere((p) => p['code'] == code);
      parts.add({...old, ...clone(patch), 'code': code});
      w['parts'] = parts;
      w['partsValidated'] = false;
      w['installationValid'] = false;
      w['approval'] = null;
      if (w['status'] == 'deliverable') w['status'] = 'installed';
      r['working'] = w;
      r['dirty'] = true;
      r['draftActor'] = user;
      r['draftSavedAt'] = DateTime.now().toUtc().toIso8601String();
      r['finalReviewDraft'] = {
        ...object(r['finalReviewDraft']),
        'fieldChecked': false,
        'dossierConsulted': false,
      };
    });
  }

  Future<void> reconnectSession() async {
    final previous = app.session;
    if (previous == null || previous.kind != SessionKind.field) {
      throw StateError('Inicia sesión como residente Construction.');
    }
    try {
      final next = await app.remote.fieldLogin(
        name: previous.name,
        email: previous.email,
        phone: previous.phone,
        crew: previous.crew,
      );
      if (app.session != previous ||
          next.userId.toLowerCase() != previous.userId.toLowerCase()) {
        throw StateError(
          'La identidad del entorno no coincide. Los pendientes siguen asociados al usuario original.',
        );
      }
      final profile = await app.remote.profile();
      await app.local.saveProfile(profile);
      app.session = next;
      app.profile = profile;
      app.online = true;
      message = eligible
          ? null
          : 'Sesión conectada. La API no autoriza a este usuario como residente Construction.';
      if (!eligible) await store.authorize(next.userId.toLowerCase(), false);
      await refresh();
    } catch (_) {
      if (app.session == previous) await app.sessions.save(previous);
      rethrow;
    } finally {
      _notify();
    }
  }

  Future<void> deleteRegistration(String id, String uid) async {
    _requireWritable(id);
    if (syncing || capturing) {
      throw StateError(
        'Espera a que termine la sincronización o captura actual.',
      );
    }
    final user = actor;
    final catalog = CabinetCatalog(await remote.get('/catalog'));
    if (!allowed || actor != user) throw StateError('La sesión cambió.');
    if (object(catalog.json['capabilities'])['permanentDeletion'] != true) {
      throw StateError(
        'Esta API aún no habilita eliminación definitiva. Datos conservados.',
      );
    }
    await _edit(id, (value) {
      final r = CabinetRecord(value);
      if (syncing ||
          capturing ||
          !allowed ||
          actor != user ||
          value['deletion'] != null) {
        throw StateError('Hay otra operación en curso. Reintenta.');
      }
      if (r.working['installation'] != null ||
          r.server['installation'] != null ||
          ['installed', 'deliverable'].contains(r.working['status']) ||
          ['installed', 'deliverable'].contains(r.server['status'])) {
        throw StateError(
          'No se puede borrar un gabinete vinculado a instalación.',
        );
      }
      if (cabinetUid(uid) != r.working['uid']) {
        throw StateError('El número no coincide.');
      }
      value['deletion'] = {
        'actor': user,
        'body': {
          'operationId': const Uuid().v4(),
          'expectedVersion': r.server['version'] ?? 0,
          'uid': cabinetUid(uid),
          'confirmPermanent': true,
        },
      };
    });
    await synchronize(force: true);
    if (store.read(id) != null) {
      throw StateError(
        '${object(store.read(id)!.json['deletion'])['error'] ?? message ?? 'Eliminación pendiente. Reintenta desde Sincronización.'}',
      );
    }
  }

  Future<void> cancelRejectedDeletion(String id) async {
    if (!allowed) throw StateError('Acceso de residente requerido.');
    await _edit(id, (value) {
      final deletion = object(value['deletion']);
      if (deletion['actor'] != actor ||
          deletion['code'] != 'VERSION_CONFLICT') {
        throw StateError(
          'La eliminación no puede cancelarse sin confirmación del servidor.',
        );
      }
      value.remove('deletion');
    });
    await refresh();
  }

  Future<void> _finishDeletion(String id, String user) async {
    final record = store.read(id)!;
    final deletion = object(record.json['deletion']);
    if (deletion['actor'] != user || !allowed || actor != user) return;
    final body = object(deletion['body']);
    final result = await remote.deleteCabinet(id, body);
    if (result['deleted'] != true ||
        result['cabinetId'] != id ||
        result['operationId'] != body['operationId']) {
      throw StateError(
        'No se confirmó la eliminación. Reintenta sin cambiar la solicitud.',
      );
    }
    if (!allowed || actor != user) return;
    await _serial(() async {
      // Only the confirmed dossier directory and its own Hive rows are removed.
      final root = await camera.supportDirectory();
      if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(id)) {
        throw StateError('UUID inválido.');
      }
      final folder = Directory('${root.path}/cabinets/$id');
      if (await folder.exists()) {
        final physical = await folder.resolveSymbolicLinks();
        final expectedRoot = await root.resolveSymbolicLinks();
        if (physical != '$expectedRoot/cabinets/$id') {
          throw StateError('Ruta de fotografías no segura.');
        }
        await folder.delete(recursive: true);
      }
      for (final box in [
        store.media.surveysBox,
        store.media.photosBox,
        store.media.queueBox,
        store.media.journalBox,
        store.media.metadataBox,
      ]) {
        for (final key in box.keys.toList()) {
          Json entry;
          try {
            entry = object(jsonDecode(box.get(key)!));
          } catch (_) {
            continue;
          }
          if (entry['surveyId'] == id || entry['cabinetId'] == id) {
            await box.delete(key);
          }
        }
        await box.flush();
      }
      await store.box.delete('cabinet:$id');
      await store.box.flush();
    });
    _notify();
  }

  Future<void> enqueue(String id, String type, Json extra) async {
    final submission = '$id:$type:${_stableCommand(extra)}';
    if (!_submitting.add(submission)) return;
    _notify();
    try {
      final user = actor;
      _requireWritable(id);
      await _edit(id, (r) {
        if (!allowed || actor != user) throw StateError('La sesión cambió.');
        final current = CabinetRecord(r);
        final normalized = checkedCabinetPayload(type, extra);
        extra = normalized;
        if (normalized['reason'] != null) {
          normalized['reason'] = '${normalized['reason']}'.trim();
        }
        if (['identity_correct', 'final_review'].contains(type) ||
            (['parts_save', 'installation_save'].contains(type) &&
                (current.server['status'] == 'deliverable' ||
                    current.server['status'] == 'installed' ||
                    current.working['status'] == 'installed' ||
                    current.working['status'] == 'deliverable'))) {
          final error = reasonError(normalized['reason']);
          if (error != null) throw StateError(error);
        }
        if (type == 'registration_close' &&
            current.working['status'] != 'draft') {
          return;
        }
        if (type == 'installation_close' &&
            current.working['installationValid'] == true) {
          return;
        }
        final matching = current.pending
            .where((op) => object(op['body'])['type'] == type)
            .toList();
        final duplicate =
            matching.isNotEmpty &&
            object(matching.last['body'])['operationId'] ==
                object(current.pending.last['body'])['operationId'] &&
            (() {
              final op = matching.last;
              final old = clone(object(op['body']))
                ..remove('operationId')
                ..remove('expectedVersion')
                ..remove('capturedAt');
              return _stableCommand(old) ==
                  _stableCommand({'type': type, ...normalized});
            })();
        if (duplicate) return;
        if (current.pending.any((o) => o['actor'] != user)) {
          throw StateError(
            'Hay operaciones de otro residente pendientes. Debe enviarlas con su sesión antes de continuar.',
          );
        }
        final version =
            (current.server['version'] as num? ?? 0).toInt() +
            current.pending.length;
        final body = <String, dynamic>{
          'operationId': const Uuid().v4(),
          'expectedVersion': version,
          'capturedAt': DateTime.now().toUtc().toIso8601String(),
          'type': type,
          ...normalized,
        };
        final w = current.working;
        switch (type) {
          case 'registration_close':
            if (objects(extra['evidence']).isEmpty) {
              throw StateError(
                'Falta fotografía de identificación confirmada.',
              );
            }
            w['registrationEvidence'] = extra['evidence'];
            w['status'] = 'registered';
          case 'parts_save':
            if (extra['partsReviewPolicyVersion'] != null) {
              w['partsReviewPolicyVersion'] = extra['partsReviewPolicyVersion'];
              w['partsReviewPolicy'] = clone(
                object(catalogFor(current).json['partsReviewPolicy']),
              );
              w['partDefinitions'] = cabinetReviewDefinitions(
                w,
                object(w['partsReviewPolicy']),
              );
            }
            w['parts'] = extra['parts'];
            w['partsValidated'] = false;
            if (!['installed', 'deliverable'].contains(w['status'])) {
              w['status'] = 'incomplete';
            }
          case 'parts_validate':
            final pending = partsPending(w);
            w['partsValidated'] = pending.isEmpty;
            w['pending'] = pending;
            if (!['installed', 'deliverable'].contains(w['status'])) {
              w['status'] = pending.isEmpty ? 'validated' : 'incomplete';
            }
          case 'identity_correct':
            final catalog = catalogFor(current);
            final retained = compatibleParts(
              w,
              catalog.parts(extra['model'], extra['automated']),
            );
            w['model'] = extra['model'];
            w['automated'] = extra['automated'];
            w['catalogVersion'] = catalog.version;
            w['closurePolicyVersion'] = catalog.policyVersion;
            w['partDefinitions'] = catalog.parts(
              extra['model'],
              extra['automated'],
            );
            if (w['partsReviewPolicyVersion'] != null) {
              w['partsReviewPolicy'] = clone(
                object(catalog.json['partsReviewPolicy']),
              );
            }
            w['parts'] = retained;
            w['partsValidated'] = false;
            w['installationValid'] = false;
            w['approval'] = null;
            w['pending'] = partsPending(w);
            if (!['installed', 'deliverable'].contains(w['status'])) {
              w['status'] = 'incomplete';
            }
            if (w['installation'] != null) {
              final i = object(w['installation']);
              i['answers'] = <Json>[];
              i['evidence'] = <String, dynamic>{};
              w['installation'] = i;
            }
          case 'installation_save':
            if (w['partsValidated'] != true) {
              throw StateError('Valida las piezas antes de instalar.');
            }
            w['installation'] = extra['installation'];
          case 'installation_close':
            if (w['partsValidated'] != true ||
                partsPending(w).isNotEmpty ||
                object(w['installation'])['gps'] == null ||
                object(w['installation'])['baseId'] == null) {
              throw StateError(
                'Faltan piezas validadas, base o GPS propio de instalación.',
              );
            }
            final pending = installationPending(w, catalogFor(current));
            if (pending.any((p) => p['classification'] == 'blocking')) {
              throw StateError(
                'Resuelve los bloqueos antes de completar instalación.',
              );
            }
            w['status'] = 'installed';
            w['installationOperationId'] = body['operationId'];
            w['pending'] = pending;
            w['installationValid'] = true;
          case 'final_review':
            if (w['installationValid'] != true) {
              throw StateError(
                'Cierra nuevamente la instalación corregida antes del dictamen.',
              );
            }
            if (!['installed', 'deliverable'].contains(w['status'])) {
              throw StateError('Primero completa la instalación.');
            }
            if (extra['verdict'] == 'approve' &&
                (partsPending(w).isNotEmpty ||
                    installationPending(w, catalogFor(current)).isNotEmpty)) {
              throw StateError('Quedan incumplimientos o pruebas pendientes.');
            }
          // Approval only comes from the server. Keep installed while pending.
        }
        if ([
          'parts_save',
          'installation_save',
          'identity_correct',
        ].contains(type)) {
          if (['installed', 'deliverable'].contains(w['status'])) {
            if ((extra['reason'] ?? '').toString().trim().length < 3) {
              throw StateError('Explica la corrección de datos instalados.');
            }
            w['status'] = 'installed';
            w['approval'] = null;
            w['installationValid'] = false;
          }
        }
        r['working'] = w;
        r['dirty'] = false;
        if (type == 'final_review') r['finalReviewDraft'] = <String, dynamic>{};
        r['operations'] = [
          ...current.operations,
          {'body': body, 'actor': user, 'state': 'queued', 'attempts': 0},
        ];
      });
      unawaited(synchronize());
    } finally {
      _submitting.remove(submission);
      _notify();
    }
  }

  Future<void> capture(String id, String context) async {
    if (capturing) return;
    final user = actor;
    _requireWritable(id);
    capturing = true;
    _notify();
    final intent = <String, dynamic>{'actor': user, 'context': context};
    try {
      await app.locations.startPrewarm();
      _cabinetFixes ??= app.locations.fixes.listen(
        (_) => unawaited(recoverPhotoGps()),
      );
      await _edit(id, (r) => r['captureIntent'] = intent);
      final photo = await camera.capture(surveyId: id);
      if (photo == null) return;
      // Persist before GPS/network; a failed GPS never discards the photo.
      await _adoptPhoto(photo, intent);
      try {
        final gps =
            app.locations.bestFix(photo.capturedAt)?.toGeoPoint() ??
            await app.locations.capture();
        if (gps.accuracy <= 0 ||
            gps.accuracy > 100 ||
            gps.capturedAt.difference(photo.capturedAt).inSeconds.abs() > 120) {
          throw StateError('GPS fuera de precisión o ventana de captura.');
        }
        await _edit(id, (r) {
          final photos = objects(r['photos']);
          final p = photos.firstWhere((p) => p['id'] == photo.id);
          p['metadata'] = {...object(p['metadata']), ...gpsWire(gps)};
          p['gpsCapturedAt'] = gps.capturedAt.toIso8601String();
          r['photos'] = photos;
        });
      } catch (e) {
        message =
            'No se obtuvo ubicación válida para esta foto. Se conserva y se reintentará automáticamente dentro de la ventana de captura.';
      }
    } finally {
      await recoverPhotoGps();
      capturing = false;
      _notify();
    }
    if (actor == user) unawaited(synchronize());
  }

  Future<void> recoverPhotoGps() async {
    if (!allowed || _applyingGps) return;
    _applyingGps = true;
    final user = actor;
    try {
      for (final record in records) {
        if (record.json['deletion'] != null) continue;
        for (final photo in record.photos.where(
          (p) =>
              p['actor'] == actor &&
              p['deleting'] != true &&
              object(p['metadata'])['accuracy'] == null,
        )) {
          final captured = DateTime.tryParse(
            '${object(photo['metadata'])['capturedAt']}',
          );
          if (captured == null) continue;
          final fix = app.locations.bestFix(captured);
          if (fix == null) continue;
          if (!allowed || actor != user || store.read(record.id) == null) {
            return;
          }
          await _edit(record.id, (r) {
            if (!allowed || actor != user || r['deletion'] != null) return;
            final photos = objects(r['photos']);
            final p = photos.where((p) => p['id'] == photo['id']).firstOrNull;
            if (p == null ||
                p['deleting'] == true ||
                object(p['metadata'])['accuracy'] != null) {
              return;
            }
            p['metadata'] = {
              ...object(p['metadata']),
              ...gpsWire(fix.toGeoPoint()),
            };
            p['gpsCapturedAt'] = fix.timestamp.toIso8601String();
            r['photos'] = photos;
            final w = object(r['working']);
            if (w['status'] == 'draft' &&
                object(p['metadata'])['context'] == 'registration') {
              final evidence = objects(w['registrationEvidence']);
              if (!evidence.any((e) => e['photoId'] == p['id'])) {
                evidence.add({'photoId': p['id'], 'confirmed': true});
              }
              w['registrationEvidence'] = evidence;
              r['working'] = w;
              r['dirty'] = true;
              r['draftActor'] = actor;
            }
          });
        }
      }
    } finally {
      _applyingGps = false;
    }
  }

  Future<void> deleteRegistrationPhoto(String id, String photoId) async {
    _requireWritable(id);
    if (syncing || capturing) {
      throw StateError('Espera a que termine la operación actual.');
    }
    await _edit(id, (r) {
      final record = CabinetRecord(r);
      if (record.working['status'] != 'draft' ||
          record.server['status'] != null &&
              record.server['status'] != 'draft') {
        throw StateError('Esta foto ya forma parte de un registro cerrado.');
      }
      if (record.pending.any((o) => jsonEncode(o['body']).contains(photoId))) {
        throw StateError('La foto forma parte de una operación pendiente.');
      }
      final photos = objects(r['photos']);
      final photo = photos.firstWhere((p) => p['id'] == photoId);
      if (object(photo['metadata'])['context'] != 'registration') {
        throw StateError('La fotografía no es de registro.');
      }
      photo['deleting'] = true;
      photo['deleteActor'] = actor;
      r['photos'] = photos;
      final w = object(r['working']);
      w['registrationEvidence'] = objects(
        w['registrationEvidence'],
      ).where((e) => e['photoId'] != photoId).toList();
      r['working'] = w;
      r['dirty'] = true;
      r['draftActor'] = actor;
    });
    unawaited(synchronize());
  }

  Future<void> _finishPhotoDeletions(String id, String user) async {
    final record = store.read(id)!;
    for (final p in record.photos.where((p) => p['deleting'] == true)) {
      if (!allowed || actor != user || p['deleteActor'] != user) {
        throw StateError(
          'Reconecta al residente que solicitó eliminar la foto.',
        );
      }
      final photoId = '${p['id']}';
      final result = await remote.deletePhoto(id, photoId);
      if (result['deleted'] != true || result['photoId'] != photoId) {
        throw StateError('No se confirmó la eliminación de la foto.');
      }
      if (!allowed || actor != user) return;
      final journal = store.media.journal.find(photoId);
      final root = await (await camera.supportDirectory())
          .resolveSymbolicLinks();
      for (final path in <String?>[
        p['localPath'] as String?,
        p['thumbnailPath'] as String?,
        journal?.sourcePath,
        journal?.uploadPath,
        journal?.thumbnailPath,
      ].whereType<String>().toSet()) {
        final file = File(path);
        if (!await file.exists()) continue;
        final parent = await file.parent.resolveSymbolicLinks();
        if (!parent.startsWith('$root/cabinets/$id/')) {
          throw StateError('Ruta de foto fuera del expediente.');
        }
        if (await file.exists()) {
          if (!(await file.resolveSymbolicLinks()).startsWith(
            '$root/cabinets/$id/',
          )) {
            throw StateError('Ruta de foto no segura.');
          }
          await file.delete();
        }
      }
      await store.media.journalBox.delete(photoId);
      await store.media.photosBox.delete(photoId);
      await _edit(id, (r) {
        r['photos'] = objects(
          r['photos'],
        ).where((p) => p['id'] != photoId).toList();
        r['deletedPhotos'] = {
          ...(r['deletedPhotos'] as List? ?? []),
          photoId,
        }.toList();
      });
    }
  }

  Future<void> _adoptPhoto(ConstructionPhoto photo, Json intent) async {
    await _edit(photo.surveyId, (r) {
      final photos = objects(r['photos']);
      if (!photos.any((p) => p['id'] == photo.id) &&
          !(r['deletedPhotos'] as List? ?? []).contains(photo.id)) {
        photos.add({
          'id': photo.id,
          'actor': intent['actor'],
          'localPath': photo.localPath,
          'thumbnailPath': photo.thumbnailPath,
          'verified': false,
          'metadata': {
            'photoId': photo.id,
            'context': intent['context'],
            'clientSha256': photo.sha256,
            'capturedAt': photo.capturedAt.toUtc().toIso8601String(),
          },
        });
      }
      r['photos'] = photos;
    });
    await camera.advance(photo.id, ConstructionJournalState.committed);
  }

  Future<Json> installationGps() async {
    if (!allowed) throw StateError('Sin permiso.');
    final gps = await app.locations.capture();
    if (gps.accuracy <= 0 || gps.accuracy > 100) {
      throw StateError('Precisión GPS insuficiente.');
    }
    return {
      ...gpsWire(gps),
      'capturedAt': gps.capturedAt.toUtc().toIso8601String(),
    };
  }

  static Json gpsWire(GeoPoint gps) => {
    'latitude': gps.latitude,
    'longitude': gps.longitude,
    'accuracy': gps.accuracy,
    if (gps.altitude != null) 'altitude': gps.altitude,
  };
  Future<void> synchronize({bool force = false}) async {
    if (!allowed || (!app.online && !force) || syncing) return;
    syncing = true;
    _retry?.cancel();
    final user = actor!;
    _notify();
    if (remote is CabinetApi) (remote as CabinetApi).operationActor = user;
    try {
      // A cached offline permission never authorizes writes to an incompatible API.
      try {
        final catalog = CabinetCatalog(await remote.get('/catalog'));
        if (!allowed || actor != user) return;
        await store.saveCatalog(catalog);
      } catch (e) {
        await _handleAccess(e, user);
        if (e is FormatException ||
            (e is DioException && e.response?.statusCode == 404)) {
          await store.authorize(user, false);
        }
        message = explain(e);
        return;
      }
      // A failed dossier never blocks the remaining dossiers.
      for (final item in records) {
        if (!allowed || actor != user) break;
        if (item.json['deletion'] != null) {
          final d = object(item.json['deletion']);
          if (d['code'] == 'VERSION_CONFLICT') continue;
          if (!force &&
              DateTime.tryParse(
                    '${d['nextAttempt']}',
                  )?.isAfter(DateTime.now()) ==
                  true) {
            continue;
          }
          try {
            await _finishDeletion(item.id, user);
          } catch (e) {
            await _handleAccess(e, user);
            await _edit(item.id, (value) {
              final d = object(value['deletion']);
              d['error'] = explain(e);
              if (e is DioException) {
                d['code'] = object(e.response?.data)['code'];
              }
              d['nextAttempt'] = DateTime.now()
                  .add(const Duration(seconds: 30))
                  .toIso8601String();
              value['deletion'] = d;
            });
          }
          continue;
        }
        if (store.read(item.id)!.server.isNotEmpty &&
            store.read(item.id)!.photos.any((p) => p['deleting'] == true)) {
          try {
            await _finishPhotoDeletions(item.id, user);
          } catch (e) {
            await _handleAccess(e, user);
            message = explain(e);
            // Independent identity corrections must not be held by an unused-photo deletion.
          }
        }
        while (true) {
          final r = store.read(item.id)!;
          final op = r.pending.firstOrNull;
          if (op == null || op['actor'] != user || op['state'] == 'conflict') {
            break;
          }
          if (!force &&
              DateTime.tryParse(
                    '${op['nextAttempt']}',
                  )?.isAfter(DateTime.now()) ==
                  true) {
            break;
          }
          final body = object(op['body']), operationId = body['operationId'];
          if (!['register', 'identity_correct'].contains(body['type']) &&
              r.photos.any((p) => p['deleting'] == true)) {
            break;
          }
          try {
            Json? result;
            if (op['state'] == 'sending') {
              try {
                result = await remote.get('/${r.id}/operations/$operationId');
              } on DioException catch (e) {
                if (e.response?.statusCode != 404) rethrow;
              }
            }
            if (!allowed || actor != user) break;
            if (result == null) {
              if (body['type'] != 'register') {
                await _uploadReferences(r, body, user);
              }
              if (!allowed || actor != user) break;
              await _changeOperation(
                r.id,
                '$operationId',
                (o) => o['state'] = 'sending',
              );
              result = await remote.command(r.id, body);
            }
            final server = object(result['cabinet']);
            if (server['cabinetId'].toString().toLowerCase() != r.id ||
                server['version'] != (body['expectedVersion'] as num) + 1) {
              throw StateError(
                'Respuesta incompleta; se recuperará la operación.',
              );
            }
            await _edit(r.id, (value) {
              final ops = objects(value['operations']);
              final current = ops.firstWhere(
                (o) => object(o['body'])['operationId'] == operationId,
              );
              current['state'] = 'done';
              current['result'] = result;
              current.remove('error');
              current.remove('diagnostic');
              current.remove('problem');
              value['operations'] = ops;
              value['server'] = server;
              if (body['type'] == 'final_review' && value['dirty'] != true) {
                value['finalReviewDraft'] = <String, dynamic>{};
              }
              value['lastSent'] = DateTime.now().toUtc().toIso8601String();
              if (CabinetRecord(value).pending.isEmpty &&
                  value['dirty'] != true) {
                value['working'] = server;
              }
            });
          } catch (e) {
            await _handleAccess(e, user);
            final status = e is DioException ? e.response?.statusCode : null;
            await _changeOperation(r.id, '$operationId', (o) {
              final attempts = (o['attempts'] as int? ?? 0) + 1;
              o['attempts'] = attempts;
              o['error'] = explain(e);
              if (e is DioException) o['diagnostic'] = diagnostic(e);
              if (e is DioException && e.response != null) {
                o['problem'] = problemData(e.response!.data);
              }
              if (status != null &&
                  status >= 400 &&
                  status < 500 &&
                  status != 401 &&
                  status != 403 &&
                  status != 429 &&
                  !(e is DioException &&
                      problemData(e.response?.data)['retryable'] == true)) {
                o['state'] = 'conflict';
              }
              // Keep 'sending' after ambiguous failures; recover before retransmission.
              o['nextAttempt'] = DateTime.now()
                  .add(Duration(seconds: (1 << attempts.clamp(0, 8)) * 2))
                  .toIso8601String();
            });
            break;
          }
          if (!allowed || actor != user) break;
        }
        final latest = store.read(item.id)!;
        if (allowed && actor == user && latest.server.isNotEmpty) {
          for (final photo in latest.photos.where(
            (p) =>
                p['deleting'] != true &&
                p['verified'] != true &&
                p['remote'] != true &&
                p['actor'] == user &&
                object(p['metadata'])['accuracy'] != null,
          )) {
            if (!force &&
                DateTime.tryParse(
                      '${photo['nextAttempt']}',
                    )?.isAfter(DateTime.now()) ==
                    true) {
              continue;
            }
            try {
              await _uploadReferences(latest, {
                'evidence': [
                  {'photoId': photo['id']},
                ],
              }, user);
            } catch (e) {
              await _handleAccess(e, user);
              await _edit(latest.id, (r) {
                final photos = objects(r['photos']),
                    p = photos.firstWhere((p) => p['id'] == photo['id']);
                p['uploadError'] = explain(e);
                final attempts = (p['attempts'] as int? ?? 0) + 1;
                p['attempts'] = attempts;
                p['nextAttempt'] = DateTime.now()
                    .add(Duration(seconds: (1 << attempts.clamp(0, 8)) * 2))
                    .toIso8601String();
                r['photos'] = photos;
              });
            }
            if (!allowed || actor != user) break;
          }
        }
      }
    } finally {
      syncing = false;
      _notify();
      if (allowed &&
          records.any(
            (r) =>
                object(r.json['deletion'])['actor'] == actor ||
                r.photos.any(
                  (p) => p['deleting'] == true && p['deleteActor'] == actor,
                ) ||
                r.pending.any(
                  (o) => o['actor'] == actor && o['state'] != 'conflict',
                ) ||
                r.photos.any(
                  (p) =>
                      p['deleting'] != true &&
                      p['verified'] != true &&
                      p['remote'] != true &&
                      p['actor'] == actor &&
                      object(p['metadata'])['accuracy'] != null,
                ),
          )) {
        _retry = Timer(
          const Duration(seconds: 15),
          () => unawaited(synchronize()),
        );
      }
    }
  }

  Future<void> _uploadReferences(
    CabinetRecord r,
    Json body,
    String user,
  ) async {
    final ids = <String>{};
    void walk(Object? value) {
      if (value is Map) {
        if (value['photoId'] is String) ids.add(value['photoId'] as String);
        for (final v in value.values) {
          walk(v);
        }
      }
      if (value is List) {
        for (final v in value) {
          walk(v);
        }
      }
    }

    walk(body);
    for (final id in ids) {
      if (!allowed || actor != user) throw StateError('La sesión cambió.');
      final photo = store
          .read(r.id)!
          .photos
          .where((p) => p['id'] == id)
          .firstOrNull;
      if (photo != null &&
          photo['remote'] != true &&
          photo['verified'] != true) {
        if (photo['actor'] != user) {
          throw StateError(
            'Esta fotografía debe enviarla el residente que la capturó.',
          );
        }
        if (object(photo['metadata'])['accuracy'] == null) {
          throw StateError(
            'Fotografía conservada sin GPS válido; requiere nueva captura.',
          );
        }
        final file = File(photo['localPath']);
        if (!await file.exists() ||
            await sha256File(file) !=
                object(photo['metadata'])['clientSha256']) {
          throw StateError(
            'Archivo local faltante o alterado. Recupera el original; no se descarta evidencia.',
          );
        }
        await remote.upload(r.id, photo);
      }
      var result = await remote.verify(r.id, [id]);
      bool verified(Json result) => objects(result['items']).any(
        (p) =>
            '${p['photoId']}'.toLowerCase() == id.toLowerCase() &&
            p['storageVerified'] == true,
      );
      if (!verified(result) &&
          photo != null &&
          photo['remote'] != true &&
          photo['actor'] == user) {
        final file = File(photo['localPath']);
        if (await file.exists() &&
            await sha256File(file) ==
                object(photo['metadata'])['clientSha256']) {
          if (!allowed || actor != user) throw StateError('La sesión cambió.');
          await remote.upload(r.id, photo);
          result = await remote.verify(r.id, [id]);
        }
      }
      if (!objects(result['items']).any(
        (p) =>
            '${p['photoId']}'.toLowerCase() == id.toLowerCase() &&
            p['storageVerified'] == true,
      )) {
        throw StateError(
          'El servidor no confirmó la integridad de la fotografía.',
        );
      }
      if (photo != null) {
        await _edit(r.id, (value) {
          final photos = objects(value['photos']);
          final saved = photos.firstWhere((p) => p['id'] == id);
          saved['verified'] = true;
          saved.remove('uploadError');
          value['photos'] = photos;
        });
      }
    }
  }

  Future<void> _changeOperation(
    String id,
    String op,
    void Function(Json) change,
  ) => _edit(id, (r) {
    final operations = objects(r['operations']);
    change(
      operations.firstWhere((o) => object(o['body'])['operationId'] == op),
    );
    r['operations'] = operations;
  });

  /// The resident explicitly accepts the current profile company after a rejected
  /// registration. The API checks that company again when the new attempt runs.
  Future<void> reconcileRegistrationCompany(
    String id, {
    required String crewId,
    required String crewName,
  }) async {
    final user = actor;
    _requireWritable(id);
    if (crewId.trim().isEmpty || crewName.trim().isEmpty) {
      throw StateError('La cuenta necesita una empresa configurada.');
    }
    await _edit(id, (value) {
      if (!allowed || actor != user) throw StateError('La sesión cambió.');
      final current = CabinetRecord(value);
      final first = current.pending.firstOrNull;
      if (current.server.isNotEmpty ||
          first == null ||
          first['actor'] != user ||
          first['state'] != 'conflict' ||
          object(first['body'])['type'] != 'register' ||
          object(first['problem'])['code'] != 'COMPANY_CHANGED') {
        throw StateError(
          'El conflicto de empresa ya cambió. Actualiza el expediente.',
        );
      }
      final operations = current.operations;
      final index = operations.indexWhere(
        (op) =>
            object(op['body'])['operationId'] ==
            object(first['body'])['operationId'],
      );
      final original = operations[index];
      original['state'] = 'superseded';
      original['resolution'] =
          'Empresa actual confirmada explícitamente: $crewName ($crewId)';
      operations.insert(index + 1, {
        'body': {
          ...object(original['body']),
          'operationId': const Uuid().v4(),
          'expectedCrewId': crewId,
        },
        'actor': user,
        'state': 'queued',
        'attempts': 0,
      });
      value['operations'] = operations;
      value['working'] = {
        ...current.working,
        'registrationCompany': {
          'id': crewId,
          'name': crewName,
          'source': 'local_capture',
        },
      };
    });
    unawaited(synchronize());
  }

  /// Explicit conflict resolution preserves the original command, result, photos and draft.
  Future<void> reconcile(
    String id, {
    required bool retryLocal,
    required String reason,
  }) async {
    final r = record(id);
    if (reason.trim().length < 3 ||
        r.pending.isEmpty ||
        r.pending.first['state'] != 'conflict') {
      throw StateError('Consulta el conflicto y explica la resolución.');
    }
    if (r.pending.any((o) => o['actor'] != actor)) {
      throw StateError(
        'Sólo el actor original puede resolver sus operaciones pendientes.',
      );
    }
    await pull(id); // never rebase silently
    await _edit(id, (value) {
      final current = CabinetRecord(value), ops = current.operations;
      var version = (current.server['version'] as num).toInt();
      final replacements = <Json>[];
      final replacementIds = <String, String>{};
      for (final op in ops.where(
        (o) => !['done', 'superseded'].contains(o['state']),
      )) {
        op['state'] = 'superseded';
        op['resolution'] = reason;
        if (retryLocal) {
          final body = {
            ...object(op['body']),
            'operationId': const Uuid().v4(),
            'expectedVersion': version++,
          };
          replacementIds['${object(op['body'])['operationId']}'] =
              '${body['operationId']}';
          if (replacements.isEmpty) {
            final w = current.working;
            if (body['type'] == 'parts_save') {
              body['parts'] = w['parts'];
              body['reason'] = reason;
            }
            if (body['type'] == 'installation_save') {
              final install = object(w['installation']);
              install.removeWhere((k, v) => v == null && k != 'accountNumber');
              body['installation'] = install;
              body['reason'] = reason;
            }
            if (body['type'] == 'registration_close') {
              body['evidence'] = w['registrationEvidence'];
            }
            if (body['type'] == 'final_review') {
              final draft = object(value['finalReviewDraft']);
              if (draft['evidence'] != null) {
                body['evidence'] = draft['evidence'];
              }
              if (draft['reason'] != null) body['reason'] = draft['reason'];
              body['installationOperationId'] =
                  current.server['installationOperationId'];
              body['capturedAt'] = DateTime.now().toUtc().toIso8601String();
            }
          }
          if (body['type'] == 'final_review' &&
              replacementIds.containsKey(body['installationOperationId'])) {
            body['installationOperationId'] =
                replacementIds[body['installationOperationId']];
          }
          replacements.add({
            'body': body,
            'actor': actor,
            'state': 'queued',
            'attempts': 0,
          });
        }
      }
      value['operations'] = [...ops, ...replacements];
      if (!retryLocal) {
        value['preservedDraft'] = value['working'];
        value['working'] = value['server'];
        value['dirty'] = false;
      }
    });
    unawaited(synchronize());
  }

  Future<void> saveAuxDraft(String id, String key, Json draft) async {
    final user = actor;
    _requireWritable(id);
    await _edit(id, (r) {
      if (!allowed || actor != user) throw StateError('La sesión cambió.');
      final drafts = object(r['uiDrafts']);
      drafts[user!] = {...object(drafts[user]), key: clone(draft)};
      r['uiDrafts'] = drafts;
    });
  }

  Future<void> saveReviewDraft(String id, String field, Object? value) async {
    final user = actor;
    _requireWritable(id);
    await _edit(id, (r) {
      if (!allowed || actor != user) throw StateError('La sesión cambió.');
      r['draftActor'] = user;
      r['finalReviewDraft'] = {
        ...object(r['finalReviewDraft']),
        field: value,
        if (field == 'fieldChecked')
          'fieldCheckedAt': value == true
              ? DateTime.now().toUtc().toIso8601String()
              : null,
      };
      r['dirty'] = true;
      r['draftSavedAt'] = DateTime.now().toUtc().toIso8601String();
    });
  }

  final Map<String, Future<void>> _evidenceLoads = {};

  /// Reading shared evidence never requires ownership of unsent local edits.
  /// Persist metadata first; the gallery fetches bytes only when displayed.
  Future<void> downloadEvidence(String id) {
    final key = '$actor:$id';
    return _evidenceLoads.putIfAbsent(
      key,
      () => _loadEvidence(id).whenComplete(() {
        _evidenceLoads.remove(key);
      }),
    );
  }

  Future<void> _loadEvidence(String id) async {
    final current = record(id), user = actor;
    if (current.server.isEmpty) return;
    try {
      for (var page = 1; ; page++) {
        final rows = objects(
          (await remote.get('/$id/photos', {
            'page': page,
            'limit': 100,
          }))['items'],
        );
        await _edit(id, (r) {
          if (!allowed || actor != user) throw StateError('La sesión cambió.');
          final photos = objects(r['photos']);
          for (final row in rows) {
            final photoId = '${row['photo_id']}'.toLowerCase();
            if ((r['deletedPhotos'] as List? ?? []).contains(photoId)) continue;
            final index = photos.indexWhere(
              (p) => '${p['id']}'.toLowerCase() == photoId,
            );
            final old = index < 0 ? <String, dynamic>{} : photos[index];
            if (old['deleting'] == true) continue;
            final next = {
              ...old,
              'id': photoId,
              'actor': '${row['actor_user_id']}'.toLowerCase(),
              'serverSha256': row['server_sha256'],
              'metadata': {
                ...object(row['metadata']),
                ...object(old['metadata']),
              },
              if (index < 0) 'remote': true,
            };
            if (index < 0) {
              photos.add(next);
            } else {
              photos[index] = next;
            }
          }
          r['photos'] = photos;
          r['evidenceFetchedAt'] = DateTime.now().toUtc().toIso8601String();
          r.remove('evidenceError');
        });
        if (rows.length < 100) break;
      }
    } catch (e) {
      if (allowed && actor == user) {
        await _edit(id, (r) => r['evidenceError'] = explain(e));
      }
      rethrow;
    }
  }

  Future<void> resolveDuplicate(String id) async {
    final r = record(id), user = actor;
    if (r.json['actor'] != user) {
      throw StateError('Se requiere el actor original.');
    }
    final data = await remote.get('/resolve', {'uid': r.working['uid']});
    final c = object(data['cabinet']),
        remoteId = '${object(data['cabinet'])['cabinetId']}'.toLowerCase();
    if (!allowed || actor != user || remoteId == id) {
      throw StateError('Revisa la identidad del expediente.');
    }
    await _serial(() async {
      if (store.read(remoteId) == null) {
        await store.save({
          'id': remoteId,
          'actor': user,
          'working': c,
          'server': c,
          'operations': <Json>[],
          'photos': <Json>[],
        });
      }
      final saved = clone(store.read(id)!.json);
      saved['archived'] = true;
      saved['resolvedTo'] = remoteId;
      await store.save(saved);
    });
    _notify();
  }

  Future<void> _handleAccess(Object e, String user) async {
    if (e is DioException && [401, 403].contains(e.response?.statusCode)) {
      await store.authorize(user, false);
      _notify();
    }
  }

  Future<List<Json>> history(String id) async {
    record(id);
    final result = <Json>[];
    for (var page = 1; ; page++) {
      final rows = objects(
        (await remote.get('/$id/history', {
          'page': page,
          'limit': 100,
        }))['items'],
      );
      result.addAll(rows);
      if (rows.length < 100) break;
    }
    await _edit(id, (r) => r['history'] = result);
    return result;
  }

  final Map<String, Future<Uint8List>> _photoLoads = {};
  Future<Uint8List> photoBytes(
    String id,
    Json photo, {
    bool original = false,
  }) async {
    record(id);
    final user = actor;
    final key = '$user:$id:${photo['id']}:$original';
    final bytes = await _photoLoads.putIfAbsent(
      key,
      () => _readPhoto(id, photo, original: original, user: user).whenComplete(
        () {
          _photoLoads.remove(key);
        },
      ),
    );
    if (!allowed || actor != user) {
      throw StateError('Sin permiso para ver fotografías.');
    }
    return bytes;
  }

  Future<Uint8List> _readPhoto(
    String id,
    Json photo, {
    required bool original,
    required String? user,
  }) async {
    final saved =
        record(id).photos.where((p) => p['id'] == photo['id']).firstOrNull ??
        photo;
    final path = original
        ? saved['localPath']
        : saved['thumbnailPath'] ?? saved['localPath'];
    if (path != null && await File('$path').exists()) {
      return File('$path').readAsBytes();
    }
    final photoId = '${photo['id'] ?? photo['photo_id']}'.toLowerCase();
    final bytes = await remote.content(id, photoId, thumbnail: !original);
    if (!allowed || actor != user) {
      throw StateError('Sin permiso para ver fotografías.');
    }
    final dir = Directory(
      '${(await camera.supportDirectory()).path}/cabinets/$id/remote',
    );
    await dir.create(recursive: true);
    final file = File('${dir.path}/$photoId.${original ? 'jpg' : 'webp'}');
    await file.writeAsBytes(bytes, flush: true);
    if (original &&
        saved['serverSha256'] != null &&
        await sha256File(file) != '${saved['serverSha256']}'.toLowerCase()) {
      await file.delete();
      throw StateError('Hash remoto no coincide. Reintenta la descarga.');
    }
    await _edit(id, (r) {
      if (!allowed || actor != user) {
        throw StateError('Sin permiso para ver fotografías.');
      }
      final photos = objects(r['photos']);
      final index = photos.indexWhere((p) => p['id'] == photoId);
      if (index >= 0 && photos[index]['deleting'] != true) {
        photos[index][original ? 'localPath' : 'thumbnailPath'] = file.path;
        r['photos'] = photos;
      }
    });
    return bytes;
  }

  Json syncDiagnostics(String id) {
    final r = record(id);
    return {
      'schema': 1,
      'cabinetId': id,
      'uid': r.working['uid'],
      'localModel': r.working['model'],
      'serverModel': r.server['model'],
      'localStatus': r.working['status'],
      'serverStatus': r.server['status'],
      'serverVersion': r.server['version'],
      'dirty': r.json['dirty'] == true,
      'photoCount': r.photos.length,
      'photoDeletionsPending': r.photos
          .where((p) => p['deleting'] == true)
          .length,
      'photosWithoutGps': r.photos
          .where(
            (p) =>
                p['remote'] != true &&
                object(p['metadata'])['accuracy'] == null,
          )
          .length,
      'operations': [
        for (final op in r.pending)
          {
            'operationId': object(op['body'])['operationId'],
            'type': object(op['body'])['type'],
            'expectedVersion': object(op['body'])['expectedVersion'],
            'state': op['state'],
            'attempts': op['attempts'],
            'requiresOtherActor': op['actor'] != actor,
            'error': op['error'],
            'diagnostic': op['diagnostic'],
          },
      ],
    };
  }

  static Json diagnostic(DioException error) => {
    'type': error.type.name,
    'httpStatus': error.response?.statusCode,
    'method': error.requestOptions.method,
    'path': error.requestOptions.uri.path,
    'requestId': error.requestOptions.headers['X-Request-ID'],
    'at': DateTime.now().toUtc().toIso8601String(),
  };

  static Json problemData(Object? value) {
    try {
      if (value is List<int>) value = utf8.decode(value);
      if (value is String) value = jsonDecode(value);
      return object(value);
    } on FormatException {
      return {};
    }
  }

  static String explain(Object error) {
    if (error is DioException) {
      if (error.response?.statusCode == 401) {
        return 'La sesión no es válida para esta API. Reconecta tu sesión; las capturas siguen guardadas.';
      }
      if (error.response == null) {
        return switch (error.type) {
          DioExceptionType.receiveTimeout =>
            'Tiempo de respuesta agotado. Se comprobará si el servidor recibió la operación. Datos conservados.',
          DioExceptionType.sendTimeout =>
            'El envío no terminó a tiempo. Se reintentará conservando la operación y sus fotos.',
          DioExceptionType.connectionTimeout ||
          DioExceptionType.connectionError =>
            'No se pudo establecer conexión con la API. Datos conservados; reintenta al recuperar conexión.',
          DioExceptionType.cancel => 'Solicitud cancelada. Datos conservados.',
          _ =>
            'No se recibió confirmación de la API (${error.type.name}). Datos conservados.',
        };
      }
      final data = problemData(error.response?.data);
      final pending = objects(data['blocking']).isNotEmpty
          ? objects(data['blocking'])
          : objects(data['pending']);
      final details = pending
          .map((p) => '${p['subject']}: ${p['reason']}')
          .join('\n');
      return '${data['code'] ?? 'HTTP ${error.response?.statusCode}'}: ${data['detail'] ?? 'El servidor devolvió una respuesta inesperada. Datos conservados.'}${details.isEmpty ? '' : '\n$details'}';
    }
    if (error is FileSystemException) {
      return error.osError?.errorCode == 28
          ? 'No hay espacio suficiente. Libera almacenamiento y reintenta; las capturas previas se conservan.'
          : 'No se pudo guardar o leer el archivo. Conserva el expediente y revisa el almacenamiento.';
    }
    if (error is StateError) return error.message;
    if (error is FormatException) return error.message;
    return error.toString();
  }

  @override
  void dispose() {
    _disposed = true;
    app.removeListener(_appChanged);
    WidgetsBinding.instance.removeObserver(this);
    _retry?.cancel();
    unawaited(_cabinetFixes?.cancel());
    super.dispose();
  }
}
