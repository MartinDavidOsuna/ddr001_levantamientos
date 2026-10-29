import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';
import 'hydrostatic_repository.dart';
import 'hydrostatic_sync_api.dart';
import 'hydrostatic_sync_store.dart';

String hydroSyncHash(String value) =>
    sha256.convert(utf8.encode(value)).toString();

/// Independent durable delivery. The source document/journal/photos are never
/// rewritten from an HTTP response. One flight and one unresolved command/test.
class HydrostaticSync extends ChangeNotifier {
  HydrostaticSync({
    required this.repository,
    required this.store,
    required this.remote,
    required this.identity,
    required this.verifySession,
    required this.online,
    required this.enabled,
    DateTime Function()? now,
    double Function()? jitter,
  }) : now = now ?? (() => DateTime.now().toUtc()),
       jitter = jitter ?? Random().nextDouble;
  final HydrostaticRepository repository;
  final HydrostaticSyncStore store;
  final HydrostaticSyncRemote remote;
  final HydrostaticSyncIdentity? Function() identity;
  final Future<void> Function() verifySession;
  final bool Function() online;
  final bool enabled;
  final DateTime Function() now;
  final double Function() jitter;
  Future<void>? _flight;
  bool _disposed = false;
  String? error;
  bool get busy => _flight != null;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _scope(HydrostaticSyncIdentity expected) => hydroRequire(
    !_disposed && identity()?.key == expected.key,
    'SESSION_CHANGED',
    'Sesión cambiada; datos conservados.',
  );
  HydroJson? view(String id) {
    final s = identity();
    if (s == null) return null;
    HydroJson? r;
    try {
      r = store.read(id);
    } catch (_) {
      // Do not expose an unreadable record to a different actor.
      final t = repository.get(id);
      if (t?.actor.userId != s.actorId ||
          t?.actor.deviceInstallationId != s.installationId) {
        return null;
      }
      return {
        'active': {'state': 'CORRUPT'},
      };
    }
    return r != null &&
            r['actorId'] == s.actorId &&
            r['installationId'] == s.installationId
        ? r
        : null;
  }

  String label(HydrostaticTest test) {
    if (!enabled) return 'Sólo local · sincronización no habilitada';
    HydroJson? r;
    try {
      r = view(test.id);
    } catch (_) {
      return 'Outbox requiere recuperación · originales conservados';
    }
    if (r == null) return 'Documento pendiente de envío · fotos locales';
    final active = r['active'] == null ? null : hydroObject(r['active']);
    if (active != null) {
      return switch (active['state']) {
        'IN_FLIGHT' => 'Enviando documento · fotos locales',
        'SENT_UNKNOWN' =>
          'Respuesta pendiente de recuperar · datos conservados',
        'CONFLICT' =>
          'Conflicto de revisión · requiere revisión, datos conservados',
        'REJECTED' => 'Documento rechazado · ${active['errorCode']}',
        'PAUSED' => 'Envío pausado por sesión o permisos',
        'CORRUPT' => 'Outbox requiere recuperación · originales conservados',
        _ => 'Documento pendiente de envío · fotos locales',
      };
    }
    return r['acceptedSourceRevision'] == test.revision
        ? 'Documento recibido · fotos e historial pendientes de transferencia'
        : 'Cambios locales pendientes de envío';
  }

  Future<void> run({bool manual = false}) {
    if (_disposed || !enabled) return Future.value();
    return _flight ??= store.serial(() => _run(manual)).whenComplete(() {
      _flight = null;
      _notify();
    });
  }

