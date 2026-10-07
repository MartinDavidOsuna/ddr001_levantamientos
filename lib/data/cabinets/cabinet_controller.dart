import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:uuid/uuid.dart';
import '../../core/media/photo_capture_service.dart';
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
           PhotoCaptureService(local: store.media, directoryName: 'cabinets') {
    app.addListener(_appChanged);
    WidgetsBinding.instance.addObserver(this);
  }
  final AppController app;
  final CabinetStore store;
  final CabinetRemote remote;
  final PhotoCaptureService camera;
  Timer? _retry;
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
      !app.config.isProduction &&
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
    await recoverPhotos();
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
    _notify();
    try {
      final catalog = CabinetCatalog(await remote.get('/catalog'));
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
    if (allowed && actor == user) unawaited(synchronize());
  }

  Future<void> pull(String id) async {
    if (!allowed) return;
    final user = actor;
    final response = await remote.get('/$id');
    final cabinet = object(response['cabinet']);
    if (!allowed || actor != user) return;
    final version = cabinet['catalogVersion'] as String;
    if (store.catalog(version) == null) {
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
      final installation = object(w['installation']);
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
            final catalog = store.catalog()!;
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
      await _edit(id, (r) => r['captureIntent'] = intent);
      final photo = await camera.capture(surveyId: id);
      if (photo == null) return;
      // Persist before GPS/network; a failed GPS never discards the photo.
      await _adoptPhoto(photo, intent);
      try {
        final gps = await app.locations.capture();
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
            'Foto conservada, GPS pendiente: ${explain(e)}. Captura otra evidencia con GPS; no se sustituye su ubicación.';
      }
    } finally {
      capturing = false;
      _notify();
    }
    if (actor == user) unawaited(synchronize());
  }

  Future<void> _adoptPhoto(ConstructionPhoto photo, Json intent) async {
    await _edit(photo.surveyId, (r) {
      final photos = objects(r['photos']);
      if (!photos.any((p) => p['id'] == photo.id)) {
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
              if (e is DioException && e.response != null) {
                o['problem'] = e.response!.data;
              }
              if (status != null &&
                  status >= 400 &&
                  status < 500 &&
                  status != 401 &&
                  status != 403 &&
                  status != 429 &&
                  !(e is DioException &&
                      object(e.response?.data)['retryable'] == true)) {
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
                p['verified'] != true &&
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
                r.pending.any(
                  (o) => o['actor'] == actor && o['state'] != 'conflict',
                ) ||
                r.photos.any(
                  (p) =>
                      p['verified'] != true &&
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
      if (photo != null && photo['verified'] != true) {
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

  Future<void> downloadEvidence(String id) async {
    record(id);
    final user = actor;
    for (var page = 1; ; page++) {
      final rows = objects(
        (await remote.get('/$id/photos', {
          'page': page,
          'limit': 100,
        }))['items'],
      );
      for (final row in rows) {
        if (!allowed || actor != user) return;
        final photoId = '${row['photo_id']}'.toLowerCase();
        if (store.read(id)!.photos.any((p) => p['id'] == photoId)) continue;
        final bytes = await remote.content(id, photoId, thumbnail: false);
        final dir = Directory(
          '${(await camera.supportDirectory()).path}/cabinets/$id/remote',
        );
        await dir.create(recursive: true);
        final file = File('${dir.path}/$photoId.jpg');
        await file.writeAsBytes(bytes, flush: true);
        if (await sha256File(file) != row['server_sha256']) {
          throw StateError('Hash remoto no coincide.');
        }
        await _edit(
          id,
          (r) => r['photos'] = [
            ...objects(r['photos']),
            {
              'id': photoId,
              'actor': '${row['actor_user_id']}'.toLowerCase(),
              'localPath': file.path,
              'verified': true,
              'remote': true,
              'metadata': object(row['metadata']),
            },
          ],
        );
      }
      if (rows.length < 100) break;
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

  Future<Uint8List> photoBytes(
    String id,
    Json photo, {
    bool original = false,
  }) async {
    record(id);
    final user = actor;
    final path = original
        ? photo['localPath']
        : photo['thumbnailPath'] ?? photo['localPath'];
    final bytes = path != null && await File('$path').exists()
        ? await File('$path').readAsBytes()
        : await remote.content(
            id,
            '${photo['id'] ?? photo['photo_id']}',
            thumbnail: !original,
          );
    if (!allowed || actor != user) {
      throw StateError('Sin permiso para ver fotografías.');
    }
    return bytes;
  }

  static String explain(Object error) {
    if (error is DioException) {
      final data = object(error.response?.data);
      final pending = objects(data['blocking']).isNotEmpty
          ? objects(data['blocking'])
          : objects(data['pending']);
      final details = pending
          .map((p) => '${p['subject']}: ${p['reason']}')
          .join('\n');
      return '${data['code'] ?? 'CONNECTION'}: ${data['detail'] ?? 'No se pudo comunicar con la API. Datos conservados.'}${details.isEmpty ? '' : '\n$details'}';
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
    super.dispose();
  }
}
