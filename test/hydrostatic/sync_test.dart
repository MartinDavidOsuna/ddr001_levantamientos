import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync_api.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync_store.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'harness.dart';

class FakeHydroRemote implements HydrostaticSyncRemote {
  final receipts = <String, HydroJson>{};
  final requests = <HydroJson>[];
  final heads = <String, HydroJson>{};
  bool loseResponse = false, missingReceipt = false, corruptReceipt = false;
  String environment = 'TEST';
  int reads = 0, capabilitiesCalls = 0;
  HydrostaticSyncFailure? fail;
  final failuresById = <String, HydrostaticSyncFailure>{};
  Completer<void>? gate;
  void Function()? afterCommit;
  @override
  Future<HydroJson> capabilities(HydrostaticSyncIdentity s) async {
    capabilitiesCalls++;
    return {
      'contractVersion': 'hydrostatic-sync-v1',
      'available': true,
      'environment': environment,
      'commands': ['REGISTER_DOCUMENT', 'UPDATE_DOCUMENT', 'DECLARE_VIDEO'],
      'features': {'documentPersistence': true, 'durableReceipts': true},
    };
  }

  @override
  Future<HydroJson> command(
    String id,
    HydroJson c,
    HydrostaticSyncIdentity s,
  ) async {
    requests.add(jsonDecode(jsonEncode(c)));
    await gate?.future;
    if (fail != null) throw fail!;
    if (failuresById[id] != null) throw failuresById[id]!;
    final existing = receipts[c['operationId']];
    if (existing != null) return existing;
    final p = hydroObject(jsonDecode(c['payloadJson']));
    final d = hydroObject(p['document']);
    expect(hydroSyncHash(c['payloadJson']), c['payloadSha256']);
    expect(c['expectedVersion'], heads[id]?['serverVersion'] ?? 0);
    expect(p['baseSourceRevision'], heads[id]?['acceptedSourceRevision']);
    expect(p['baseSourceHash'], heads[id]?['acceptedSourceHash']);
    expect(d['syncState'], 'LOCAL_ONLY');
    final r = <String, dynamic>{
      'contractVersion': 'hydrostatic-sync-v1',
      'operationId': c['operationId'],
      'testId': id,
      'receiptState': 'COMMITTED',
      'documentStored': true,
      'serverVersion': c['expectedVersion'] + 1,
      'acceptedSourceRevision': d['revision'],
      'acceptedSourceHash': c['payloadSha256'],
      'committedAt': '2026-10-29T12:00:00.000Z',
      'validationState': 'PENDING_EVIDENCE',
      'requestSha256': hydroSyncHash(
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
      ),
      'mutationApplied': true,
    };
    receipts[c['operationId']] = r;
    heads[id] = r;
    afterCommit?.call();
    if (loseResponse) throw const HydrostaticSyncFailure(null, 'TIMEOUT');
    return corruptReceipt ? {...r, 'acceptedSourceHash': '0' * 64} : r;
  }

  @override
  Future<HydroJson> receipt(
    String id,
    String op,
    HydrostaticSyncIdentity s,
  ) async {
    reads++;
    if (missingReceipt || receipts[op] == null) {
      throw const HydrostaticSyncFailure(404, 'OPERATION_NOT_FOUND');
    }
    return receipts[op]!;
  }

  @override
  Future<HydroJson> status(
    String id,
    int revision,
    HydrostaticSyncIdentity s,
  ) async => {
    'serverVersion': 7,
    'acceptedSourceRevision': 99,
    'fullyReconciled': false,
  };
}

