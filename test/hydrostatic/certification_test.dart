import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_repository.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_approval_policy.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'execution_harness.dart';
import 'harness.dart';
import 'results_test.dart' show draft;

class SlowIntegrity extends LocalHydrostaticEvidenceFiles {
  SlowIntegrity(super.root, this.h);
  final ExecutionHarness h;
  bool delayed = false;
  @override
  Future<bool> verify(HydrostaticEvidence evidence) async {
    if (!delayed) {
      delayed = true;
      h.clock.advance(2);
    }
    return super.verify(evidence);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ExecutionHarness h;
  setUp(() async {
    h = ExecutionHarness();
    await h.open();
    h.approvalPolicy = HydrostaticApprovalPolicy.approved;
    await h.restart();
    h.picker.distinctBytes = true;
  });
  tearDown(() async => h.close());

  Future<String> pending({String branch = 'approval'}) async {
    final id = await h.active();
    h.clock.advance(1000);
    await h.add(id, HydrostaticEvidenceRole.manometer5Bar, gps: h.location());
    await h.repo.finish(id, uuid());
    if (branch != 'answer') {
      await h.repo.answerLeaks(id, uuid(), branch == 'leak');
    }
    if (branch == 'approval') {
      await h.add(id, HydrostaticEvidenceRole.final4Bar);
    }
    if (branch == 'leak') {
      await h.repo.saveLeakDraft(id, uuid(), draft({'J01': '2'}));
      await h.add(id, HydrostaticEvidenceRole.leakEvidence);
    }
    return id;
  }

  test(
    'legacy pending close without temporal witness is preserved for review',
    () async {
      final id = await pending();
      final op = uuid();
      h.store.fault = (p) async {
        if (p == 'before:document') throw const FileSystemException('stop');
      };
      await expectLater(
        h.repo.closePass(id, op),
        throwsA(isA<FileSystemException>()),
      );
      h.store.fault = null;
      final entry = h.repo.journal.get(op)!;
      entry.remove('closeWitness');
      entry['after'] = {...hydroObject(entry['after'])}..remove('closeWitness');
      await h.repo.journal.save(entry, 'syntheticLegacy');
      await h.restart();
      expect(h.repo.get(id)!.closedAt, null);
      expect(h.repo.get(id)!.isDiscarded, false);
      expect(
        h.repo.journal.get(op)!['uncertainCloseCandidate']['type'],
        'closePass',
      );
      expect(
        h.repo.get(id)!.toJson()['temporalReview']['reason'],
        'LEGACY_CLOSE_TIME_UNVERIFIABLE',
      );
    },
  );
  for (final phase in [
    'preparation',
    'starting',
    'active',
    'passed',
    'failed',
  ]) {
    test('$phase never expires as an incomplete result', () async {
      final String id;
      if (phase == 'preparation') {
        id = await h.prepare();
      } else if (phase == 'starting') {
        id = await h.starting();
      } else if (phase == 'active') {
        id = await h.active();
      } else if (phase == 'passed') {
        id = await h.passed();
      } else {
        id = await pending(branch: 'leak');
        await h.repo.closeLeak(id, uuid());
      }
      h.clock.advance(3 * 86400000);
      expect(h.repo.resultExpired(h.repo.get(id)!), false);
      expect(h.repo.requiresTimeReview(h.repo.get(id)!), false);
    });
  }
  test(
    'A full controller approval/video survives real Hive reopen and intact JPEGs',
    () async {
      final id = await h.ready();
      await h.controller.start(id);
      h.clock.advance(1000);
      await h.controller.capturePhoto(
        id,
        HydrostaticEvidenceRole.manometer5Bar,
      );
      await h.controller.finish(id);
      await h.controller.resultAction(id, 'answer', yes: false);
      await h.controller.capturePhoto(id, HydrostaticEvidenceRole.final4Bar);
      await h.controller.resultAction(id, 'pass');
      expect(h.repo.get(id)!.video.state, HydrostaticVideoState.pending);
      await h.controller.resultAction(id, 'video', confirmed: true);
      final before = h.repo.get(id)!.toJson();
      await h.restart();
      expect(h.repo.get(id)!.toJson(), before);
      expect(h.repo.get(id)!.state, HydrostaticTestState.passed);
      for (final e in h.repo.get(id)!.evidence) {
        expect(await h.files.verify(e), true);
      }
      expect(h.network.calls, 0);
    },
  );
  test(
    'B full multi-leak controller flow followed by independent attempt 2',
    () async {
      final id = await h.ready();
      await h.controller.start(id);
      h.clock.advance(1000);
      await h.controller.finish(id);
      await h.controller.resultAction(id, 'answer', yes: true);
      await h.controller.saveDraft(
        id,
        draft(
          {'J01': '1,125', 'J02': '3', 'J11': '4.999'},
          other: 'Unión sintética',
          observation: 'TEST',
        ),
      );
      await h.controller.capturePhoto(id, HydrostaticEvidenceRole.leakEvidence);
      await h.controller.linkEvidence(id, h.repo.get(id)!.evidence.last.id, [
        'J01',
        'J02',
        'J11',
      ]);
      await h.controller.resultAction(id, 'leak');
      final before = h.repo.get(id)!.toJson();
      await h.restart();
      final next = await h.ready();
      await h.controller.start(next);
      expect(next, isNot(id));
      expect(h.repo.get(next)!.attemptNumber, 2);
      expect(h.repo.get(id)!.toJson(), before);
      expect(h.repo.get(id)!.state, HydrostaticTestState.failed);
    },
  );
  test(
    'C partial leak expires on restart, conserves evidence, new attempt increments',
    () async {
      final id = await h.ready();
      await h.controller.start(id);
      h.clock.advance(1000);
      await h.controller.finish(id);
      await h.controller.resultAction(id, 'answer', yes: true);
      await h.controller.saveDraft(
        id,
        draft({'J11': '2,'}, other: 'En captura'),
      );
      await h.controller.capturePhoto(id, HydrostaticEvidenceRole.leakEvidence);
      final photos = h.repo.get(id)!.evidence;
      h.clock.advance(1800001);
      await h.restart();
      final discarded = h.repo.get(id)!;
      expect(discarded.isDiscarded, true);
      expect(discarded.result, HydrostaticResult.pending);
      expect(discarded.toJson()['discardedFromState'], 'LEAK_DETAILS_PENDING');
      expect(
        discarded.toJson()['leakDraft']['joints']['J11']['pressure'],
        '2,',
      );
      for (final e in photos) {
        expect(await h.files.verify(e), true);
      }
      final next = await h.ready();
      await h.controller.start(next);
      expect(h.repo.get(next)!.attemptNumber, 2);
      expect(next, isNot(id));
    },
  );

  for (final branch in ['answer', 'leak', 'approval']) {
    for (final elapsed in [1799999, 1800000, 1800001]) {
      test('$branch boundary $elapsed ms uses durable policy', () async {
        final id = await pending(branch: branch);
        h.clock.advance(elapsed);
        if (elapsed > 1800000) {
          await h.repo.discardExpired(id, uuid());
          expect(h.repo.get(id)!.isDiscarded, true);
          await expectLater(
            h.repo.closePass(id, uuid()),
            throwsA(isA<HydrostaticException>()),
          );
        } else if (branch == 'answer') {
          await h.repo.answerLeaks(id, uuid(), false);
          expect(h.repo.get(id)!.hadLeaks, false);
        } else {
          if (branch == 'leak') {
            await h.repo.closeLeak(id, uuid());
          } else {
            await h.repo.closePass(id, uuid());
          }
          expect(h.repo.get(id)!.closedAt, h.clock.utc);
        }
      });
    }
  }
  for (final boundary in [
    'before:prepared',
    'after:prepared',
    'before:ready',
    'after:ready',
  ]) {
    test('deadline crossing during $boundary cannot certify close', () async {
      final id = await pending();
      h.clock.advance(1799999);
      h.store.fault = (p) async {
        if (p == boundary) h.clock.advance(2);
      };
      await expectLater(
        h.repo.closePass(id, uuid()),
        throwsA(isA<HydrostaticException>()),
      );
      h.store.fault = null;
      await h.restart();
      expect(h.repo.get(id)!.state, isNot(HydrostaticTestState.passed));
    });
  }
  test(
    'deadline crossing during integrity verification rejects close',
    () async {
      final id = await pending();
      h.clock.advance(1799999);
      h.repo = HydrostaticRepository(
        store: h.store,
        clock: h.clock,
        access: () => h.access,
        files: SlowIntegrity(h.root, h),
        approvalPolicy: h.approvalPolicy,
      );
      await expectLater(
        h.repo.closePass(id, uuid()),
        throwsA(isA<HydrostaticException>()),
      );
      expect(h.repo.get(id)!.closedAt, null);
    },
  );
  for (final boundary in [
    'after:closeWitness',
    'before:document',
    'after:document',
  ]) {
    test(
      'close committed before limit wins over later expiry at $boundary',
      () async {
        final id = await pending();
        h.clock.advance(1799999);
        final op = uuid();
        h.store.fault = (p) async {
          if (p == boundary) {
            throw const FileSystemException('synthetic interruption');
          }
        };
        await expectLater(
          h.repo.closePass(id, op),
          throwsA(isA<FileSystemException>()),
        );
        h.clock.advance(86400000);
        await h.restart();
        expect(h.repo.get(id)!.state, HydrostaticTestState.passed);
        expect(h.repo.get(id)!.isDiscarded, false);
        expect(h.repo.get(id)!.toJson()['closeWitness']['elapsedMs'], 1799999);
      },
    );
  }
  for (final boundary in ['after:ready', 'before:closeWitness']) {
    test(
      'uncertain commit at $boundary remains review, not retrospective approval/discard',
      () async {
        final id = await pending();
        h.clock.advance(1799999);
        h.store.fault = (p) async {
          if (p == boundary) throw const FileSystemException('interrupted');
        };
        await expectLater(
          h.repo.closePass(id, uuid()),
          throwsA(isA<FileSystemException>()),
        );
        h.clock.advance(86400000);
        await h.restart();
        expect(h.repo.get(id)!.closedAt, null);
        expect(h.repo.get(id)!.isDiscarded, false);
        expect(h.repo.get(id)!.timeState, HydrostaticTimeState.needsReview);
      },
    );
  }
  test(
    'deadline reached inside camera preserves original and intent before discard',
    () async {
      final id = await pending(branch: 'leak');
      await h.controller.initialize();
      h.picker.beforeReturn = () async {
        h.clock.advance(1800001);
      };
      await h.controller.capturePhoto(id, HydrostaticEvidenceRole.leakEvidence);
      final photo = h.repo.get(id)!.evidence.last;
      await h.controller.expireResults();
      expect(h.repo.get(id)!.isDiscarded, true);
      expect(await h.files.verify(photo), true);
      expect(
        h.store.read(
          h.store.metadata,
          'capture:${photo.captureIntentId}',
        )!['state'],
        'LINKED',
      );
    },
  );
  test(
    'discard write failure does not announce durable discard; restart recovers',
    () async {
      final id = await pending();
      h.clock.advance(1800001);
      h.store.fault = (p) async {
        if (p == 'before:document') throw const FileSystemException('full');
      };
      await expectLater(
        h.repo.discardExpired(id, uuid()),
        throwsA(isA<FileSystemException>()),
      );
      expect(h.store.test(id)!.isDiscarded, false);
      await h.restart();
      expect(h.repo.get(id)!.isDiscarded, true);
    },
  );
  for (final kind in ['preparation', 'failed', 'passed', 'discarded']) {
    test(
      'development deletion of $kind preserves unrelated data and sequence',
      () async {
        final String id;
        if (kind == 'preparation') {
          id = await h.prepare();
          await h.add(id, HydrostaticEvidenceRole.initialSetup);
        } else {
          id = await pending(branch: kind == 'failed' ? 'leak' : 'approval');
        }
        if (kind == 'failed') await h.repo.closeLeak(id, uuid());
        if (kind == 'passed') await h.repo.closePass(id, uuid());
        if (kind == 'discarded') {
          h.clock.advance(1800001);
          await h.repo.discardExpired(id, uuid());
        }
        final number = h.repo.sequences.last(h.cabinet.uid);
        final other = await h.prepare();
        await h.add(other, HydrostaticEvidenceRole.initialSetup);
        final foreign = h.repo.get(other)!.evidence.single;
        await h.repo.deleteLocal(id, uuid(), confirmedTestId: id);
        expect(h.repo.get(id), null);
        expect(await h.files.verify(foreign), true);
        expect(h.repo.sequences.last(h.cabinet.uid), number);
      },
    );
  }
}
