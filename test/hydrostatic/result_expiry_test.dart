import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_approval_policy.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'execution_harness.dart';
import 'harness.dart';

void main() {
  late ExecutionHarness h;
  setUp(() async {
    h = ExecutionHarness();
    await h.open();
    h.approvalPolicy = HydrostaticApprovalPolicy.approved;
    await h.restart();
  });
  tearDown(() async => h.close());
  test('late durable close candidate never becomes approved', () async {
    final id = await h.ended(yes: false);
    await h.add(id, HydrostaticEvidenceRole.final4Bar);
    h.clock.advance(1799999);
    h.store.fault = (point) async {
      if (point == 'before:ready') h.clock.advance(2);
    };
    await expectLater(
      h.repo.closePass(id, uuid()),
      throwsA(isA<HydrostaticException>()),
    );
    h.store.fault = null;
    await h.restart();
    expect(h.repo.get(id)!.state, isNot(HydrostaticTestState.passed));
  });
  for (final point in ['after:ready', 'after:document']) {
    test('discard recovery $point retains exact deadline and files', () async {
      final id = await h.ended();
      h.clock.advance(1800001);
      final deadline = h.repo
          .get(id)!
          .endedAt!
          .add(const Duration(minutes: 30));
      h.store.fault = (p) async {
        if (p == point) {
          throw const FileSystemException('synthetic interruption');
        }
      };
      await expectLater(
        h.repo.discardExpired(id, uuid()),
        throwsA(isA<FileSystemException>()),
      );
      await h.restart();
      expect(h.repo.get(id)!.discardedAt, deadline);
      expect(await h.files.verify(h.repo.get(id)!.evidence.single), true);
    });
  }
  test(
    'startup persists expired discard without touching evidence or attempt',
    () async {
      final id = await h.ended();
      final initial = h.repo.get(id)!;
      h.clock.advance(1800001);
      await h.restart();
      final t = h.repo.get(id)!;
      expect(t.isDiscarded, true);
      expect(t.result, HydrostaticResult.pending);
      expect(t.attemptNumber, initial.attemptNumber);
      expect(t.durationMs, initial.durationMs);
      expect(await h.files.verify(t.evidence.single), true);
      await expectLater(
        h.controller.capturePhoto(id, HydrostaticEvidenceRole.leakEvidence),
        throwsA(isA<HydrostaticException>()),
      );
    },
  );
  test(
    'manual clock change after execution blocks closure and never silently approves',
    () async {
      final id = await h.ended(yes: false);
      await h.add(id, HydrostaticEvidenceRole.final4Bar);
      h.clock.utc = h.clock.utc.add(const Duration(days: 1));
      expect(
        h.repo.resultExpired(h.repo.get(id)!),
        false,
      ); // monotonic deadline
      await expectLater(
        h.repo.closePass(id, uuid()),
        throwsA(
          isA<HydrostaticException>().having(
            (e) => e.code,
            'code',
            'CLOCK_REVIEW_REQUIRED',
          ),
        ),
      );
    },
  );
  test(
    'clock rollback preserves review rather than inventing expiry',
    () async {
      final id = await h.ended();
      h.clock.advance(1800001);
      h.clock.utc = h.clock.utc.subtract(const Duration(hours: 1));
      expect(h.repo.resultExpired(h.repo.get(id)!), false);
      await h.repo.reviewClock(id, uuid());
      expect(h.repo.get(id)!.timeState, HydrostaticTimeState.needsReview);
      expect(h.repo.get(id)!.isDiscarded, false);
    },
  );
}
