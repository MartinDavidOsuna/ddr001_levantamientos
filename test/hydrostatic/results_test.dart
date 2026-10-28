import 'dart:io';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_approval_policy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'harness.dart';

Map<String, dynamic> draft(
  Map<String, String> pressures, {
  String other = '',
  String observation = '',
}) => {
  'version': 1,
  'observation': observation,
  'joints': {
    for (final entry in pressures.entries)
      entry.key: {
        'selected': true,
        'pressure': entry.value,
        'description': entry.key == 'J11' ? other : '',
      },
  },
};
void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await h.open();
  });
  tearDown(() async => h.close());

  for (final milliseconds in [1800000, 1800001]) {
    test('approved procedure deadline boundary $milliseconds ms', () async {
      h.approvalPolicy = HydrostaticApprovalPolicy.approved;
      await h.reopen();
      final id = await h.ended(yes: false);
      h.clock.advance(milliseconds);
      await h.add(id, HydrostaticEvidenceRole.final4Bar);
      if (milliseconds == 1800000) {
        await h.repo.closePass(id, uuid());
        expect(h.repo.get(id)!.state, HydrostaticTestState.passed);
        expect(
          h.repo.get(id)!.toJson()['approvalPolicy']['version'],
          'hydrostatic-close-30m-v1',
        );
      } else {
        final photos = h.repo.get(id)!.evidence;
        await expectLater(
          h.repo.closePass(id, uuid()),
          throwsA(isA<HydrostaticException>()),
        );
        final op = uuid();
        await h.repo.discardExpired(id, op);
        final discarded = h.repo.get(id)!;
        expect(discarded.isDiscarded, true);
        expect(discarded.result, HydrostaticResult.pending);
        expect(discarded.closedAt, null);
        for (final e in photos) {
          expect(await h.files.verify(e), true);
        }
        await h.reopen();
        await h.repo.discardExpired(id, op);
        expect(h.repo.get(id)!.discardedAt, discarded.discardedAt);
        await expectLater(
          h.repo.changeAnswer(id, uuid(), true, confirmed: true),
          throwsA(isA<HydrostaticException>()),
        );
      }
    });
  }
  test(
    'video declaration has no deadline after approved hydraulic result',
    () async {
      final id = await h.passed();
      h.clock.advance(3 * 86400000);
      expect(h.repo.resultExpired(h.repo.get(id)!), false);
      await h.repo.declareVideoSent(id, uuid());
      expect(h.repo.get(id)!.video.state, HydrostaticVideoState.declaredSent);
    },
  );

  test(
    'answer changes require confirmation, preserve drafts and all originals',
    () async {
      final id = await h.ended();
      await h.repo.saveLeakDraft(
        id,
        uuid(),
        draft({'J01': '2,125', 'J11': ''}, other: '  '),
      );
      await h.add(id, HydrostaticEvidenceRole.leakEvidence);
      final before = h.repo.get(id)!;
      await expectLater(
        h.repo.changeAnswer(id, uuid(), false, confirmed: false),
        throwsA(isA<HydrostaticException>()),
      );
      await h.repo.changeAnswer(id, uuid(), false, confirmed: true);
      await h.reopen();
      await h.repo.changeAnswer(id, uuid(), true, confirmed: true);
      final after = h.repo.get(id)!;
      expect(after.toJson()['leakDraft'], before.toJson()['leakDraft']);
      expect(
        after.evidence.map((e) => e.originalPath),
        before.evidence.map((e) => e.originalPath),
      );
      expect(after.endedAt, before.endedAt);
      expect(after.durationMs, before.durationMs);
    },
  );

  for (final value in ['0', '-1', '5.001', '2.1234', '', '2,', 'abc']) {
    test(
      'invalid raw pressure $value survives reopen and blocks closure',
      () async {
        final id = await h.ended();
        await h.repo.saveLeakDraft(id, uuid(), draft({'J01': value}));
        await h.add(id, HydrostaticEvidenceRole.leakEvidence);
        await h.reopen();
        expect(
          h.repo.get(id)!.toJson()['leakDraft']['joints']['J01']['pressure'],
          value,
        );
        await expectLater(
          h.repo.closeLeak(id, uuid()),
          throwsA(isA<HydrostaticException>()),
        );
      },
    );
  }
  for (final value in ['1', '5', '2.125', '3,001']) {
    test('valid per-joint pressure $value closes and reopens FAILED', () async {
      final id = await h.ended();
      await h.repo.saveLeakDraft(
        id,
        uuid(),
        draft({
          'J01': value,
          'J02': '4',
          'J11': '1.123',
        }, other: 'Unión sintética'),
      );
      await h.add(id, HydrostaticEvidenceRole.leakEvidence);
      final photo = h.repo.get(id)!.evidence.last;
      await h.repo.linkLeakEvidence(id, uuid(), photo.id, ['J01', 'J02']);
      await h.repo.closeLeak(id, uuid());
      final closed = h.repo.get(id)!;
      await h.reopen();
      expect(h.repo.get(id)!.state, HydrostaticTestState.failed);
      expect(h.repo.get(id)!.leaks.length, 3);
      expect(h.repo.get(id)!.leaks.map((e) => e.id).toSet().length, 3);
      expect(h.repo.get(id)!.evidence.last.jointCodes, ['J01', 'J02']);
      expect(h.repo.get(id)!.evidence.last.originalPath, photo.originalPath);
      await h.repo.closeLeak(id, uuid());
      expect(h.repo.get(id)!.closedAt, closed.closedAt);
      await expectLater(
        h.repo.changeAnswer(id, uuid(), false, confirmed: true),
        throwsA(isA<HydrostaticException>()),
      );
    });
  }
  test(
    'Other whitespace, no joints, missing and corrupt photos block close',
    () async {
      final id = await h.ended();
      for (final d in [
        draft({}),
        draft({'J11': '3'}, other: '   '),
        draft({'J01': '2'}),
      ]) {
        await h.repo.saveLeakDraft(id, uuid(), d);
        await expectLater(
          h.repo.closeLeak(id, uuid()),
          throwsA(isA<HydrostaticException>()),
        );
      }
      await h.add(id, HydrostaticEvidenceRole.leakEvidence);
      final photo = h.repo.get(id)!.evidence.last;
      await File(
        '${h.root.path}/${photo.originalPath}',
      ).writeAsString('corrupt');
      await expectLater(
        h.repo.closeLeak(id, uuid()),
        throwsA(isA<HydrostaticException>()),
      );
    },
  );
  test(
    'approval stays durable independently of first video declaration',
    () async {
      final id = await h.passed();
      final before = h.repo.get(id)!;
      expect(before.video.state, HydrostaticVideoState.pending);
      final op = uuid();
      await h.repo.declareVideoSent(id, op);
      final declared = h.repo.get(id)!;
      h.clock.advance(100000);
      await h.reopen();
      await h.repo.declareVideoSent(id, op);
      await h.repo.declareVideoSent(id, uuid());
      expect(h.repo.get(id)!.video.declaredAt, declared.video.declaredAt);
      expect(h.repo.get(id)!.durationMs, before.durationMs);
      expect(h.repo.get(id)!.closedAt, before.closedAt);
      expect(h.network.calls, 0);
    },
  );
  test('deleting failed test removes exclusive new roles only', () async {
    final id = await h.ended();
    await h.repo.saveLeakDraft(id, uuid(), draft({'J01': '3'}));
    await h.add(id, HydrostaticEvidenceRole.leakEvidence);
    await h.repo.closeLeak(id, uuid());
    final photos = h.repo.get(id)!.evidence;
    final other = await h.prepare();
    await h.add(other, HydrostaticEvidenceRole.initialSetup);
    final unrelated = h.repo.get(other)!.evidence.single;
    await h.repo.deleteLocal(id, uuid(), confirmedTestId: id);
    for (final e in photos) {
      expect(await File('${h.root.path}/${e.originalPath}').exists(), false);
    }
    expect(await h.files.verify(unrelated), true);
  });

  for (final operation in ['draft', 'change', 'close', 'video']) {
    for (final boundary in [
      'prepared',
      'ready',
      'document',
      'indexes',
      'applied',
    ]) {
      for (final when in ['before', 'after']) {
        test(
          '$operation interruption $when:$boundary replays exact journal',
          () async {
            final id = operation == 'video'
                ? await h.passed()
                : await h.ended();
            if (operation == 'close') {
              await h.repo.saveLeakDraft(id, uuid(), draft({'J01': '3.123'}));
              await h.add(id, HydrostaticEvidenceRole.leakEvidence);
            }
            final op = uuid();
            Future<HydrostaticTest> run() => switch (operation) {
              'draft' => h.repo.saveLeakDraft(
                id,
                op,
                draft({'J01': '2,'}, observation: 'Pendiente'),
              ),
              'change' => h.repo.changeAnswer(id, op, false, confirmed: true),
              'close' => h.repo.closeLeak(id, op),
              _ => h.repo.declareVideoSent(id, op),
            };
            var hit = false;
            h.store.fault = (point) async {
              if (point == '$when:$boundary' && !hit) {
                hit = true;
                throw const FileSystemException('synthetic interruption');
              }
            };
            await expectLater(run(), throwsA(isA<FileSystemException>()));
            expect(hit, true);
            final frozen = h.repo.journal.get(op)?['after'];
            await h.reopen();
            h.clock.advance(300000);
            await h.repo.recover();
            if (operation == 'close' &&
                boundary == 'ready' &&
                when == 'after') {
              expect(
                h.repo.get(id)!.state,
                HydrostaticTestState.leakDetailsPending,
              );
              expect(
                h.repo.get(id)!.timeState,
                HydrostaticTimeState.needsReview,
              );
              expect(h.repo.get(id)!.closedAt, null);
              return;
            }
            await run();
            final t = h.repo.get(id)!;
            if (frozen != null &&
                !(boundary == 'prepared' ||
                    (boundary == 'ready' && when == 'before'))) {
              expect(t.toJson(), frozen);
            }
            final revision = t.revision;
            await run();
            expect(h.repo.get(id)!.revision, revision);
          },
        );
      }
    }
  }
}
