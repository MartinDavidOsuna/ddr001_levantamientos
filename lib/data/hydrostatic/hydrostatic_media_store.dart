import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';

/// Delivery sidecar. Each test's immutable commands, receipts and head are
/// written together; there is no multi-box acknowledgement transaction.
class HydrostaticMediaStore {
  HydrostaticMediaStore._(this.box);
  static const name = 'hydrostatic_media_sync_v1';
  final Box<String> box;
  Future<void> Function(String boundary)? fault;
  Future<void> _tail = Future.value();
  static Future<HydrostaticMediaStore> open(Directory directory) async {
    hydroRequire(
      !Hive.isBoxOpen(name),
      'SYNC_ALREADY_OPEN',
      'Un solo escritor de sincronización.',
    );
    await directory.create(recursive: true);
    return HydrostaticMediaStore._(
      await Hive.openBox<String>(name, path: directory.path),
    );
  }

  Future<T> serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  HydroJson? read(String id) {
    final raw = box.get(id);
    if (raw == null) return null;
    final row = hydroObject(jsonDecode(raw));
    final body = hydroObject(row['body']);
    hydroRequire(
      body['schemaVersion'] == 1 &&
          row['sha256'] ==
              sha256.convert(utf8.encode(canonicalHydroJson(body))).toString(),
      'SYNC_CORRUPT',
      'Outbox ilegible; no se elimina ni se reenvía a ciegas.',
    );
    return body;
  }

  Future<void> save(String id, HydroJson row, String boundary) async {
    await fault?.call('before:$boundary');
    await box.put(
      id,
      jsonEncode({
        'body': row,
        'sha256': sha256
            .convert(utf8.encode(canonicalHydroJson(row)))
            .toString(),
      }),
    );
    await box.flush();
    await fault?.call('after:$boundary');
  }

  Future<void> close() async {
    await _tail;
    await box.close();
  }
}
