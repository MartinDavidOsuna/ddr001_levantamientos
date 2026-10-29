import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_repository.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'package:ddr001_levantamientos/features/hydrostatic/hydrostatic_execution_pages.dart';
import 'execution_harness.dart';
import 'harness.dart';
import 'execution_widgets_test.dart' show reveal;
import 'ui_widgets_test.dart' as widgets;

class GatedFiles extends LocalHydrostaticEvidenceFiles {
  GatedFiles(super.root);
  Completer<void>? gate;
  int calls = 0;
  @override
  Future<bool> verify(HydrostaticEvidence e) async {
    calls++;
    final pending = gate;
    if (pending != null) await pending.future;
    return super.verify(e);
  }
}

void main() {
  late ExecutionHarness h;
  late GatedFiles files;
  setUp(() async {
    h = ExecutionHarness();
    await h.open();
    files = GatedFiles(h.root);
    h.files = files;
    h.repo = HydrostaticRepository(
      store: h.store,
      clock: h.clock,
      access: () => h.access,
      files: files,
      approvalPolicy: h.approvalPolicy,
    );
    h.wire();
  });
  tearDown(() async => h.close());

  Future<String> pending({bool large = false}) async {
    h.picker.distinctBytes = true;
    final id = await h.ready();
    await h.controller.start(id);
    h.clock.advance(1000);
    await h.controller.capturePhoto(id, HydrostaticEvidenceRole.manometer5Bar);
    await h.controller.finish(id);
    await h.controller.resultAction(id, 'answer', yes: false);
    h.picker.paddingBytes = large ? 4 * 1024 * 1024 : 0;
    await h.controller.capturePhoto(id, HydrostaticEvidenceRole.final4Bar);
    h.picker.paddingBytes = 0;
    await h.controller.initialize();
    return id;
  }

  widgets.localWidgetTest(
    'large originals and multiple ticks retain one pending validation',
    (tester) async {
      final id = await pending(large: true);
      files.gate = Completer<void>();
      await widgets.open(tester, h, page: HydrostaticPendingResultPage(id: id));
      await reveal(tester, find.text('GUARDAR APROBACIÓN'));
      final calls = files.calls;
      // These widget tests use runAsync for real Hive I/O, so allow real Timer
      // ticks as well as pumping frames (fake pump time alone is insufficient).
      for (var i = 0; i < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        await tester.pump();
      }
      expect(
        files.calls,
        calls,
        reason: 'A tick must not restart SHA-256 reads',
      );
      files.gate!.complete();
      files.gate = null;
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'GUARDAR APROBACIÓN'),
                )
                .onPressed !=
            null) {
          break;
        }
      }
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'GUARDAR APROBACIÓN'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  widgets.localWidgetTest(
    'file change after prevalidation is rejected at closure and can be rechecked',
    (tester) async {
      final id = await pending();
      await widgets.open(tester, h, page: HydrostaticPendingResultPage(id: id));
      await reveal(tester, find.text('GUARDAR APROBACIÓN'));
      final photo = h.repo.get(id)!.evidence.last;
      final file = File('${h.root.path}/${photo.originalPath}');
      final original = await file.readAsBytes();
      await file.writeAsBytes([0, 1], flush: true);
      await tester.tap(find.text('GUARDAR APROBACIÓN'));
      await widgets.settle(tester);
      expect(
        h.repo.get(id)!.state,
        HydrostaticTestState.approvalEvidencePending,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'GUARDAR APROBACIÓN'),
            )
            .onPressed,
        isNull,
      );
      await file.writeAsBytes(original, flush: true);
      await reveal(tester, find.text('REVALIDAR EVIDENCIAS'));
      await tester.tap(find.text('REVALIDAR EVIDENCIAS'));
      await widgets.settle(tester);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'GUARDAR APROBACIÓN'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  widgets.localWidgetTest(
    'new evidence supersedes an in-flight obsolete validation',
    (tester) async {
      final id = await pending();
      final oldPhoto = h.repo.get(id)!.evidence.last;
      final gate = Completer<void>();
      files.gate = gate;
      await widgets.open(tester, h, page: HydrostaticPendingResultPage(id: id));
      await reveal(tester, find.text('GUARDAR APROBACIÓN'));
      files.gate = null;
      await File('${h.root.path}/${oldPhoto.originalPath}').delete();
      h.clock.advance(1000);
      await h.add(id, HydrostaticEvidenceRole.final4Bar);
      await h.controller.initialize();
      await widgets.settle(tester);
      gate.complete();
      await widgets.settle(tester);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'GUARDAR APROBACIÓN'),
            )
            .onPressed,
        isNotNull,
      );
      expect(h.repo.get(id)!.evidence.length, 4);
    },
  );

  test(
    'evidence revision and recovered aggregate invalidate prevalidation',
    () async {
      final id = await pending();
      expect(await h.controller.closureIssue(id), isNull);
      final before = h.controller.evidenceValidationRevision;
      h.clock.advance(1000);
      await h.add(id, HydrostaticEvidenceRole.final4Bar);
      final revision = h.repo.get(id)!.revision;
      await h.controller.initialize();
      expect(h.controller.evidenceValidationRevision, greaterThan(before));
      expect(h.repo.get(id)!.revision, revision);
      expect(h.repo.get(id)!.evidence.length, 4);
      expect(await h.controller.closureIssue(id), isNull);
    },
  );

  test('session revocation during hashing cannot commit pass', () async {
    final id = await pending();
    files.gate = Completer<void>();
    final close = h.repo.closePass(id, uuid());
    final rejection = expectLater(close, throwsA(isA<HydrostaticException>()));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    h.access = HydrostaticAccess(
      actor: h.access.actor,
      authorized: false,
      fieldSession: true,
    );
    h.changes.notifyListeners();
    files.gate!.complete();
    files.gate = null;
    await rejection;
    expect(
      h.store.test(id)!.state,
      HydrostaticTestState.approvalEvidencePending,
    );
  });

  test('expiry during hashing cannot commit pass', () async {
    final id = await pending();
    files.gate = Completer<void>();
    final close = h.repo.closePass(id, uuid());
    final rejection = expectLater(close, throwsA(isA<HydrostaticException>()));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    h.clock.advance(31 * 60000);
    files.gate!.complete();
    files.gate = null;
    await rejection;
    expect(h.repo.get(id)!.state, HydrostaticTestState.approvalEvidencePending);
    expect(h.repo.get(id)!.result, HydrostaticResult.pending);
  });

  test(
    'storage recovery blocks prevalidation until durable recovery',
    () async {
      final id = await pending();
      expect(await h.controller.closureIssue(id), isNull);
      h.store.recoveryRequired = true;
      expect(await h.controller.closureIssue(id), contains('RECOVERY_PENDING'));
      await h.controller.initialize();
      expect(h.controller.ready, true);
      expect(await h.controller.closureIssue(id), isNull);
    },
  );

  test('late final photo does not authorize retrospective approval', () async {
    final id = await h.ended(yes: false);
    h.clock.advance(31 * 60000);
    await h.add(id, HydrostaticEvidenceRole.final4Bar);
    await expectLater(
      h.repo.closePass(id, uuid()),
      throwsA(isA<HydrostaticException>()),
    );
    expect(h.repo.get(id)!.closedAt, isNull);
  });
}