void main() {
  late Harness h;
  late HydrostaticSyncStore outbox;
  late FakeHydroRemote remote;
  late HydrostaticSync sync;
  bool online = true;
  HydrostaticSyncIdentity? identity() => h.access.authorized
      ? HydrostaticSyncIdentity(
          h.access.actor.userId,
          h.access.actor.sessionId,
          h.access.actor.deviceInstallationId,
        )
      : null;
  void createSync({bool enabled = true}) {
    sync = HydrostaticSync(
      repository: h.repo,
      store: outbox,
      remote: remote,
      identity: identity,
      verifySession: () async {},
      online: () => online,
      enabled: enabled,
      now: () => h.clock.utc,
      jitter: () => 0,
    );
  }

  setUp(() async {
    h = Harness();
    await h.open();
    online = true;
    outbox = await HydrostaticSyncStore.open(Directory('${h.root.path}/sync'));
    remote = FakeHydroRemote();
    createSync();
  });
  tearDown(() async {
    sync.dispose();
    await outbox.close();
    await h.close();
  });
  Future<void> reopen() async {
    sync.dispose();
    await outbox.close();
    await h.reopen();
    outbox = await HydrostaticSyncStore.open(Directory('${h.root.path}/sync'));
    createSync();
  }

  test('disabled never opens network or pins local deletion', () async {
    final id = await h.prepare();
    sync.dispose();
    createSync(enabled: false);
    await sync.run();
    expect(remote.capabilitiesCalls, 0);
    expect(outbox.read(id), null);
    expect(h.store.read(h.store.metadata, 'syncProtected:$id'), null);
  });
  test(
    'offline queue persists source and exact payload across reopen',
    () async {
      final id = await h.active();
      final before = canonicalHydroJson(h.repo.get(id)!.toJson());
      online = false;
      await sync.run();
      final c = outbox.read(id)!['active']['command'];
      expect(remote.requests, isEmpty);
      await reopen();
      expect(outbox.read(id)!['active']['command'], c);
      online = true;
      await sync.run();
      expect(remote.requests.single, c);
      expect(canonicalHydroJson(h.repo.get(id)!.toJson()), before);
      expect(
        sync.label(h.repo.get(id)!),
        contains('fotos e historial pendientes'),
      );
      expect(outbox.read(id)!['segments'], isNotEmpty);
    },
  );
  test(
    'lost response after COMMIT uses durable receipt without second POST',
    () async {
      final id = await h.passed();
      remote.loseResponse = true;
      await sync.run();
      expect(outbox.read(id)!['active']['state'], 'SENT_UNKNOWN');
      final old = outbox.read(id)!['active']['command'];
      await reopen();
      remote.loseResponse = false;
      await sync.run(manual: true);
      expect(remote.requests, hasLength(1));
      expect(remote.reads, 1);
      expect(outbox.read(id)!['receipts'].single['command'], old);
      expect(outbox.read(id)!['active'], null);
      for (final e in h.repo.get(id)!.evidence) {
        expect(await h.files.verify(e), true);
      }
    },
  );
  test(
    'lost response and receipt not found replays exactly same bytes',
    () async {
      final id = await h.prepare();
      remote.loseResponse = true;
      await sync.run();
      final first = remote.requests.single;
      remote.loseResponse = false;
      remote.missingReceipt = true;
      await sync.run(manual: true);
      expect(remote.requests, hasLength(2));
      expect(remote.requests.last, first);
      expect(outbox.read(id)!['active'], null);
      expect(remote.receipts, hasLength(1));
    },
  );
  test(
    'concurrent drains are single flight and preserve causal revisions',
    () async {
      final id = await h.active();
      remote.gate = Completer();
      final one = sync.run();
      final two = sync.run();
      expect(identical(one, two), true);
      while (remote.requests.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      h.clock.advance(1000);
      await h.repo.finish(id, uuid());
      remote.gate!.complete();
      await Future.wait([one, two]);
      expect(remote.requests, hasLength(2));
      expect(remote.requests.last['type'], 'UPDATE_DOCUMENT');
      expect(outbox.read(id)!['serverVersion'], 2);
      expect(
        outbox.read(id)!['acceptedSourceRevision'],
        h.repo.get(id)!.revision,
      );
    },
  );
  test('changed actor never sends or exposes previous owner records', () async {
    final id = await h.prepare();
    online = false;
    await sync.run();
    h.access = HydrostaticAccess(
      actor: HydrostaticActorSnapshot(
        userId: uuid(),
        name: 'OTHER SYNTHETIC',
        sessionId: uuid(),
        deviceInstallationId: h.access.actor.deviceInstallationId,
      ),
      authorized: true,
      fieldSession: true,
    );
    online = true;
    await sync.run();
    expect(remote.requests, isEmpty);
    expect(sync.view(id), null);
    expect(outbox.read(id)!['active'], isNotNull);
  });
  test(
    'session changes during response pause ACK; same owner new session recovers',
    () async {
      final id = await h.prepare();
      final original = h.access.actor;
      remote.afterCommit = () {
        h.access = HydrostaticAccess(
          actor: HydrostaticActorSnapshot(
            userId: original.userId,
            name: original.name,
            sessionId: uuid(),
            deviceInstallationId: original.deviceInstallationId,
          ),
          authorized: true,
          fieldSession: true,
        );
      };
      await sync.run();
      expect(outbox.read(id)!['active']['state'], 'PAUSED');
      remote.afterCommit = null;
      await sync.run(manual: true);
      expect(outbox.read(id)!['active'], null);
      expect(remote.requests, hasLength(1));
      expect(h.repo.get(id)!.actor.sessionId, original.sessionId);
    },
  );
  test('installation changes cannot submit old records', () async {
    final id = await h.prepare();
    final old = h.access.actor;
    h.access = HydrostaticAccess(
      actor: HydrostaticActorSnapshot(
        userId: old.userId,
        name: old.name,
        sessionId: uuid(),
        deviceInstallationId: uuid(),
      ),
      authorized: true,
      fieldSession: true,
    );
    await sync.run();
    expect(remote.requests, isEmpty);
    expect(outbox.read(id), null);
  });
  test(
    '409 preserves exact request while a different dossier commits',
    () async {
      final one = await h.prepare(), two = await h.prepare();
      remote.failuresById[one] = const HydrostaticSyncFailure(
        409,
        'REVISION_CONFLICT',
      );
      await sync.run();
      final c = outbox.read(one)!['active']['command'];
      expect(outbox.read(one)!['active']['state'], 'CONFLICT');
      expect(outbox.read(one)!['active']['remoteStatus']['serverVersion'], 7);
      expect(outbox.read(two)!['active'], null);
      expect(outbox.read(two)!['serverVersion'], 1);
      final calls = remote.requests.length;
      await sync.run();
      expect(
        remote.requests.length,
        calls,
      ); // No automatic overwrite of conflict.
      remote.failuresById.clear();
      await sync.run(manual: true);
      final attempts = remote.requests
          .where((r) => r['operationId'] == c['operationId'])
          .toList();
      expect(attempts, hasLength(2));
      expect(attempts[0], c);
      expect(attempts[1], c);
      expect(
        outbox.read(one)!['serverVersion'],
        1,
      ); // Never adopted remote version 7.
    },
  );
  test(
    'invalid receipt is not accepted; authoritative recovery required',
    () async {
      final id = await h.prepare();
      remote.corruptReceipt = true;
      await sync.run();
      expect(outbox.read(id)!['active']['state'], 'SENT_UNKNOWN');
      expect(outbox.read(id)!['serverVersion'], 0);
      remote.corruptReceipt = false;
      await sync.run(manual: true);
      expect(outbox.read(id)!['serverVersion'], 1);
    },
  );
  test(
    'backoff prevents busy looping and manual retry overrides delay',
    () async {
      await h.prepare();
      remote.fail = const HydrostaticSyncFailure(503, 'UNAVAILABLE');
      await sync.run();
      await sync.run();
      expect(remote.requests, hasLength(1));
      remote.fail = null;
      await sync.run(manual: true);
      expect(remote.requests, hasLength(2));
    },
  );
  test('capability mismatch never posts documents', () async {
    final id = await h.prepare();
    remote.environment = 'PRODUCTION';
    await sync.run();
    expect(remote.requests, isEmpty);
    expect(outbox.read(id)!['active']['state'], 'PENDING');
  });
  for (final code in [401, 403, 422]) {
    test('HTTP $code retains document and frozen command', () async {
      final id = await h.prepare();
      remote.fail = HydrostaticSyncFailure(code, 'REJECTED_TEST');
      await sync.run();
      expect(
        outbox.read(id)!['active']['state'],
        code == 422 ? 'REJECTED' : 'PAUSED',
      );
      expect(h.repo.get(id), isNotNull);
    });
  }
  test(
    'local development deletion blocked offline and after receipt',
    () async {
      final id = await h.prepare();
      online = false;
      await sync.run();
      Future<void> check() async => expectLater(
        h.repo.deleteLocal(id, uuid(), confirmedTestId: id),
        throwsA(
          isA<HydrostaticException>().having(
            (e) => e.code,
            'code',
            'SYNC_PROTECTED',
          ),
        ),
      );
      await check();
      online = true;
      await sync.run();
      await check();
    },
  );
  test(
    'approved and video declaration remain independent after update',
    () async {
      final id = await h.passed();
      await sync.run();
      final before = h.repo.get(id)!;
      await h.repo.declareVideoSent(id, uuid());
      await sync.run();
      expect(remote.requests.last['type'], 'UPDATE_DOCUMENT');
      final d = jsonDecode(remote.requests.last['payloadJson'])['document'];
      expect(d['state'], 'PASSED');
      expect(d['video']['state'], 'DECLARED_SENT');
      expect(h.repo.get(id)!.durationMs, before.durationMs);
      expect(
        h.repo.get(id)!.evidence.map((e) => e.sha256),
        before.evidence.map((e) => e.sha256),
      );
    },
  );
  test('FAILED and discarded retain result distinction and photos', () async {
    final fail = await h.ended();
    await h.add(fail, HydrostaticEvidenceRole.leakEvidence);
    await h.repo.saveLeaks(fail, uuid(), [
      HydrostaticLeak(id: uuid(), jointCode: 'J01', pressureMilliBar: 2000),
    ]);
    await h.repo.closeLeak(fail, uuid());
    final discarded = await h.ended();
    h.clock.advance(11 * 60 * 1000);
    await h.repo.discardExpired(discarded, uuid());
    await sync.run();
    final docs = remote.requests
        .map((c) => jsonDecode(c['payloadJson'])['document'])
        .toList();
    expect(docs.firstWhere((d) => d['id'] == fail)['result'], 'LEAK');
    expect(docs.firstWhere((d) => d['id'] == discarded)['result'], 'PENDING');
    expect(h.repo.get(discarded)!.isDiscarded, true);
    for (final t in h.repo.forUser()) {
      for (final e in t.evidence) {
        expect(await h.files.verify(e), true);
      }
    }
  });
  for (final boundary in [
    'before:enqueue',
    'after:enqueue',
    'before:sending',
    'after:sending',
    'before:acknowledge',
    'after:acknowledge',
  ]) {
    test('fault injection $boundary recovers after real Hive reopen', () async {
      final id = await h.active();
      bool once = false;
      outbox.fault = (at) async {
        if (at == boundary && !once) {
          once = true;
          throw StateError('synthetic disk interruption');
        }
      };
      await sync.run();
      expect(once, true);
      await reopen();
      await sync.run(manual: true);
      expect(outbox.read(id)!['active'], null);
      expect(remote.receipts, hasLength(1));
      expect(outbox.read(id)!['serverVersion'], 1);
      expect(h.repo.get(id)!.attemptNumber, 1);
    });
  }
  test(
    'process interrupted in-flight recovers exact request after reopen',
    () async {
      final id = await h.prepare();
      online = false;
      await sync.run();
      final r = outbox.read(id)!;
      final command = r['active']['command'];
      await outbox.save(id, {
        ...r,
        'active': {...hydroObject(r['active']), 'state': 'IN_FLIGHT'},
      }, 'syntheticCrash');
      await reopen();
      online = true;
      await sync.run();
      expect(remote.reads, 1);
      expect(remote.requests.single, command);
    },
  );
  test('corrupt outbox refuses blind resend and keeps original', () async {
    final id = await h.prepare();
    online = false;
    await sync.run();
    final raw = outbox.box.get(id)!;
    await outbox.box.put(id, raw.replaceFirst('PENDING', 'BROKEN'));
    await outbox.box.flush();
    online = true;
    await sync.run();
    expect(remote.requests, isEmpty);
    expect(h.repo.get(id), isNotNull);
  });
}