  Future<void> _run(bool manual) async {
    error = null;
    final s = identity();
    if (s == null) return;
    try {
      await verifySession();
      _scope(s);
      if (repository.store.recoveryRequired) return;
      final docs = repository
          .forUser()
          .where((t) => t.actor.deviceInstallationId == s.installationId)
          .toList();
      // Queue even offline. Deletion is pinned under the same source writer.
      for (final t in docs) {
        _scope(s);
        try {
          await _enqueue(t.id, s);
        } catch (_) {
          error = 'No se pudo preparar un envío; originales conservados.';
        }
      }
      _notify();
      if (!online()) return;
      final pending = docs.where((t) {
        try {
          return store.read(t.id)?['active'] != null;
        } catch (_) {
          error = 'Outbox requiere revisión; originales conservados.';
          return false;
        }
      }).toList();
      if (pending.isEmpty) return;
      final cap = await remote.capabilities(s);
      _scope(s);
      hydroRequire(
        cap['contractVersion'] == 'hydrostatic-sync-v1' &&
            cap['available'] == true &&
            cap['environment'] == 'TEST' &&
            hydroObject(cap['features'])['documentPersistence'] == true &&
            hydroObject(cap['features'])['durableReceipts'] == true &&
            (cap['commands'] as List?)?.contains('REGISTER_DOCUMENT') == true &&
            (cap['commands'] as List?)?.contains('UPDATE_DOCUMENT') == true,
        'CONTRACT_UNAVAILABLE',
        'API TEST compatible no disponible.',
      );
      for (final t in pending) {
        _scope(s);
        if (!online()) break;
        try {
          // Bounded drain lets another dossier progress even under continuous edits.
          for (var n = 0; n < 3; n++) {
            final r = store.read(t.id);
            if (r == null || r['active'] == null) break;
            final a = hydroObject(r['active']);
            if (!manual &&
                (['CONFLICT', 'REJECTED'].contains(a['state']) ||
                    (a['retryAt'] != null &&
                        now().isBefore(DateTime.parse(a['retryAt']))))) {
              break;
            }
            final accepted = await _send(t.id, s);
            if (!accepted) break;
            await _enqueue(t.id, s);
          }
        } catch (_) {
          error = 'Un envío requiere recuperación; los demás continúan.';
        }
      }
    } catch (e) {
      error = e is HydrostaticSyncFailure && [401, 403].contains(e.status)
          ? 'Sesión o permisos no vigentes; envío pausado.'
          : 'Sincronización pendiente. Datos y fotografías conservados.';
    }
  }

  Future<void> _enqueue(
    String id,
    HydrostaticSyncIdentity s,
  ) => repository.store.serial(() async {
    _scope(s);
    if (repository.store.recoveryRequired) return;
    final t = repository.get(id);
    if (t == null || t.actor.deviceInstallationId != s.installationId) return;
    var row =
        store.read(id) ??
        <String, dynamic>{
          'schemaVersion': 1,
          'testId': id,
          'actorId': t.actor.userId,
          'installationId': t.actor.deviceInstallationId,
          'serverVersion': 0,
          'acceptedSourceRevision': null,
          'acceptedSourceHash': null,
          'receipts': <dynamic>[],
          'segments': <dynamic>[],
          'active': null,
        };
    if (row['active'] != null || row['acceptedSourceRevision'] == t.revision) {
      return;
    }
    hydroRequire(
      row['actorId'] == s.actorId && row['installationId'] == s.installationId,
      'ORIGIN_CONFLICT',
      'No se cambia el propietario del outbox.',
    );
    final segments = List<dynamic>.from(row['segments']);
    // Freeze journal segments locally. HAPI-2 receives only the manifest, not
    // history bytes, which remain durable for HAPI-4 and are never called synced.
    for (final entry in repository.journal.entries.where(
      (e) => e['testId'] == id && e['phase'] == 'APPLIED',
    )) {
      if (segments.any((e) => e['segmentId'] == entry['operationId'])) continue;
      final bytes = canonicalHydroJson(entry);
      segments.add({
        'segmentId': entry['operationId'],
        'sha256': hydroSyncHash(bytes),
        'byteLength': utf8.encode(bytes).length,
        'operationCount': 1,
        'json': bytes,
      });
    }
    final intents = <HydroJson>[];
    for (final key in repository.store.metadata.keys.where(
      (k) => '$k'.startsWith('capture:'),
    )) {
      final capture = repository.store.read(repository.store.metadata, '$key')!;
      if (capture['testId'] == id) intents.add(capture);
    }
    final payload = canonicalHydroJson({
      'document': t.toJson(),
      'baseSourceRevision': row['acceptedSourceRevision'],
      'baseSourceHash': row['acceptedSourceHash'],
      'historyManifest': segments
          .map(
            (e) => {
              'segmentId': e['segmentId'],
              'sha256': e['sha256'],
              'byteLength': e['byteLength'],
              'operationCount': e['operationCount'],
            },
          )
          .toList(),
      'captureIntents': intents,
    });
    hydroRequire(
      utf8.encode(payload).length <= 8 * 1024 * 1024,
      'PAYLOAD_TOO_LARGE',
      'Documento excede límite HAPI-2; se conserva localmente.',
    );
    final command = <String, dynamic>{
      'contractVersion': 'hydrostatic-sync-v1',
      'operationId': const Uuid().v4(),
      'expectedVersion': row['serverVersion'],
      'type': row['acceptedSourceRevision'] == null
          ? 'REGISTER_DOCUMENT'
          : 'UPDATE_DOCUMENT',
      'originInstallationId': s.installationId,
      'payloadJson': payload,
      'payloadSha256': hydroSyncHash(payload),
      'clientCreatedAt': now().toUtc().toIso8601String(),
    };
    // Pin first. A crash before queue write may leave a conservative pin; the
    // next scan reconstructs the unsent snapshot, never deletes the source.
    await repository.store.write(
      repository.store.metadata,
      'syncProtected:$id',
      {'testId': id, 'actorId': s.actorId},
      'syncProtection',
    );
    row = {
      ...row,
      'segments': segments,
      'active': {
        'state': 'PENDING',
        'command': command,
        'sourceRevision': t.revision,
        'attempts': 0,
        'retryAt': null,
        'errorCode': null,
      },
    };
    await store.save(id, row, 'enqueue');
  });

