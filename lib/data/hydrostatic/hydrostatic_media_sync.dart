import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import '../../core/network/api_client.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';
import 'hydrostatic_media_store.dart';
import 'hydrostatic_sync.dart';
import 'hydrostatic_sync_api.dart';

abstract interface class HydrostaticMediaRemote {
  Future<HydroJson> status(
    String test,
    String evidence,
    HydrostaticSyncIdentity actor,
  );
  Future<HydroJson> upload(
    HydrostaticEvidence evidence,
    File original,
    String mime,
    HydrostaticSyncIdentity actor,
    void Function(int, int) progress,
  );
}

class HydrostaticMediaApi implements HydrostaticMediaRemote {
  HydrostaticMediaApi(this.client);
  final ApiClient client;
  Options options(HydrostaticSyncIdentity s) => Options(
    extra: {
      'expectedActor': s.actorId,
      'expectedSessionId': s.sessionId,
      'expectedInstallationId': s.installationId,
    },
  );
  String path(String t, String e) =>
      '${HydrostaticSyncApi.root}/$t/evidences/$e';
  @override
  Future<HydroJson> status(
    String t,
    String e,
    HydrostaticSyncIdentity s,
  ) async => hydroObject(
    (await client.dio.get('${path(t, e)}/status', options: options(s))).data,
  );
  @override
  Future<HydroJson> upload(
    HydrostaticEvidence e,
    File file,
    String mime,
    HydrostaticSyncIdentity s,
    void Function(int, int) progress,
  ) async {
    final o = options(s);
    o.headers = {'Content-Type': mime, 'Content-Length': e.byteLength};
    return hydroObject(
      (await client.dio.put(
        '${path(e.testId, e.id)}/content',
        data: file.openRead(),
        options: o,
        onSendProgress: progress,
      )).data,
    );
  }
}

/// Separate durable sidecar. Never deletes originals or mutates document receipts.
class HydrostaticMediaSync {
  HydrostaticMediaSync({
    required this.documents,
    required this.store,
    required this.remote,
    required this.support,
    DateTime Function()? now,
  }) : now = now ?? (() => DateTime.now().toUtc());
  final HydrostaticSync documents;
  final HydrostaticMediaStore store;
  final HydrostaticMediaRemote remote;
  final Directory support;
  final DateTime Function() now;
  Future<void>? _flight;
  void Function()? onChanged;
  final Map<String, double> progress = {};
  bool _disposed = false;
  void scope(HydrostaticSyncIdentity s) => hydroRequire(
    !_disposed && documents.identity()?.key == s.key,
    'SESSION_CHANGED',
    'Sesión cambiada; fotos conservadas.',
  );
  HydroJson? view(HydrostaticTest t, HydrostaticEvidence e) {
    final s = documents.identity();
    if (s == null ||
        t.actor.userId != s.actorId ||
        t.actor.deviceInstallationId != s.installationId) {
      return null;
    }
    try {
      return store.read(e.id);
    } catch (_) {
      return {'state': 'ERROR', 'error': 'MEDIA_OUTBOX_CORRUPT'};
    }
  }

  String label(HydrostaticTest t) {
    final rows = t.evidence.map((e) => view(t, e)).toList();
    if (rows.any((r) => r?['state'] == 'ERROR')) {
      return 'Error de evidencia · originales conservados';
    }
    if (rows.any((r) => r?['state'] == 'SENDING')) {
      return 'Fotografías enviándose';
    }
    if (rows.isNotEmpty && rows.every((r) => r?['state'] == 'VERIFIED')) {
      return 'Fotografías verificadas · expediente pendiente de historial';
    }
    return 'Fotografías pendientes';
  }

