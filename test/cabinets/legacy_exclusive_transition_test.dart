import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'cabinet_api_test.dart' show Adapter, response;
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_automatic_sync.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_cabinet_recovery.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_controller.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_legacy_scope.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'harness.dart';
import 'legacy_recovery_test.dart' show LegacyRemote;
import 'legacy_automatic_sync_test.dart' show seed;

class SessionChangesAtGrant extends CabinetController {
  SessionChangesAtGrant(Harness h, LegacyRemote remote)
    : super(
        app: h.app,
        store: h.store,
        remote: remote,
        camera: h.controller.camera,
      );
  @override
  Future<Object> beginLegacySupport(
    String id, {
    Duration waitTimeout = const Duration(seconds: 8),
  }) async {
    final token = await super.beginLegacySupport(id, waitTimeout: waitTimeout);
    app.session =
        testSession(); // Same actor, genuinely different session at async grant.
    return token;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late LegacyRemote remote;
  late String id;
  setUp(() async {
    h = Harness();
    remote = LegacyRemote();
    await h.open(remote: remote);
    h.app.online = true;
    id = await seed(h, remote, legacyAutomaticUids.first, 1);
    remote.selectedId = id;
  });
  tearDown(() async {
    await h.close();
  });
  test(
    'batch grant is bound to its original session before first preparation',
    () async {
      final before = jsonEncode(h.store.read(id)!.json);
      final b = LegacyAutomaticSync(
        h.controller,
        executor: (selected, permit) async {
          h.app.session =
              testSession(); // Same user, new session between dispatch and prepare.
          final r = LegacyCabinetRecovery(
            h.controller,
            selected,
            cabinetAllowlist: {selected},
            automaticBatchPermit: permit,
          );
          try {
            await r.prepare(prepareDerivatives: true);
            return false;
          } finally {
            await r.close();
          }
        },
      );
      await b.runFromHome(() async {});
      expect(b.result!['globalCode'], 'SUPPORT_SESSION_CHANGED');
      expect(
        objects(
          b.result!['rows'],
        ).where((r) => r['status'] == 'not_processed').length,
        9,
      );
      expect(remote.traces, isEmpty);
      expect(remote.calls, isEmpty);
      expect(jsonEncode(h.store.read(id)!.json), before);
      expect(h.controller.supportHeld, isFalse);
    },
  );
  test(
    'field-shaped first UID failure preserves one blocked and nine unprocessed without unlocking owner',
    () async {
      final owner = await h.controller.beginLegacySupport(id);
      final b = LegacyAutomaticSync(h.controller);
      await b.runFromHome(() async {});
      final rows = objects(b.result!['rows']);
      expect(rows.first['uid'], 'AQ26000076');
      expect(rows.first['code'], 'SUPPORT_LOCK_OWNED');
      expect(rows.where((r) => r['status'] == 'blocked').length, 1);
      expect(rows.where((r) => r['status'] == 'not_processed').length, 9);
      expect(b.result!['globalCode'], 'SUPPORT_LOCK_OWNED');
      expect(h.controller.ownsLegacySupport(owner), isTrue);
      expect(remote.calls, isEmpty);
      expect(remote.uploads, isEmpty);
      expect(remote.traces, isEmpty);
      await h.controller.endLegacySupport(owner);
    },
  );
  test(
    'RC14 aggregation loses exact causes: RC15 preserves actual support code',
    () {
      for (final code in [
        'SUPPORT_CONTROLLER_BUSY',
        'SUPPORT_HTTP_IN_FLIGHT',
        'SUPPORT_MEDIA_BUSY',
        'SUPPORT_LOCK_OWNED',
        'SUPPORT_SESSION_CHANGED',
        'AUTO_BATCH_PERMIT_REQUIRED',
        'SUPPORT_ROLE_DENIED',
      ]) {
        final issue = LegacyAutomaticSync.classify(
          StateError('$code: synthetic private text'),
        );
        expect(issue.code, code);
        expect(issue.global, isTrue);
        expect(issue.message, isNot(contains('private text')));
      }
      expect(
        LegacyAutomaticSync.classify(
          StateError('SUPPORT_ACTOR_MISMATCH'),
        ).global,
        isFalse,
      );
      expect(
        LegacyAutomaticSync.classify(Exception('private payload')).code,
        'UNEXPECTED_EXCEPTION',
      );
    },
  );
  test(
    'reservation rejected before first UID has complete durable summary and does not unlock owner',
    () async {
      final owner = h.controller.beginAutomaticHistoricalBatch();
      var called = false;
      final b = LegacyAutomaticSync(
        h.controller,
        executor: (id, p) async {
          called = true;
          return false;
        },
      );
      await b.runFromHome(() async {
        called = true;
      });
      expect(called, isFalse);
      expect(b.result!['globalCode'], 'AUTO_BATCH_LOCK_OWNED');
      expect(objects(b.result!['rows']).length, 10);
      expect(b.summary, contains('Recuperación histórica no iniciada'));
      expect(b.summary, contains('Gabinetes pendientes: 10'));
      expect(h.controller.ownsAutomaticHistoricalBatch(owner), isTrue);
      h.controller.endAutomaticHistoricalBatch(owner);
      final reloaded = LegacyAutomaticSync(h.controller);
      expect(reloaded.result, b.result);
      expect(reloaded.hasVisibleResult, isTrue);
      h.setRole(ConstructionRole.contractor);
      expect(
        reloaded.hasVisibleResult,
        isTrue,
      ); // Same owner may read without transmission rights.
      expect(LegacyAutomaticSync(h.controller).hasVisibleResult, isTrue);
      expect(remote.calls, isEmpty);
    },
  );
  test(
    'normal sync still active after callback must drain before historical lease',
    () async {
      final entered = Completer<void>();
      var executed = 0;
      final b = LegacyAutomaticSync(
        h.controller,
        executor: (id, p) async {
          expect(h.app.syncing, isFalse);
          final lease = await h.controller.beginLegacySupport(id);
          expect(h.controller.ownsLegacySupport(lease), isTrue);
          await h.controller.endLegacySupport(lease);
          executed++;
          return false;
        },
      );
      final run = b.runFromHome(() async {
        await h.controller.synchronize(force: true);
        h.app.syncing = true;
        entered.complete();
      });
      await entered.future;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(executed, 0);
      expect(h.app.syncing, isTrue);
      h.app.syncing = false;
      await run;
      expect(executed, 1);
      expect(b.result!['status'], 'partial');
      expect(remote.calls, isEmpty);
    },
  );
  test(
    'normal sync timeout preserves activity and persistent reason without first UID',
    () async {
      final b = LegacyAutomaticSync(
        h.controller,
        ordinaryWaitTimeout: const Duration(milliseconds: 40),
      );
      await b.runFromHome(() async {
        h.app.syncing = true;
      });
      expect(h.app.syncing, isTrue);
      expect(b.result!['globalCode'], 'SUPPORT_ORDINARY_BUSY');
      expect(b.summary, contains('Recuperación histórica no iniciada'));
      h.app.syncing = false;
    },
  );
  test('transient controller work drains before acquiring support', () async {
    h.controller.syncing = true;
    final future = h.controller.beginLegacySupport(id);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(h.controller.supportHeld, isFalse);
    h.controller.syncing = false;
    final lease = await future;
    expect(h.controller.ownsLegacySupport(lease), isTrue);
    await h.controller.endLegacySupport(lease);
  });
  test(
    'another broker snapshot is diagnosed without releasing its owner',
    () async {
      final owner = Object();
      h.controller.camera.broker.holdForSnapshot(owner);
      await expectLater(
        h.controller.beginLegacySupport(id),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'code',
            contains('SUPPORT_MEDIA_LOCK_OWNED'),
          ),
        ),
      );
      expect(h.controller.camera.broker.snapshotHeld, isTrue);
      h.controller.camera.broker.releaseSnapshot(owner);
    },
  );
  test('another HTTP lease is diagnosed without releasing its owner', () async {
    final owner = h.client.beginCabinetRecovery(cabinetIds: {id});
    await expectLater(
      h.controller.beginLegacySupport(id),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'code',
          contains('SUPPORT_HTTP_LOCK_OWNED'),
        ),
      ),
    );
    expect(h.client.cabinetRecoveryHeld, isTrue);
    h.client.endCabinetRecovery(owner);
  });
  test(
    'real ordinary command finishes before first historical preparation and execution',
    () async {
      h.app.online = false;
      remote.allowOrdinaryOther = true;
      await h.controller.scan('AQ26000017', 'A1', false);
      h.app.online = true;
      final entered = Completer<void>(), finish = Completer<void>();
      remote.beforeCommand = () async {
        entered.complete();
        await finish.future;
        remote.beforeCommand = null;
      };
      var started = false;
      final b = LegacyAutomaticSync(
        h.controller,
        executor: (selected, permit) async {
          expect(h.controller.syncing, isFalse);
          started = true;
          final r = LegacyCabinetRecovery(
            h.controller,
            selected,
            cabinetAllowlist: {selected},
            automaticBatchPermit: permit,
            derivativeEncoder: (s, t, w, height, q) async {
              await File(s).copy(t);
            },
          );
          try {
            await r.prepare(prepareDerivatives: true);
            expect(r.blockers, isEmpty);
            await r.execute(
              operationAllowlist: r.operationAllowlist,
              explicitlyConfirmed: true,
            );
            expect(r.completed, isTrue);
            return false;
          } finally {
            await r.close();
          }
        },
      );
      final run = b.runFromHome(() async {
        await h.controller.synchronize(force: true);
      });
      await entered.future;
      expect(started, isFalse);
      expect(h.controller.syncing, isTrue);
      finish.complete();
      await run;
      expect(started, isTrue);
      expect(remote.documents[id]!['status'], 'validated');
      expect(objects(b.result!['rows']).first['status'], 'recovered');
    },
  );
  test('in-flight HTTP drains naturally before support acquisition', () async {
    final entered = Completer<void>(), finish = Completer<void>();
    h.client.dio.httpClientAdapter = Adapter((request) async {
      entered.complete();
      await finish.future;
      return response(200, {});
    });
    final request = h.client.dio.get('/construction/cabinets/$id');
    await entered.future;
    final acquiring = h.controller.beginLegacySupport(id);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(h.client.cabinetRequestsInFlight, isTrue);
    expect(h.controller.supportHeld, isFalse);
    finish.complete();
    await request;
    final lease = await acquiring;
    expect(h.controller.ownsLegacySupport(lease), isTrue);
    await h.controller.endLegacySupport(lease);
  });
  test(
    'session changed exactly at async lease grant is not silently adopted',
    () async {
      final old = h.controller;
      h.controller = SessionChangesAtGrant(h, remote);
      old.dispose();
      final permit = h.controller.beginAutomaticHistoricalBatch();
      final r = LegacyCabinetRecovery(
        h.controller,
        id,
        cabinetAllowlist: {id},
        automaticBatchPermit: permit,
      );
      final before = jsonEncode(h.store.read(id)!.json);
      await expectLater(
        r.prepare(prepareDerivatives: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'code',
            'SUPPORT_SESSION_CHANGED',
          ),
        ),
      );
      await r.close();
      h.controller.endAutomaticHistoricalBatch(permit);
      expect(jsonEncode(h.store.read(id)!.json), before);
      expect(remote.calls, isEmpty);
      expect(remote.traces, isEmpty);
    },
  );
}