  Future<bool> _send(String id, HydrostaticSyncIdentity s) async {
    var row = store.read(id)!;
    var active = hydroObject(row['active']);
    final command = hydroObject(active['command']);
    final recovering = active['state'] != 'PENDING';
    try {
      await verifySession();
      _scope(s);
      active = {
        ...active,
        'state': 'IN_FLIGHT',
        'attempts': (active['attempts'] as int) + 1,
        'lastAttemptAt': now().toUtc().toIso8601String(),
      };
      row = {...row, 'active': active};
      await store.save(id, row, 'sending');
      _scope(s);
      _notify();
      HydroJson? receipt;
      if (recovering) {
        try {
          receipt = await remote.receipt(id, command['operationId'], s);
        } on HydrostaticSyncFailure catch (e) {
          if (e.status != 404 ||
              !['OPERATION_NOT_FOUND', 'NOT_FOUND'].contains(e.code)) {
            rethrow;
          }
        }
        _scope(s);
      }
      receipt ??= await remote.command(id, command, s);
      _scope(s);
      _validateReceipt(id, command, active, receipt, s);
      // Atomic sidecar record contains both receipt and accepted head.
      await store.save(id, {
        ...row,
        'active': null,
        'serverVersion': receipt['serverVersion'],
        'acceptedSourceRevision': receipt['acceptedSourceRevision'],
        'acceptedSourceHash': receipt['acceptedSourceHash'],
        'lastCommitAt': receipt['committedAt'],
        'validationState': receipt['validationState'],
        'receipts': [
          ...List<dynamic>.from(row['receipts']),
          {'command': command, 'receipt': receipt},
        ],
      }, 'acknowledge');
      _notify();
      return true;
    } catch (e) {
      // An injected failure after durable ACK must not resurrect the old command.
      row = store.read(id)!;
      if (row['active'] == null) return true;
      active = hydroObject(row['active']);
      final f = e is HydrostaticSyncFailure ? e : null;
      final changed = identity()?.key != s.key;
      final state = changed || [401, 403].contains(f?.status)
          ? 'PAUSED'
          : f?.status == 409
          ? 'CONFLICT'
          : f?.status != null &&
                f!.status! >= 400 &&
                f.status! < 500 &&
                ![408, 429].contains(f.status)
          ? 'REJECTED'
          : 'SENT_UNKNOWN';
      HydroJson? conflict;
      if (state == 'CONFLICT') {
        try {
          conflict = await remote.status(id, active['sourceRevision'], s);
          _scope(s);
        } catch (_) {
          /* Conflict remains unresolved; never overwrite local. */
        }
      }
      final attempt = (active['attempts'] as int).clamp(1, 10);
      final seconds = min(1800, (1 << attempt) * 5) + (jitter() * 5).floor();
      await store.save(id, {
        ...row,
        'active': {
          ...active,
          'state': state,
          'errorCode':
              f?.code ??
              (changed ? 'SESSION_CHANGED' : 'LOCAL_OR_NETWORK_FAILURE'),
          'retryAt': now()
              .add(Duration(seconds: seconds))
              .toUtc()
              .toIso8601String(),
          'remoteStatus': ?conflict,
        },
      }, 'failure');
      _notify();
      return false;
    }
  }

  void _validateReceipt(
    String id,
    HydroJson c,
    HydroJson a,
    HydroJson r,
    HydrostaticSyncIdentity s,
  ) {
    final fingerprint = hydroSyncHash(
      jsonEncode([
        'hapi-op-v1',
        id,
        c['operationId'],
        'field',
        s.actorId,
        c['originInstallationId'],
        c['type'],
        c['expectedVersion'],
        c['payloadSha256'],
        c['clientCreatedAt'],
      ]),
    );
    hydroRequire(
      r['contractVersion'] == 'hydrostatic-sync-v1' &&
          r['receiptState'] == 'COMMITTED' &&
          r['documentStored'] == true &&
          r['testId'] == id &&
          r['operationId'] == c['operationId'] &&
          r['acceptedSourceHash'] == c['payloadSha256'] &&
          r['acceptedSourceRevision'] == a['sourceRevision'] &&
          r['requestSha256'] == fingerprint &&
          r['serverVersion'] is int &&
          r['serverVersion'] == c['expectedVersion'] + 1 &&
          DateTime.tryParse('${r['committedAt']}') != null,
      'INVALID_RECEIPT',
      'Recibo no verificable; conserva operación para recuperación.',
    );
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
