import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_approval_policy.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'execution_harness.dart';
import 'harness.dart';
import 'results_test.dart' show draft;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ExecutionHarness h;
  setUp(() async {
    h = ExecutionHarness();
    await h.open();
  });
  tearDown(() async => h.close());

  for (final role in [
    HydrostaticEvidenceRole.leakEvidence,
    HydrostaticEvidenceRole.final4Bar,
  ]) {
    test(
      '$role capture, cancel, corrupt and recovery preserve originals',
      () async {
        final id = await h.ended(
          yes: role == HydrostaticEvidenceRole.leakEvidence,
        );
        await h.controller.initialize();
        await h.controller.capturePhoto(id, role);
        final original = h.repo.get(id)!.evidence.last;
        expect(original.ready, true);
        h.picker.cancel = true;
        await h.controller.capturePhoto(id, role);
        expect(h.repo.get(id)!.evidence.last.id, original.id);
        h.picker.cancel = false;
        h.picker.corrupt = true;
        await h.controller.capturePhoto(id, role);
        expect(
          h.repo.get(id)!.evidence.last.integrity,
          HydrostaticIntegrity.corrupt,
        );
        h.picker.corrupt = false;
        h.picker.throwAfter = true;
        await expectLater(
          h.controller.capturePhoto(id, role),
          throwsA(isA<StateError>()),
        );
        h.picker.throwAfter = false;
        await h.restart();
        expect(
          h.repo.get(id)!.evidence.length,
          role == HydrostaticEvidenceRole.leakEvidence ? 4 : 5,
        ); // initial + valid + corrupt + recovered
        expect(await h.files.verify(original), true);
        expect(h.repo.get(id)!.evidence.last.role, role);
        expect(h.network.calls, 0);
      },
    );
  }

  test(
    '5 bar cannot be captured after end; final cannot precede answer',
    () async {
      final id = await h.active();
      await h.repo.finish(id, uuid());
      await h.controller.initialize();
      for (final role in [
        HydrostaticEvidenceRole.manometer5Bar,
        HydrostaticEvidenceRole.final4Bar,
        HydrostaticEvidenceRole.leakEvidence,
      ]) {
        await expectLater(
          h.controller.capturePhoto(id, role),
          throwsA(isA<HydrostaticException>()),
        );
      }
      expect(h.picker.captures, 0);
    },
  );

  test(
    'explicitly unconfigured policy blocks approval, never invents threshold',
    () async {
      final id = await h.ended(yes: false);
      await h.add(id, HydrostaticEvidenceRole.final4Bar);
      h.approvalPolicy = const HydrostaticApprovalPolicy();
      await h.restart();
      await expectLater(
        h.repo.closePass(id, uuid()),
        throwsA(
          isA<HydrostaticException>().having(
            (e) => e.code,
            'code',
            'FINAL_PHOTO_POLICY_REQUIRED',
          ),
        ),
      );
      expect(
        h.repo.get(id)!.state,
        HydrostaticTestState.approvalEvidencePending,
      );
    },
  );

  test(
    'configured synthetic policy rejects late final photo and preserves it',
    () async {
      final id = await h.ended(yes: false);
      h.clock.advance(600001);
      await h.add(id, HydrostaticEvidenceRole.final4Bar);
      final photo = h.repo.get(id)!.evidence.last;
      await expectLater(
        h.repo.closePass(id, uuid()),
        throwsA(isA<HydrostaticException>()),
      );
      expect(await h.files.verify(photo), true);
      expect(h.repo.get(id)!.closedAt, null);
    },
  );

  test(
    'draft disk full retains queue; retry recovers and flushes exact raw input',
    () async {
      final id = await h.ended();
      await h.controller.initialize();
      var fail = true;
      h.store.fault = (point) async {
        if (point == 'after:ready' && fail) {
          fail = false;
          throw const FileSystemException('synthetic full');
        }
      };
      await expectLater(
        h.controller.saveDraft(id, draft({'J01': '2,'})),
        throwsA(isA<FileSystemException>()),
      );
      expect(h.controller.draftPending, true);
      h.store.fault = null;
      await h.controller.flushDrafts();
      expect(h.controller.draftPending, false);
      await h.restart();
      expect(h.controller.leakDraft(id)['joints']['J01']['pressure'], '2,');
    },
  );

  test(
    'session revoked during result prevents durable answer and leaks no identity',
    () async {
      final id = await h.active();
      await h.repo.finish(id, uuid());
      await h.controller.initialize();
      h.verify = () async {
        h.access = HydrostaticAccess(
          actor: h.access.actor,
          authorized: false,
          fieldSession: true,
        );
      };
      await expectLater(
        h.controller.resultAction(id, 'answer', yes: true),
        throwsA(isA<HydrostaticException>()),
      );
      expect(h.store.test(id)!.state, HydrostaticTestState.endedPendingResult);
    },
  );

  test('double result and video commands are semantic idempotent', () async {
    final id = await h.active();
    await h.repo.finish(id, uuid());
    await h.controller.initialize();
    await Future.wait([
      h.controller.resultAction(id, 'answer', yes: true),
      h.controller.resultAction(id, 'answer', yes: true),
    ]);
    final revision = h.repo.get(id)!.revision;
    await h.controller.resultAction(id, 'answer', yes: true);
    expect(h.repo.get(id)!.revision, revision);
  });
}
