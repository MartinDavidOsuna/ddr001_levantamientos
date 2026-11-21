import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'harness.dart';

String syntheticUid(int n) {
  for (var digit = 0; digit < 10; digit++) {
    try {
      return cabinetUid('AQ26${(n + 1000).toString().padLeft(5, '0')}$digit');
    } on FormatException {
      /* check digit is validated by the real parser */
    }
  }
  throw StateError('Invalid synthetic UID');
}

class InventoryRemote extends FakeCabinetRemote {
  String? failedId;
  bool receiptUnavailable = false;
  Completer<void>? gate;
  final requested = <String>[];
  @override
  Future<Json> get(String path, [Json? query]) async {
    requested.add(path);
    if (receiptUnavailable && path.contains('/operations/')) {
      throw failure(404, 'ROUTE_NOT_FOUND');
    }
    if (path == '') {
      return {
        'total': documents.length,
        'items': documents.keys
            .skip(((query?['page'] as int? ?? 1) - 1) * 100)
            .take(100)
            .map(
              (id) => {'cabinet_id': id, 'created_at': '2026-11-01T00:00:00Z'},
            )
            .toList(),
      };
    }
    if (path == '/$failedId') throw failure(503, 'TEMPORARY_FAILURE');
    if (path == '/resolve') {
      final c = documents.values
          .where((c) => c['uid'] == query!['uid'])
          .firstOrNull;
      if (c == null) throw failure(404, 'CABINET_NOT_FOUND');
      return {'cabinet': clone(c)};
    }
    final result = await super.get(path, query);
    if (path != '' && path != '/catalog' && gate != null) await gate!.future;
    return clone(result);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late InventoryRemote remote;
  setUp(() async {
    h = Harness();
    remote = InventoryRemote();
    await h.open(remote: remote);
    for (var n = 1; n <= 19; n++) {
      final id = '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
      remote.documents[id] = {
        'cabinetId': id,
        'uid': syntheticUid(n),
        'model': 'A1',
        'automated': false,
        'version': 1,
        'status': 'draft',
        'catalogVersion': fixtureCatalog().version,
        'parts': <Json>[],
        'registrationEvidence': <Json>[],
      };
    }
  });
  tearDown(() => h.close());

  for (final count in [14, 15, 19]) {
    test(
      '$count cached dossiers converge to common 19 without deleting local pending',
      () async {
        for (final id in remote.documents.keys.take(count)) {
          await h.controller.pull(id);
        }
        final local = await h.controller.scan(syntheticUid(25), 'A1', false);
        final before = clone(h.store.read(local)!.json);
        await h.controller.refresh();
        expect(h.controller.remoteTotal, 19);
        expect(h.controller.downloadedRemoteCount, 19);
        expect(h.controller.refreshComplete, isTrue);
        expect(h.controller.records.length, 20);
        expect(h.store.read(local)!.json, before);
        expect(remote.calls, isEmpty);
      },
    );
  }

  test(
    'partial refresh continues independent dossiers and retry clears only refresh error',
    () async {
      remote.failedId = remote.documents.keys.elementAt(1);
      await h.controller.refresh();
      expect(h.controller.records.length, 18);
      expect(h.controller.remoteTotal, 19);
      expect(h.controller.downloadedRemoteCount, 18);
      expect(h.controller.refreshComplete, isFalse);
      expect(h.controller.refreshIssues.keys, contains(remote.failedId));
      expect(h.controller.refreshError, contains('Descarga incompleta'));
      expect(
        h.controller.records.any((r) => r.id == remote.documents.keys.last),
        isTrue,
      );
      remote.failedId = null;
      await h.controller.refresh();
      expect(h.controller.refreshError, isNull);
      expect(h.controller.refreshComplete, isTrue);
      expect(h.controller.records.length, 19);
    },
  );

  test(
    'pull never regresses newer server snapshot or pending local work',
    () async {
      final id = remote.documents.keys.first;
      await h.controller.pull(id);
      var value = clone(h.store.read(id)!.json);
      value['server'] = {
        ...remote.documents[id]!,
        'version': 5,
        'status': 'validated',
      };
      value['working'] = {
        ...remote.documents[id]!,
        'version': 5,
        'status': 'incomplete',
      };
      value['dirty'] = true;
      value['operations'] = [
        {
          'state': 'conflict',
          'actor': h.controller.actor,
          'body': {'operationId': 'pending', 'type': 'parts_validate'},
        },
      ];
      value['photos'] = [
        {'id': 'sentinel', 'localPath': '/synthetic/preserved.jpg'},
      ];
      await h.store.save(value);
      await h.controller.pull(id);
      expect(h.store.read(id)!.json, value);
      remote.documents[id]!['version'] = 6;
      remote.documents[id]!['status'] = 'validated';
      await h.controller.pull(id);
      final after = h.store.read(id)!;
      expect(after.server['version'], 6);
      expect(after.working, value['working']);
      expect(after.pending, value['operations']);
      expect(after.photos, value['photos']);
      expect(after.synchronized, isFalse);
    },
  );

  test(
    'resolved draft retains server ID and does not create or validate',
    () async {
      h.app.online = true;
      final expected = remote.documents.keys.first;
      final id = await h.controller.findForInstallation(syntheticUid(1));
      expect(id, expected);
      expect(h.store.read(id!)!.server['status'], 'draft');
      expect(h.store.read(id)!.working['status'], 'draft');
      expect(h.store.read(id)!.pending, isEmpty);
      expect(remote.calls, isEmpty);
    },
  );

  test(
    'session change during pull does not apply old actor response',
    () async {
      remote.gate = Completer<void>();
      final id = remote.documents.keys.first;
      final work = h.controller.pull(id);
      await Future<void>.delayed(Duration.zero);
      h.app.session = testSession(user: '22222222-2222-4222-8222-222222222222');
      remote.gate!.complete();
      await work;
      expect(h.store.read(id), isNull);
    },
  );

  test(
    'lost registration receipt is recovered without rolling back newer remote validation',
    () async {
      final id = await h.controller.scan(syntheticUid(25), 'A1', false);
      remote.loseNextResponse = true;
      await h.controller.synchronize(force: true);
      expect(h.store.read(id)!.pending.single['state'], 'sending');
      expect(remote.calls.length, 1);
      remote.documents[id] = {
        ...remote.documents[id]!,
        'version': 5,
        'status': 'validated',
        'partsValidated': true,
      };
      await h.controller.pull(id);
      expect(h.store.read(id)!.working['status'], 'draft');
      await h.controller.synchronize(force: true);
      expect(
        remote.calls.length,
        1,
        reason: 'receipt must be retrieved before retransmission',
      );
      expect(h.store.read(id)!.pending, isEmpty);
      expect(h.store.read(id)!.server['version'], 5);
      expect(h.store.read(id)!.working['status'], 'validated');
      expect(
        object(
          h.store.read(id)!.operations.single['result'],
        )['cabinet']['version'],
        1,
      );
    },
  );

  test(
    'installation refreshes clean stale draft to same validated remote ID',
    () async {
      final id = remote.documents.keys.first;
      await h.controller.pull(id);
      remote.documents[id] = {
        ...remote.documents[id]!,
        'version': 2,
        'status': 'validated',
        'partsValidated': true,
      };
      h.app.online = true;
      expect(await h.controller.findForInstallation(syntheticUid(1)), id);
      expect(h.store.read(id)!.working['status'], 'validated');
      expect(h.controller.records.length, 1);
      expect(remote.calls, isEmpty);
    },
  );

  test(
    'pagination downloads all 105 dossiers without conflating first page and total',
    () async {
      final template = clone(remote.documents.values.first);
      for (var n = 20; n <= 105; n++) {
        final id = '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
        remote.documents[id] = {
          ...template,
          'cabinetId': id,
          'uid': syntheticUid(n),
        };
      }
      await h.controller.refresh();
      expect(h.controller.remoteTotal, 105);
      expect(h.controller.downloadedRemoteCount, 105);
      expect(h.controller.refreshComplete, isTrue);
      expect(remote.requested.where((path) => path == '').length, 2);
    },
  );

  test(
    'eleven reported UIDs normalize and validate without creating any record',
    () {
      for (final uid in [
        'AQ26-00006-8',
        'AQ26-00007-6',
        'AQ26-00009-2',
        'AQ26-00010-5',
        'AQ26-00012-1',
        'AQ26-00013-0',
        'AQ26-00014-8',
        'AQ26-00015-6',
        'AQ26-00016-4',
        'AQ26-00017-2',
        'AQ26-00018-9',
      ]) {
        expect(cabinetUid(uid), uid.replaceAll('-', ''));
        expect(
          cabinetUid(
            'https://id.aquafim.com/ddr001/${uid.replaceAll('-', '')}',
          ),
          cabinetUid(uid),
        );
      }
      expect(h.controller.records, isEmpty);
      expect(remote.calls, isEmpty);
    },
  );

  test(
    'unknown receipt 404 retains sending state and does not replay until receipt is recovered',
    () async {
      final id = await h.controller.scan(syntheticUid(25), 'A1', false);
      remote.loseNextResponse = true;
      await h.controller.synchronize(force: true);
      remote.receiptUnavailable = true;
      await h.controller.synchronize(force: true);
      expect(remote.calls.length, 1);
      expect(h.store.read(id)!.pending.single['state'], 'sending');
      expect(h.store.read(id)!.pending.single['error'], contains('recibo'));
      remote.receiptUnavailable = false;
      await h.controller.synchronize(force: true);
      expect(remote.calls.length, 1);
      expect(h.store.read(id)!.pending, isEmpty);
    },
  );

  test('clean-looking local draft is not server confirmation', () {
    final local = CabinetRecord({
      'id': 'local',
      'working': {'status': 'draft'},
      'operations': [],
      'photos': [],
    });
    expect(local.synchronized, isFalse);
    final received = CabinetRecord({
      'id': 'remote',
      'working': {'status': 'draft'},
      'server': {'status': 'draft', 'version': 1},
      'operations': [],
      'photos': [],
    });
    expect(received.synchronized, isTrue);
    final missingReceipt = CabinetRecord({
      ...received.json,
      'operations': [
        {
          'state': 'done',
          'body': {'type': 'parts_validate'},
        },
      ],
    });
    expect(missingReceipt.synchronized, isFalse);
  });
}
