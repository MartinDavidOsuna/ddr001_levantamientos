import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';

enum HydrostaticOperationPhase {
  prepared,
  applyReady,
  closePendingTime,
  applied,
  recoverable,
  error,
}

typedef HydrostaticWriteFault = Future<void> Function(String boundary);

class HydrostaticStore {
  HydrostaticStore._(this.documents, this.journal, this.metadata, this.fault);
  final Box<String> documents, journal, metadata;
  HydrostaticWriteFault? fault;
  Future<void> _tail = Future.value();
  bool recoveryRequired = false;
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  static bool _opening = false;
  static const names = [
    'hydrostatic_documents_v1',
    'hydrostatic_journal_v1',
    'hydrostatic_metadata_v1',
  ];
  static Future<HydrostaticStore> open(
    Directory directory, {
    HydrostaticWriteFault? fault,
  }) async {
    hydroRequire(
      !_opening && !names.any(Hive.isBoxOpen),
      'STORE_ALREADY_OPEN',
      'Una instancia escritora por proceso.',
    );
    _opening = true;
    final boxes = <Box<String>>[];
    try {
      await directory.create(recursive: true);
      for (final name in names) {
        boxes.add(await Hive.openBox<String>(name, path: directory.path));
      }
      final store = HydrostaticStore._(boxes[0], boxes[1], boxes[2], fault);
      final version = store.metadata.get('schemaVersion');
      hydroRequire(
        version == null || version == '1',
        'SCHEMA_UNSUPPORTED',
        'Esquema local no compatible; datos conservados.',
      );
      await store.metadata.put('schemaVersion', '1');
      await store.metadata.flush();
      store.recoveryRequired = store.journal.keys.any(
        (k) =>
            '$k'.startsWith('op:') &&
            ![
              'APPLIED',
              'ERROR',
            ].contains(store.read(store.journal, '$k')?['phase']),
      );
      return store;
    } catch (_) {
      for (final b in boxes) {
        await b.close();
      }
      rethrow;
    } finally {
      _opening = false;
    }
  }

  Future<T> serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  HydroJson? read(Box<String> box, String key) {
    final raw = box.get(key);
    if (raw == null) return null;
    try {
      final envelope = hydroObject(jsonDecode(raw));
      final body = hydroObject(envelope['body']);
      hydroRequire(
        envelope['sha256'] ==
            sha256.convert(utf8.encode(canonicalHydroJson(body))).toString(),
        'CORRUPT_DOCUMENT',
        'Checksum no coincide.',
      );
      return body;
    } catch (e) {
      if (e is HydrostaticException) rethrow;
      throw const HydrostaticException(
        'CORRUPT_DOCUMENT',
        'Registro ilegible; no se elimina.',
      );
    }
  }

  Future<void> write(
    Box<String> box,
    String key,
    HydroJson value,
    String boundary,
  ) async {
    await fault?.call('before:$boundary');
    final raw = canonicalHydroJson(value);
    await box.put(
      key,
      jsonEncode({
        'body': value,
        'sha256': sha256.convert(utf8.encode(raw)).toString(),
      }),
    );
    await box.flush();
    await fault?.call('after:$boundary');
    if (box == documents) _changes.add(null);
  }

  Future<void> remove(Box<String> box, String key, String boundary) async {
    await fault?.call('before:$boundary');
    await box.delete(key);
    await box.flush();
    await fault?.call('after:$boundary');
  }

  HydrostaticTest? test(String id) {
    final row = read(documents, 'test:$id');
    return row == null ? null : HydrostaticTest.fromJson(row);
  }

  List<HydrostaticTest> all() => documents.keys
      .where((k) => '$k'.startsWith('test:'))
      .map((k) => HydrostaticTest.fromJson(read(documents, '$k')!))
      .toList();
  Future<void> close() async {
    await _tail;
    await _changes.close();
    await documents.close();
    await journal.close();
    await metadata.close();
  }
}

class HydrostaticOperationJournal {
  HydrostaticOperationJournal(this.store);
  final HydrostaticStore store;
  HydroJson? get(String operationId) =>
      store.read(store.journal, 'op:$operationId');
  List<HydroJson> get entries => store.journal.keys
      .where((k) => '$k'.startsWith('op:'))
      .map((k) => store.read(store.journal, '$k')!)
      .toList();
  Future<void> save(HydroJson entry, String boundary) =>
      store.write(store.journal, 'op:${entry['operationId']}', entry, boundary);
}

class HydrostaticSequenceStore {
  HydrostaticSequenceStore(this.store);
  final HydrostaticStore store;
  int last(String uid) =>
      store.read(store.metadata, 'sequence:$uid')?['last'] as int? ?? 0;
  Future<void> reserve(String uid, int number) async {
    final previous = last(uid);
    hydroRequire(
      number <= previous + 1,
      'SEQUENCE_CONFLICT',
      'Reserva no consecutiva.',
    );
    await store.write(store.metadata, 'sequence:$uid', {
      'uid': uid,
      'last': number > previous ? number : previous,
    }, 'sequence');
  }
}

class HydrostaticDeleteReceipt {
  const HydrostaticDeleteReceipt({
    required this.testId,
    required this.operationId,
    required this.actorId,
    required this.state,
    required this.uid,
    required this.number,
  });
  final String testId, operationId, actorId, uid;
  final int? number;
  final HydrostaticDeletionState state;
  HydroJson toJson() => {
    'testId': testId,
    'operationId': operationId,
    'actorId': actorId,
    'uid': uid,
    'number': number,
    'state': hydroWire(state),
  };
  factory HydrostaticDeleteReceipt.fromJson(HydroJson j) =>
      HydrostaticDeleteReceipt(
        testId: j['testId'],
        operationId: j['operationId'],
        actorId: j['actorId'],
        uid: j['uid'],
        number: j['number'],
        state: hydroEnum(HydrostaticDeletionState.values, j['state']),
      );
}
