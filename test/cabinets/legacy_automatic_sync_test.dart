import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/features/home/home_page.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_automatic_sync.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_legacy_scope.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_cabinet_recovery.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/recovery/cabinet_backup.dart'
    show fileHash;
import 'harness.dart';
import 'legacy_recovery_test.dart' show LegacyRemote;

Future<String> seed(
  Harness h,
  LegacyRemote remote,
  String uid,
  int index,
) async {
  final id = 'c0000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
  final pid = 'c1000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
  String oid(int n) =>
      'c2000000-0000-4000-8000-${(index * 100 + n).toString().padLeft(12, '0')}';
  final root = await h.directory.resolveSymbolicLinks();
  final dir = Directory('$root/cabinets/$id/evidence');
  await dir.create(recursive: true);
  for (final suffix in ['source', 'upload', 'thumb']) {
    await File('${dir.path}/$pid.$suffix.jpg').writeAsBytes(
      await File('test/cabinets/fixtures/evidence.jpg').readAsBytes(),
    );
  }
  final upload = '${dir.path}/$pid.upload.jpg';
  final defs = fixtureCatalog().parts('A1', false);
  final parts = defs
      .map(
        (d) => <String, dynamic>{
          'code': d['code'],
          'present': true,
          if (d['serial'] == 'required') 'serial': 'TEST-001',
          'evidence': <Json>[],
        },
      )
      .toList();
  final server = <String, dynamic>{
    'cabinetId': id,
    'uid': uid,
    'model': 'A1',
    'automated': false,
    'version': 1,
    'catalogVersion': fixtureCatalog().version,
    'status': 'draft',
    'partDefinitions': defs,
    'parts': <Json>[],
  };
  remote.documents[id] = clone(server);
  final register = {
    'operationId': oid(0),
    'expectedVersion': 0,
    'type': 'register',
    'uid': uid,
  };
  remote.receipts[oid(0)] = {'cabinet': clone(server)};
  final original = <String, dynamic>{
    'id': id,
    'actor': h.controller.actor,
    'server': clone(server),
    'working': {
      ...clone(server),
      'status': 'validated',
      'partsValidated': true,
      'parts': parts,
    },
    'dirty': true,
    'photos': [
      {
        'id': pid,
        'actor': h.controller.actor,
        'localPath': upload,
        'thumbnailPath': '${dir.path}/$pid.thumb.jpg',
        'verified': false,
        'metadata': {
          'photoId': pid,
          'context': 'registration',
          'clientSha256': await fileHash(File(upload)),
          'capturedAt': '2026-10-06T12:00:00.000Z',
          'latitude': 20,
          'longitude': -103,
          'accuracy': 5,
        },
      },
    ],
    'operations': [
      {
        'actor': h.controller.actor,
        'state': 'done',
        'body': register,
        'result': clone(remote.receipts[oid(0)]!),
      },
      for (var n = 1; n <= 3; n++)
        {
          'actor': h.controller.actor,
          'state': 'queued',
          'error': 'historical error retained',
          'body': {
            'operationId': oid(n),
            'expectedVersion': n,
            'capturedAt': '2026-10-06T12:00:00.000Z',
            'type': [
              'registration_close',
              'parts_save',
              'parts_validate',
            ][n - 1],
            if (n == 1)
              'evidence': [
                {'photoId': pid, 'confirmed': true},
              ],
            if (n == 2) 'parts': parts,
          },
        },
    ],
  };
  await h.store.save(original);

  return id;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late LegacyRemote remote;
  late List<String> ids;
  setUp(() async {
    remote = LegacyRemote();
    h = Harness();
    await h.open(remote: remote);
    h.app.online = true;
    ids = [];
    var index = 1;
    for (final uid in legacyAutomaticUids) {
      ids.add(await seed(h, remote, uid, index++));
    }
  });
  tearDown(() async {
    await h.close();
  });
  Future<bool> recover(String id, Object permit) async {
    remote.selectedId = id;
    final r = LegacyCabinetRecovery(
      h.controller,
      id,
      cabinetAllowlist: {id},
      automaticBatchPermit: permit,
      derivativeEncoder: (source, target, w, height, q) async {
        await File(source).copy(target);
      },
    );
    try {
      await r.prepare(prepareDerivatives: true);
      expect(r.blockers, isEmpty, reason: '$id ${r.blockers}');
      expect(r.canExecute, isTrue);
      final already = r.confirmedVersions.length == r.sequence.length;
      await r.execute(
        operationAllowlist: r.operationAllowlist,
        explicitlyConfirmed: true,
      );
      expect(r.completed, isTrue);
      return already;
    } finally {
      await r.close();
    }
  }

  test(
    'ten real recoveries, variable sequence v4, preserved bodies, resume without uploads or commands',
    () async {
      final before = {
        for (final id in ids)
          id: jsonEncode(
            h.store.read(id)!.operations.map((o) => o['body']).toList(),
          ),
      };
      final batch = LegacyAutomaticSync(h.controller, executor: recover);
      await batch.runFromHome(() async {});
      expect(
        batch.result?['status'],
        'complete',
        reason: jsonEncode(batch.result),
      );
      expect(remote.calls.length, 30);
      expect(remote.uploads.length, 10);
      for (final id in ids) {
        expect(remote.documents[id]!['status'], 'validated');
        expect(remote.documents[id]!['version'], 4);
        expect(
          jsonEncode(
            h.store.read(id)!.operations.map((o) => o['body']).toList(),
          ),
          before[id],
        );
      }
      await batch.runFromHome(() async {});
      expect(
        batch.result?['status'],
        'complete',
        reason: jsonEncode(batch.result),
      );
      expect(
        objects(
          batch.result!['rows'],
        ).every((r) => r['status'] == 'already_complete'),
        isTrue,
      );
      expect(remote.calls.length, 30);
      expect(remote.uploads.values.every((v) => v == 1), isTrue);
    },
  );
  test(
    'five individual failures do not block five successors; no records deleted',
    () async {
      var count = 0;
      final batch = LegacyAutomaticSync(
        h.controller,
        executor: (id, permit) async {
          if (count++ % 2 == 0) throw StateError('LEGACY_CHECKLIST_INVALID');
          return recover(id, permit);
        },
      );
      await batch.runFromHome(() async {});
      expect(batch.result!['status'], 'partial');
      expect(
        objects(
          batch.result!['rows'],
        ).where((r) => r['status'] == 'recovered').length,
        5,
      );
      expect(h.store.all().length, 10);
      expect(remote.calls.length, 15);
    },
  );
  test('shared outage stops batch and persists resumable history', () async {
    var calls = 0;
    final batch = LegacyAutomaticSync(
      h.controller,
      executor: (id, permit) async {
        calls++;
        throw failure(503, 'TEST');
      },
    );
    await batch.runFromHome(() async {});
    expect(calls, 1);
    expect(batch.result!['status'], 'stopped');
    expect(
      objects(
        batch.result!['rows'],
      ).where((r) => r['status'] == 'not_processed').length,
      9,
    );
    final restarted = LegacyAutomaticSync(h.controller);
    expect(restarted.result!['status'], 'stopped');
    expect(remote.calls, isEmpty);
  });
  test(
    'double click is single flight and changing session stops before execution',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      var ordinary = 0, calls = 0;
      final batch = LegacyAutomaticSync(
        h.controller,
        executor: (id, permit) async {
          calls++;
          return false;
        },
      );
      final first = batch.runFromHome(() async {
        ordinary++;
        entered.complete();
        await release.future;
      });
      await entered.future;
      await batch.runFromHome(() async {
        ordinary++;
      });
      h.app.session = testSession();
      release.complete();
      await first;
      expect(ordinary, 1);
      expect(calls, 0);
      expect(batch.result!['globalCode'], 'SESSION_CHANGED');
      expect(batch.busy, isFalse);
    },
  );
  test(
    'exact allowlist, pilot and outside records are never selected',
    () async {
      final pilot = await seed(h, remote, legacyPilotUid, 80);
      final other = await seed(h, remote, 'AQ26000017', 81);
      final before = {
        pilot: jsonEncode(h.store.read(pilot)!.json),
        other: jsonEncode(h.store.read(other)!.json),
      };
      final selected = <String>[];
      final batch = LegacyAutomaticSync(
        h.controller,
        executor: (id, permit) async {
          selected.add(id);
          return true;
        },
      );
      await batch.runFromHome(() async {});
      expect(selected, ids);
      for (final id in before.keys) {
        expect(jsonEncode(h.store.read(id)!.json), before[id]);
      }
      expect(legacyAutomaticUids.length, 10);
      expect(legacyAutomaticUids.contains(legacyPilotUid), isFalse);
    },
  );

  test(
    'variable split checklist, historical 413, existing photo and replayed receipts',
    () async {
      final record = clone(h.store.read(ids.first)!.json);
      final ops = objects(record['operations']);
      ops[1]['state'] = 'conflict';
      ops[1]['diagnostic'] = {
        'httpStatus': 413,
        'path': '/construction/cabinets/${ids.first}/photos',
      };
      final all = objects(object(ops[2]['body'])['parts']);
      final second = clone(ops[2]);
      second['body'] = {
        ...object(second['body']),
        'operationId': 'd0000000-0000-4000-8000-000000000001',
        'expectedVersion': 3,
        'parts': all.sublist(all.length ~/ 2),
      };
      object(ops[2]['body'])['parts'] = all.sublist(0, all.length ~/ 2);
      ops[2]['body'] = {
        ...object(ops[2]['body']),
        'parts': all.sublist(0, all.length ~/ 2),
      };
      ops[3]['body'] = {...object(ops[3]['body']), 'expectedVersion': 4};
      ops.insert(3, second);
      record['operations'] = ops;
      await h.store.save(record);
      final photo = objects(record['photos']).single;
      await remote.upload(ids.first, photo);
      remote.uploads.clear();
      remote.wireReceiptFlags = true;
      final permit = h.controller.beginAutomaticHistoricalBatch();
      try {
        await recover(ids.first, permit);
      } finally {
        h.controller.endAutomaticHistoricalBatch(permit);
      }
      expect(remote.documents[ids.first]!['version'], 5);
      expect(remote.calls.map((b) => b['type']), [
        'registration_close',
        'parts_save',
        'parts_save',
        'parts_validate',
      ]);
      expect(remote.uploads, isEmpty);
      expect(
        object(
          h.store.read(ids.first)!.operations[1]['diagnostic'],
        )['httpStatus'],
        413,
      );
    },
  );

  for (final scenario in [
    'missing photo',
    'hash mismatch',
    'missing command',
    'missing capture',
    'duplicate capture',
    'wrong actor',
    'version gap',
    'real conflict',
    'ambiguous receipt',
  ]) {
    test(
      'preparation blocks $scenario without commands or destructive edits',
      () async {
        final id = ids.first, record = clone(h.store.read(ids.first)!.json);
        final ops = objects(record['operations']);
        switch (scenario) {
          case 'missing photo':
            await File(objects(record['photos']).single['localPath']).delete();
          case 'hash mismatch':
            await File(
              objects(record['photos']).single['localPath'],
            ).writeAsBytes([0, 1]);
          case 'missing command':
            ops.removeLast();
            record['operations'] = ops;
          case 'missing capture':
            final body = object(ops[2]['body']);
            body['parts'] = objects(body['parts']).sublist(1);
            ops[2]['body'] = body;
            record['operations'] = ops;
          case 'duplicate capture':
            final body = object(ops[2]['body']);
            body['parts'] = [
              ...objects(body['parts']),
              objects(body['parts']).first,
            ];
            ops[2]['body'] = body;
            record['operations'] = ops;
          case 'wrong actor':
            record['actor'] = '11111111-2222-4333-8444-555555555555';
          case 'version gap':
            remote.documents[id]!['version'] = 2;
            remote.documents[id]!['status'] = 'registered';
          case 'real conflict':
            ops[1]['state'] = 'conflict';
            ops[1]['diagnostic'] = {'httpStatus': 409, 'path': '/commands'};
            record['operations'] = ops;
          case 'ambiguous receipt':
            remote.genericReceipt404 = true;
        }
        await h.store.save(record);
        final before = jsonEncode(h.store.read(id)!.json);
        remote.selectedId = id;
        final permit = h.controller.beginAutomaticHistoricalBatch();
        final r = LegacyCabinetRecovery(
          h.controller,
          id,
          cabinetAllowlist: {id},
          automaticBatchPermit: permit,
          derivativeEncoder: (s, t, w, height, q) async {
            await File(s).copy(t);
          },
        );
        Object? error;
        try {
          await r.prepare(prepareDerivatives: true);
        } catch (e) {
          error = e;
        }
        expect(
          error != null || r.blockers.isNotEmpty,
          isTrue,
          reason: scenario,
        );
        expect(r.canExecute, isFalse);
        await r.close();
        h.controller.endAutomaticHistoricalBatch(permit);
        expect(remote.calls, isEmpty);
        expect(remote.uploads, isEmpty);
        expect(jsonEncode(h.store.read(id)!.json), before);
      },
    );
  }
  test(
    'lost command response stops globally; subsequent click reads receipt without duplicate',
    () async {
      remote.loseOperation = 'c2000000-0000-4000-8000-000000000101';
      final batch = LegacyAutomaticSync(h.controller, executor: recover);
      await batch.runFromHome(() async {});
      expect(batch.result!['status'], 'stopped');
      expect(remote.calls.length, 1);
      await batch.runFromHome(() async {});
      expect(
        batch.result!['status'],
        'complete',
        reason: jsonEncode(batch.result),
      );
      expect(remote.calls.length, 30);
      expect(remote.uploads.values.every((v) => v == 1), isTrue);
    },
  );
  test(
    'ordinary sync skips protected historical records before batch',
    () async {
      final batch = LegacyAutomaticSync(h.controller, executor: recover);
      await batch.runFromHome(() async {
        await h.controller.synchronize(force: true);
        expect(remote.calls, isEmpty);
        expect(remote.uploads, isEmpty);
      });
      expect(
        batch.result!['status'],
        'complete',
        reason: jsonEncode(batch.result),
      );
    },
  );
  for (final connected in [true, false]) {
    testWidgets(
      'home retries ordinary sync with connection=$connected without historical recovery',
      (tester) async {
        h.app.online = false;
        final batch = LegacyAutomaticSync.forController(h.controller);
        final before = {
          for (final id in ids) id: jsonEncode(h.store.read(id)!.json),
        };
        final requests = <RequestOptions>[];
        h.client.dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests.add(options);
              if (connected) {
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {'items': [], 'total': 0},
                  ),
                );
              } else {
                handler.reject(
                  DioException(
                    requestOptions: options,
                    type: DioExceptionType.connectionError,
                    message: 'Simulated offline connection',
                  ),
                );
              }
            },
          ),
        );
        try {
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider.value(value: h.app),
                ChangeNotifierProvider.value(value: h.controller),
              ],
              child: const MaterialApp(home: HomePage()),
            ),
          );
          expect(batch.result, isNull);
          final sync = find.byTooltip('Intentar sincronizar');
          await tester.scrollUntilVisible(sync, 300);
          expect(requests, isEmpty);
          final button = tester.widget<IconButton>(
            find.ancestor(of: sync, matching: find.byType(IconButton)),
          );
          await tester.runAsync(() async {
            // Await the button's async handler through both ordinary syncs,
            // including Hive writes, before disposing either controller.
            await (button.onPressed! as Future<void> Function())();
            // Reconnecting refreshes cabinets and can start another ordinary
            // sync. Drain that background work before closing the Hive store.
            final deadline = Stopwatch()..start();
            do {
              await Future<void>.delayed(const Duration(milliseconds: 10));
              if (deadline.elapsed > const Duration(seconds: 10)) {
                fail('Ordinary synchronization did not finish');
              }
            } while (h.app.syncing ||
                h.controller.refreshing ||
                h.controller.syncing);
          });
          await tester.pumpAndSettle();
          expect(requests, hasLength(1));
          expect(requests.single.method, 'GET');
          expect(requests.single.path, endsWith('/resident/base-surveys'));
          expect(h.app.online, connected);
          expect(h.app.syncing, isFalse);
          expect(h.controller.syncing, isFalse);
          expect(batch.busy, isFalse);
          expect(batch.result, isNull);
          expect(remote.calls, isEmpty);
          expect(remote.uploads, isEmpty);
          for (final id in ids) {
            expect(jsonEncode(h.store.read(id)!.json), before[id]);
          }
          expect(
            find.text(connected ? 'Información pendiente' : 'Sin conexión'),
            findsOneWidget,
          );
          expect(find.textContaining('Históricos procesados:'), findsNothing);
        } finally {
          await tester.pumpWidget(const SizedBox());
        }
      },
    );
  }
  test(
    'default engine blocks incomplete originals without uploading and preserves all ten',
    () async {
      for (final id in ids) {
        final r = clone(h.store.read(id)!.json);
        r['operations'] = objects(r['operations']).sublist(0, 2);
        await h.store.save(r);
      }
      final batch = LegacyAutomaticSync(h.controller);
      await batch.runFromHome(() async {});
      expect(
        batch.result!['status'],
        'partial',
        reason: jsonEncode(batch.result),
      );
      expect(
        objects(
          batch.result!['rows'],
        ).where((r) => r['status'] == 'blocked').length,
        10,
      );
      expect(remote.calls, isEmpty);
      expect(remote.uploads, isEmpty);
      expect(h.store.all().length, 10);
    },
  );
  test('RC14 keeps completed pilot quarantined from ordinary writer', () async {
    final id = await seed(h, remote, legacyPilotUid, 90);
    final r = clone(h.store.read(id)!.json);
    r['legacyRecoveryCompleted'] = true;
    await h.store.save(r);
    expect(legacyProtected(h.store.read(id)!), legacyAutomaticEnabled);
  });
  test(
    'one previously recovered and nine pending use their individual causal versions',
    () async {
      final permit = h.controller.beginAutomaticHistoricalBatch();
      try {
        await recover(ids.first, permit);
      } finally {
        h.controller.endAutomaticHistoricalBatch(permit);
      }
      final batch = LegacyAutomaticSync(h.controller, executor: recover);
      await batch.runFromHome(() async {});
      expect(batch.result!['status'], 'complete');
      final rows = objects(batch.result!['rows']);
      expect(rows.where((r) => r['status'] == 'already_complete').length, 1);
      expect(rows.where((r) => r['status'] == 'recovered').length, 9);
      expect(remote.calls.length, 30);
    },
  );
  test(
    'already received historical bytes are retained even when new derivative hash differs',
    () async {
      final id = ids.first, photo = h.store.read(ids.first)!.photos.single;
      remote.selectedId = id;
      final permit = h.controller.beginAutomaticHistoricalBatch();
      LegacyCabinetRecovery create() => LegacyCabinetRecovery(
        h.controller,
        id,
        cabinetAllowlist: {id},
        automaticBatchPermit: permit,
        derivativeEncoder: (source, target, w, height, q) async {
          await File(
            target,
          ).writeAsBytes([...await File(source).readAsBytes(), 0]);
        },
      );
      var r = create();
      try {
        await r.prepare(prepareDerivatives: true);
        expect(r.blockers, isEmpty);
        expect(
          r.derivatives.values.single.manifest['transportSha256'],
          isNot(object(photo['metadata'])['clientSha256']),
        );
        await r.close();
        await remote.upload(id, photo);
        remote.uploads.clear();
        r = create();
        await r.prepare(prepareDerivatives: true);
        expect(r.blockers, isEmpty);
        expect(
          r.derivatives,
          isEmpty,
        ); // Existing original upload needs no new bytes.
        await r.execute(
          operationAllowlist: r.operationAllowlist,
          explicitlyConfirmed: true,
        );
        expect(r.completed, isTrue);
        expect(remote.uploads, isEmpty);
        expect(
          remote.photoRows[photo['id']]!['client_sha256'],
          object(photo['metadata'])['clientSha256'],
        );
      } finally {
        await r.close();
        h.controller.endAutomaticHistoricalBatch(permit);
      }
    },
  );
  for (final status in [401, 403, 408, 429, 503]) {
    test('HTTP $status is global, not ten attempts', () {
      expect(
        LegacyAutomaticSync.classify(failure(status, 'TEST')).global,
        isTrue,
      );
    });
  }
  for (final status in [409, 413, 422]) {
    test('HTTP $status is isolated', () {
      expect(
        LegacyAutomaticSync.classify(failure(status, 'TEST')).global,
        isFalse,
      );
    });
  }
}
