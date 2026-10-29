import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_store.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'harness.dart';

Matcher error(String code) =>
    isA<HydrostaticException>().having((e) => e.code, 'code', code);
void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await h.open();
  });
  tearDown(() async {
    await h.close();
  });
  test(
    'shared-path protection and default disabled deletion preserve bytes',
    () async {
      final id = await h.prepare();
      final e = await h.evidence(id, HydrostaticEvidenceRole.initialSetup);
      await expectLater(
        h.files.removeExclusive(id, [e], {e.originalPath}),
        throwsA(error('SHARED_FILE')),
      );
      expect(await h.files.verify(e), true);
      expect(
        () => const HydrostaticDevelopmentPolicy().requireDeletion(),
        throwsA(error('DELETE_DISABLED')),
      );
      expect(
        () => const HydrostaticDevelopmentPolicy(
          environment: 'test',
          enabled: true,
          syntheticData: false,
        ).requireDeletion(),
        throwsA(error('DELETE_DISABLED')),
      );
    },
  );
  test(
    'snapshot serialized validation rejects contradictory result and numbering',
    () async {
      final id = await h.prepare();
      final j = h.repo.get(id)!.toJson();
      j['attemptNumber'] = 1;
      expect(
        () => HydrostaticTest.fromJson(j),
        throwsA(error('INVALID_DOCUMENT')),
      );
      j['attemptNumber'] = null;
      j['result'] = 'PASS';
      expect(
        () => HydrostaticTest.fromJson(j),
        throwsA(error('INVALID_DOCUMENT')),
      );
    },
  );
  test('unknown journal phase is preserved and blocks new writes', () async {
    final id = await h.prepare();
    final op = uuid();
    await h.repo.journal.save({
      'operationId': op,
      'testId': id,
      'phase': 'UNKNOWN_FUTURE',
    }, 'synthetic');
    await h.reopen();
    await expectLater(h.repo.recover(), throwsA(error('CORRUPT_JOURNAL')));
    expect(h.repo.journal.get(op)!['phase'], 'UNKNOWN_FUTURE');
    await expectLater(
      h.repo.requestStart(id, uuid()),
      throwsA(error('RECOVERY_REQUIRED')),
    );
  });
  test(
    'interrupted uncommitted deletion retries original operation after recovery',
    () async {
      final id = await h.prepare(), op = uuid();
      h.store.fault = (boundary) async {
        if (boundary == 'before:ready') {
          throw const FileSystemException('synthetic disk full');
        }
      };
      await expectLater(
        h.repo.deleteLocal(id, op, confirmedTestId: id),
        throwsA(isA<FileSystemException>()),
      );
      await h.reopen();
      await h.repo.recover();
      expect(h.repo.get(id), isNotNull);
      await h.repo.deleteLocal(id, op, confirmedTestId: id);
      expect(h.repo.get(id), isNull);
    },
  );
  test('a second store writer is refused without closing the first', () async {
    await expectLater(
      HydrostaticStore.open(Directory('${h.root.path}/other')),
      throwsA(error('STORE_ALREADY_OPEN')),
    );
    final id = await h.prepare();
    expect(h.repo.get(id), isNotNull);
  });
  test(
    'session changes at durable preparation prevent committing a new command',
    () async {
      final id = await h.prepare();
      final original = h.access;
      h.store.fault = (boundary) async {
        if (boundary == 'after:prepared') {
          h.access = HydrostaticAccess(
            actor: original.actor,
            authorized: false,
            fieldSession: true,
          );
        }
      };
      final e = await h.evidence(id, HydrostaticEvidenceRole.initialSetup);
      await expectLater(
        h.repo.addEvidence(id, uuid(), e),
        throwsA(error('NOT_AUTHORIZED')),
      );
      h.access = original;
      await h.reopen();
      await h.repo.recover();
      expect(h.repo.get(id)!.evidence, isEmpty);
      expect(await File('${h.root.path}/${e.originalPath}').exists(), true);
    },
  );
  test(
    'independent devices may assign the same number but retain different UUIDs',
    () async {
      final first = await h.active();
      final number = h.repo.get(first)!.attemptNumber;
      await h.store.close();
      final second = Harness();
      await second.open();
      try {
        final id = await second.active();
        expect(id, isNot(first));
        expect(second.repo.get(id)!.attemptNumber, number);
      } finally {
        await second.close();
      }
      await h.reopen(first: true);
      expect(h.repo.get(first)!.attemptNumber, number);
    },
  );
  test(
    'failed and passed cannot restart or change result; absent initial blocks start',
    () async {
      final id = await h.prepare();
      await expectLater(
        h.repo.requestStart(id, uuid()),
        throwsA(error('EVIDENCE_INCOMPLETE')),
      );
      final passed = await h.passed();
      await expectLater(
        h.repo.requestStart(passed, uuid()),
        throwsA(error('INVALID_STATE')),
      );
      await expectLater(
        h.repo.answerLeaks(passed, uuid(), true),
        throwsA(error('INVALID_STATE')),
      );
    },
  );
  test(
    'replaying committed preparation keeps identity and creation date',
    () async {
      final id = uuid(), op = uuid();
      final first = await h.repo.prepare(
        operationId: op,
        testId: id,
        cabinet: h.cabinet,
      );
      h.clock.advance(10000);
      await h.reopen();
      final repeat = await h.repo.prepare(
        operationId: op,
        testId: id,
        cabinet: h.cabinet,
      );
      expect(repeat.toJson(), first.toJson());
    },
  );
  test(
    'preparation is reopened with no number and immutable snapshots',
    () async {
      final id = await h.prepare();
      final before = h.repo.get(id)!.toJson();
      final copy = h.repo.get(id)!.toJson();
      copy['cabinet']['model'] = 'A4';
      await h.reopen();
      expect(h.repo.get(id)!.toJson(), before);
      expect(h.repo.forCabinet(h.cabinet.uid), isEmpty);
      expect(h.repo.forUser().length, 1);
    },
  );
  test('GPS invalid retains STARTING and photo; cancel then retry', () async {
    final id = await h.starting();
    await expectLater(
      h.repo.start(id, uuid(), h.location(accuracy: 101)),
      throwsA(error('GPS_REQUIRED')),
    );
    expect(h.repo.get(id)!.attemptNumber, isNull);
    expect(h.repo.get(id)!.evidence.length, 1);
    await h.repo.cancelStart(id, uuid());
    await h.repo.requestStart(id, uuid());
    await h.repo.start(id, uuid(), h.location());
    await h.reopen();
    expect(h.repo.get(id)!.state, HydrostaticTestState.active);
  });
  test(
    'concurrent starts and repeated commands retain number and timestamps',
    () async {
      final id = await h.starting();
      final op = uuid();
      final gps = h.location();
      final results = await Future.wait([
        h.repo.start(id, op, gps),
        h.repo.start(id, op, gps),
        h.repo.start(id, uuid(), gps),
      ]);
      expect(results.map((t) => t.attemptNumber).toSet(), {1});
      await h.reopen();
      h.clock.advance(12345);
      final endOp = uuid();
      final t = await h.repo.finish(id, endOp);
      h.clock.advance(5000);
      expect((await h.repo.finish(id, uuid())).endedAt, t.endedAt);
      expect((await h.repo.finish(id, endOp)).durationMs, 12345);
      await h.reopen();
      expect(h.repo.get(id)!.durationMs, 12345);
    },
  );
  test('operation payload collision and stale revision rejected', () async {
    final id = await h.ended();
    final op = uuid();
    final leak = HydrostaticLeak(
      id: uuid(),
      jointCode: 'J01',
      pressureMilliBar: 2000,
    );
    final rev = h.repo.get(id)!.revision;
    await h.repo.saveLeaks(id, op, [leak], expectedRevision: rev);
    await expectLater(
      h.repo.saveLeaks(id, op, [], expectedRevision: rev),
      throwsA(error('IDEMPOTENCY_CONFLICT')),
    );
    await expectLater(
      h.repo.saveLeaks(id, uuid(), [], expectedRevision: rev),
      throwsA(error('REVISION_CONFLICT')),
    );
  });
  test(
    'multiple leaks, Other and required evidence survive reopen and close without 5 bar',
    () async {
      final id = await h.ended();
      await h.repo.saveLeaks(id, uuid(), [
        HydrostaticLeak(id: uuid(), jointCode: 'J01', pressureMilliBar: 1001),
        HydrostaticLeak(id: uuid(), jointCode: 'J11', pressureMilliBar: 2000),
      ]);
      await h.reopen();
      await expectLater(
        h.repo.closeLeak(id, uuid()),
        throwsA(error('LEAK_INCOMPLETE')),
      );
      await h.repo.saveLeaks(id, uuid(), [
        HydrostaticLeak(id: uuid(), jointCode: 'J01', pressureMilliBar: 1001),
        HydrostaticLeak(
          id: uuid(),
          jointCode: 'J11',
          pressureMilliBar: 2000,
          description: 'Otra unión',
        ),
      ]);
      await expectLater(
        h.repo.closeLeak(id, uuid()),
        throwsA(error('EVIDENCE_INCOMPLETE')),
      );
      await h.add(id, HydrostaticEvidenceRole.leakEvidence);
      await h.repo.closeLeak(id, uuid());
      await h.reopen();
      final t = h.repo.get(id)!;
      expect(t.state, HydrostaticTestState.failed);
      expect(t.leaks.length, 2);
      expect(t.video.state, HydrostaticVideoState.notApplicable);
      await expectLater(
        h.repo.closePass(id, uuid()),
        throwsA(error('INVALID_STATE')),
      );
    },
  );
  test(
    'pass requires all evidence; documentary closing time distinct; video idempotent',
    () async {
      final id = await h.ended(yes: false);
      final duration = h.repo.get(id)!.durationMs;
      await expectLater(
        h.repo.closePass(id, uuid()),
        throwsA(error('EVIDENCE_INCOMPLETE')),
      );
      h.clock.advance(20000);
      await h.add(id, HydrostaticEvidenceRole.final4Bar);
      await h.repo.closePass(id, uuid());
      await h.reopen();
      final t = h.repo.get(id)!;
      expect(t.result, HydrostaticResult.pass);
      expect(t.video.state, HydrostaticVideoState.pending);
      expect(t.durationMs, duration);
      expect(t.closedAt!.isAfter(t.endedAt!), true);
      final op = uuid();
      final v = await h.repo.declareVideoSent(id, op);
      h.clock.advance(1000);
      expect(
        (await h.repo.declareVideoSent(id, uuid())).video.declaredAt,
        v.video.declaredAt,
      );
      expect((await h.repo.declareVideoSent(id, op)).revision, v.revision);
      await h.reopen();
      expect(h.repo.get(id)!.video.actorId, h.access.actor.userId);
    },
  );
  test(
    'same 5 and 4 bytes cannot assert different pressure captures',
    () async {
      final id = await h.active();
      h.clock.advance(1000);
      await h.repo.addEvidence(
        id,
        uuid(),
        await h.evidence(
          id,
          HydrostaticEvidenceRole.manometer5Bar,
          text: 'identical',
          gps: h.location(),
        ),
      );
      h.clock.advance(1000);
      await h.repo.finish(id, uuid());
      await h.repo.answerLeaks(id, uuid(), false);
      await h.repo.addEvidence(
        id,
        uuid(),
        await h.evidence(
          id,
          HydrostaticEvidenceRole.final4Bar,
          text: 'identical',
        ),
      );
      await expectLater(
        h.repo.closePass(id, uuid()),
        throwsA(error('EVIDENCE_CHRONOLOGY')),
      );
    },
  );
  test(
    'missing 5 bar GPS and out-of-order photograph block approval',
    () async {
      final id = await h.active();
      h.clock.advance(1000);
      await h.add(id, HydrostaticEvidenceRole.manometer5Bar);
      await h.repo.finish(id, uuid());
      await h.repo.answerLeaks(id, uuid(), false);
      await h.add(id, HydrostaticEvidenceRole.final4Bar);
      await expectLater(
        h.repo.closePass(id, uuid()),
        throwsA(error('EVIDENCE_CHRONOLOGY')),
      );
    },
  );
  test('missing/corrupt originals rejected, no false READY approval', () async {
    final id = await h.prepare();
    final e = await h.evidence(id, HydrostaticEvidenceRole.initialSetup);
    await File('${h.root.path}/${e.originalPath}').writeAsString('broken');
    await expectLater(
      h.repo.addEvidence(id, uuid(), e),
      throwsA(error('FILE_CORRUPT')),
    );
    await File('${h.root.path}/${e.originalPath}').delete();
    expect(await h.files.verify(e), false);
  });
  test(
    'clock anomalies preserve fin and block closure; reboot reconstructs elapsed',
    () async {
      final id = await h.active();
      h.clock.advance(1000);
      await h.reopen();
      h.clock.reboot();
      h.clock.advance(5000);
      expect(h.repo.elapsed(id).state, HydrostaticTimeState.reconstructed);
      h.clock.utc = h.repo
          .get(id)!
          .startedAt!
          .subtract(const Duration(hours: 1));
      await h.repo.finish(id, uuid());
      await h.repo.answerLeaks(id, uuid(), true);
      await expectLater(
        h.repo.closeLeak(id, uuid()),
        throwsA(error('CLOCK_REVIEW_REQUIRED')),
      );
      await h.reopen();
      expect(h.repo.get(id)!.state, HydrostaticTestState.leakDetailsPending);
      expect(h.repo.get(id)!.timeState, HydrostaticTimeState.needsReview);
    },
  );
  test(
    'actor changes prevent reading/writing and do not reattribute captures',
    () async {
      final id = await h.prepare();
      final original = h.access;
      h.access = HydrostaticAccess(
        actor: HydrostaticActorSnapshot(
          userId: uuid(),
          name: 'OTHER',
          sessionId: uuid(),
          deviceInstallationId: uuid(),
        ),
        authorized: true,
        fieldSession: true,
      );
      expect(() => h.repo.get(id), throwsA(error('NOT_AUTHORIZED')));
      expect(h.repo.forUser(), isEmpty);
      await expectLater(
        h.repo.requestStart(id, uuid()),
        throwsA(error('NOT_AUTHORIZED')),
      );
      h.access = HydrostaticAccess(
        actor: original.actor,
        authorized: false,
        fieldSession: true,
      );
      expect(() => h.repo.get(id), throwsA(error('NOT_AUTHORIZED')));
      h.access = original;
      expect(h.repo.get(id)!.actor.userId, original.actor.userId);
    },
  );
  test(
    'foreign module Hive sentinel, pending queues and files are unchanged',
    () async {
      final foreign = await Hive.openBox<String>(
        'construction_sync_queue_v1',
        path: '${h.root.path}/foreign',
      );
      await foreign.put('pending', 'DO NOT TOUCH');
      final file = File('${h.root.path}/foreign-photo.jpg');
      await file.writeAsString('FIELD SENTINEL');
      final before = await file.readAsBytes();
      final id = await h.prepare();
      await h.repo.deleteLocal(id, uuid(), confirmedTestId: id);
      expect(foreign.toMap(), {'pending': 'DO NOT TOUCH'});
      expect(await file.readAsBytes(), before);
      await foreign.close();
    },
  );
  test('indexes rebuild and corrupted/future documents are retained', () async {
    final id = await h.active();
    await h.store.metadata.delete('indexes');
    await h.repo.rebuildIndexes();
    expect(
      h.store.read(h.store.metadata, 'indexes')!['byCabinet'][h.cabinet.uid],
      [id],
    );
    final raw = h.store.documents.get('test:$id')!;
    await h.store.documents.put('test:$id', raw.replaceFirst('A1', 'A4'));
    expect(() => h.repo.get(id), throwsA(error('CORRUPT_DOCUMENT')));
    expect(h.store.documents.containsKey('test:$id'), true);
    final future = {'schemaVersion': 99};
    await h.store.write(h.store.documents, 'test:$id', future, 'synthetic');
    expect(() => h.repo.get(id), throwsA(error('SCHEMA_UNSUPPORTED')));
    expect(h.store.documents.containsKey('test:$id'), true);
  });
  test(
    'delete capability, exact confirmation, capture and active guard',
    () async {
      final id = await h.prepare();
      await expectLater(
        h.repo.deleteLocal(id, uuid(), confirmedTestId: uuid()),
        throwsA(error('CONFIRMATION_REQUIRED')),
      );
      h.capturing = true;
      await expectLater(
        h.repo.deleteLocal(id, uuid(), confirmedTestId: id),
        throwsA(error('BUSY')),
      );
      h.capturing = false;
      h.policy = const HydrostaticDevelopmentPolicy(
        environment: 'production',
        enabled: true,
        syntheticData: true,
      );
      await h.reopen();
      await expectLater(
        h.repo.deleteLocal(id, uuid(), confirmedTestId: id),
        throwsA(error('DELETE_DISABLED')),
      );
      h.policy = const HydrostaticDevelopmentPolicy(
        environment: 'test',
        enabled: true,
        syntheticData: true,
      );
      await h.reopen();
      final active = await h.active();
      await expectLater(
        h.repo.deleteLocal(active, uuid(), confirmedTestId: active),
        throwsA(error('BUSY')),
      );
    },
  );
  test(
    'delete only selected evidence, repeat safely and never reuse number',
    () async {
      final id = await h.passed();
      final paths = h.repo
          .get(id)!
          .evidence
          .map((e) => File('${h.root.path}/${e.originalPath}'))
          .toList();
      final other = await h.prepare();
      final op = uuid();
      await h.repo.deleteLocal(id, op, confirmedTestId: id);
      for (final file in paths) {
        expect(await file.exists(), false);
      }
      expect(h.repo.get(id), isNull);
      expect(h.repo.get(other), isNotNull);
      final receipt = await h.repo.deleteLocal(id, op, confirmedTestId: id);
      expect(receipt.state, HydrostaticDeletionState.completed);
      await h.reopen();
      final next = await h.active();
      expect(h.repo.get(next)!.attemptNumber, 2);
    },
  );
  test('symlink original never deletes foreign target', () async {
    final id = await h.prepare();
    final e = await h.evidence(id, HydrostaticEvidenceRole.initialSetup);
    await h.repo.addEvidence(id, uuid(), e);
    final foreign = File('${h.root.path}/foreign.jpg');
    await foreign.writeAsString('preserve');
    final file = File('${h.root.path}/${e.originalPath}');
    await file.delete();
    await Link(file.path).create(foreign.path);
    await expectLater(
      h.repo.deleteLocal(id, uuid(), confirmedTestId: id),
      throwsA(error('INVALID_PATH')),
    );
    expect(await foreign.readAsString(), 'preserve');
  });
  for (final boundary in [
    'prepared',
    'ready',
    'sequence',
    'document',
    'indexes',
    'applied',
  ]) {
    for (final when in ['before', 'after']) {
      test(
        'start interruption $when:$boundary recovers exact committed values',
        () async {
          final id = await h.starting();
          final op = uuid();
          final gps = h.location();
          final timestamp = h.clock.utc;
          var hit = false;
          h.store.fault = (point) async {
            if (point == '$when:$boundary' && !hit) {
              hit = true;
              throw const FileSystemException(
                'synthetic disk full/interruption',
              );
            }
          };
          await expectLater(
            h.repo.start(id, op, gps),
            throwsA(isA<FileSystemException>()),
          );
          expect(hit, true);
          await h.reopen();
          h.clock.advance(300000);
          h.clock.reboot();
          await h.repo.recover();
          final committed =
              !(boundary == 'prepared' ||
                  (boundary == 'ready' && when == 'before'));
          if (committed) {
            expect(h.repo.get(id)!.startedAt, timestamp);
            expect(h.repo.get(id)!.attemptNumber, 1);
            expect(h.repo.get(id)!.toJson()['location'], gps.toJson());
            expect((await h.repo.start(id, op, gps)).startedAt, timestamp);
          } else {
            expect(h.repo.get(id)!.state, HydrostaticTestState.starting);
            expect(h.repo.sequences.last(h.cabinet.uid), 0);
          }
          expect(h.repo.forCabinet(h.cabinet.uid).length, committed ? 1 : 0);
        },
      );
    }
  }
  for (final boundary in [
    'prepared',
    'ready',
    'document',
    'indexes',
    'applied',
  ]) {
    for (final when in ['before', 'after']) {
      test(
        'finish interruption $when:$boundary does not create new final time',
        () async {
          final id = await h.active();
          h.clock.advance(2000);
          final op = uuid();
          final timestamp = h.clock.utc;
          var hit = false;
          h.store.fault = (point) async {
            if (point == '$when:$boundary' && !hit) {
              hit = true;
              throw const FileSystemException('synthetic interruption');
            }
          };
          await expectLater(
            h.repo.finish(id, op),
            throwsA(isA<FileSystemException>()),
          );
          expect(hit, true);
          await h.reopen();
          h.clock.advance(3000);
          await h.repo.recover();
          final committed =
              !(boundary == 'prepared' ||
                  (boundary == 'ready' && when == 'before'));
          expect(h.repo.get(id)!.endedAt, committed ? timestamp : null);
          if (committed) {
            expect((await h.repo.finish(id, op)).durationMs, 2000);
          }
        },
      );
    }
  }
  for (final boundary in [
    'prepared',
    'ready',
    'deleteRequested',
    'files',
    'filesRemoved',
    'deleteDocument',
    'scrub',
    'indexes',
    'deleteCompleted',
    'applied',
  ]) {
    for (final when in ['before', 'after']) {
      test(
        'delete interruption $when:$boundary recovers only selected dossier',
        () async {
          final id = await h.prepare();
          await h.add(id, HydrostaticEvidenceRole.initialSetup);
          final other = await h.prepare();
          final op = uuid();
          var hit = false;
          h.store.fault = (point) async {
            if (point == '$when:$boundary' && !hit) {
              hit = true;
              throw const FileSystemException('synthetic interruption');
            }
          };
          await expectLater(
            h.repo.deleteLocal(id, op, confirmedTestId: id),
            throwsA(isA<FileSystemException>()),
          );
          expect(hit, true);
          await h.reopen();
          await h.repo.recover();
          final committed =
              !(boundary == 'prepared' ||
                  (boundary == 'ready' && when == 'before'));
          expect(h.repo.get(id) == null, committed);
          expect(h.repo.get(other), isNotNull);
          if (committed) {
            expect(
              (await h.repo.deleteLocal(id, op, confirmedTestId: id)).state,
              HydrostaticDeletionState.completed,
            );
          }
        },
      );
    }
  }
}