  Future<void> run({bool manual = false}) => _flight ??= store
      .serial(() => _run(manual))
      .whenComplete(() => _flight = null);
  Future<void> _run(bool manual) async {
    final s = documents.identity();
    if (s == null || !documents.enabled || _disposed) {
      return;
    }
    await documents.verifySession();
    scope(s);
    if (documents.repository.store.recoveryRequired) return;
    bool capabilityChecked = false;
    for (final t in documents.repository.forUser()) {
      scope(s);
      final receipt = documents.view(t.id);
      if (t.actor.deviceInstallationId != s.installationId ||
          receipt?['active'] != null ||
          receipt?['acceptedSourceRevision'] != t.revision) {
        continue;
      }
      for (final e in t.evidence) {
        scope(s);
        HydroJson? saved;
        try {
          saved = store.read(e.id);
        } catch (_) {
          onChanged?.call();
          continue;
        }
        var r =
            saved ??
            <String, dynamic>{
              'schemaVersion': 1,
              'testId': t.id,
              'evidenceId': e.id,
              'actorId': s.actorId,
              'installationId': s.installationId,
              'path': e.originalPath,
              'sha256': e.sha256,
              'bytes': e.byteLength,
              'sourceRevision': t.revision,
              'state': 'PENDING',
              'attempts': 0,
            };
        if (r['actorId'] != s.actorId ||
            r['installationId'] != s.installationId ||
            r['sha256'] != e.sha256 ||
            r['testId'] != t.id) {
          continue;
        }
        if (r['state'] == 'VERIFIED') continue;
        if (!manual &&
            r['retryAt'] != null &&
            now().isBefore(DateTime.parse(r['retryAt']))) {
          continue;
        }
        await store.save(e.id, r, 'enqueue');
        if (!documents.online()) continue;
        try {
          if (!capabilityChecked) {
            final cap = await documents.remote.capabilities(s);
            scope(s);
            if (hydroObject(cap['features'])['photoUpload'] != true) return;
            capabilityChecked = true;
          }
          final file = File('${support.path}/${e.originalPath}');
          hydroRequire(
            await file.exists(),
            'PHOTO_MISSING',
            'Original ausente.',
          );
          // Canonical containment protects against links into another module.
          final canonical = await file.resolveSymbolicLinks();
          final base = await Directory(
            '${support.path}/hydrostatic/${t.id}/evidence',
          ).resolveSymbolicLinks();
          hydroRequire(
            canonical.startsWith('$base/'),
            'PHOTO_PATH',
            'Ruta de original inválida.',
          );
          hydroRequire(
            await file.length() == e.byteLength &&
                (await sha256.bind(file.openRead()).first).toString() ==
                    e.sha256,
            'PHOTO_CORRUPT',
            'Original no coincide con su SHA-256.',
          );
          scope(s);
          var ack = await remote.status(t.id, e.id, s);
          scope(s);
          if (!_verified(ack, e)) {
            r = {
              ...r,
              'state': 'SENDING',
              'attempts': (r['attempts'] as int) + 1,
            };
            await store.save(e.id, r, 'sending');
            onChanged?.call();
            final h = await file.open();
            late List<int> magic;
            try {
              magic = await h.read(12);
            } finally {
              await h.close();
            }
            final mime = magic.length >= 3 && magic[0] == 255 && magic[1] == 216
                ? 'image/jpeg'
                : magic.length >= 8 && magic[0] == 137 && magic[1] == 80
                ? 'image/png'
                : magic.length >= 12 &&
                      String.fromCharCodes(magic.sublist(0, 4)) == 'RIFF' &&
                      String.fromCharCodes(magic.sublist(8, 12)) == 'WEBP'
                ? 'image/webp'
                : '';
            hydroRequire(
              mime.isNotEmpty,
              'PHOTO_FORMAT',
              'Formato no admitido.',
            );
            scope(s);
            ack = await remote.upload(e, file, mime, s, (sent, total) {
              progress[e.id] = total > 0 ? sent / total : 0;
              onChanged?.call();
            });
            scope(s);
          }
          hydroRequire(
            _verified(ack, e),
            'PHOTO_ACK_INVALID',
            'Servidor no confirmó integridad.',
          );
          r = {
            ...r,
            'state': 'VERIFIED',
            'receipt': ack,
            'retryAt': null,
            'error': null,
          };
          await store.save(e.id, r, 'verified');
        } catch (error) {
          final attempts = (r['attempts'] as int) + 1;
          r = {
            ...r,
            'state': 'ERROR',
            'attempts': attempts,
            'error': error is HydrostaticException
                ? error.code
                : 'TRANSFER_OR_SESSION',
            'retryAt': now()
                .add(
                  Duration(
                    seconds: min(3600, 30 * pow(2, min(attempts, 7)).toInt()),
                  ),
                )
                .toIso8601String(),
          };
          await store.save(e.id, r, 'retry');
        } finally {
          progress.remove(e.id);
          onChanged?.call();
        }
      }
    }
  }

  bool _verified(HydroJson r, HydrostaticEvidence e) =>
      r['verified'] == true &&
      r['integrityState'] == 'VERIFIED' &&
      r['uploadState'] == 'STORED' &&
      r['testId'] == e.testId &&
      r['evidenceId'] == e.id &&
      r['sha256'] == e.sha256 &&
      r['byteLength'] == e.byteLength;
  void dispose() {
    _disposed = true;
    onChanged = null;
  }
}
