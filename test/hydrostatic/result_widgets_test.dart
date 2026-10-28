import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'package:ddr001_levantamientos/features/hydrostatic/hydrostatic_execution_pages.dart';
import 'execution_harness.dart';
import 'execution_widgets_test.dart' show reveal;
import 'ui_widgets_test.dart' as widgets;

void main() {
  late ExecutionHarness h;
  setUp(() async {
    h = ExecutionHarness();
    await h.open();
    h.picker.distinctBytes = true;
  });
  tearDown(() async => h.close());

  widgets.localWidgetTest(
    'yes, incremental multiple leaks, real synthetic capture and FAILED',
    (tester) async {
      final id = await h.ready();
      await h.controller.start(id);
      h.clock.advance(10000);
      await h.controller.finish(id);
      await widgets.open(tester, h, page: HydrostaticPendingResultPage(id: id));
      await tester.tap(find.text('SÍ'));
      await widgets.settle(tester);
      expect(h.repo.get(id)!.state, HydrostaticTestState.leakDetailsPending);
      await reveal(tester, find.byKey(const Key('joint_J01')));
      await tester.tap(find.byKey(const Key('joint_J01')));
      await widgets.settle(tester);
      await reveal(tester, find.byKey(const Key('pressure_J01')));
      await tester.enterText(find.byKey(const Key('pressure_J01')), '2,125');
      await widgets.settle(tester);
      expect(h.repo.get(id)!.leaks.single.pressureMilliBar, 2125);
      await reveal(tester, find.byKey(const Key('joint_J11')));
      await tester.tap(find.byKey(const Key('joint_J11')));
      await widgets.settle(tester);
      await reveal(tester, find.byKey(const Key('pressure_J11')));
      await tester.enterText(find.byKey(const Key('pressure_J11')), '4');
      await widgets.settle(tester);
      await reveal(tester, find.byKey(const Key('other_description')));
      await tester.enterText(
        find.byKey(const Key('other_description')),
        'Unión de prueba',
      );
      await widgets.settle(tester);
      await reveal(tester, find.text('TOMAR FOTO DE FUGA'));
      await tester.tap(find.text('TOMAR FOTO DE FUGA'));
      await widgets.settle(tester);
      expect(h.repo.get(id)!.evidence.last.ready, true);
      await reveal(tester, find.text('GUARDAR RESULTADO'));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'GUARDAR RESULTADO'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('GUARDAR RESULTADO'));
      await widgets.settle(tester);
      expect(h.repo.get(id)!.state, HydrostaticTestState.failed);
      expect(h.repo.get(id)!.leaks.length, 2);
    },
  );

  widgets.localWidgetTest(
    'NO, final photo, approval then explicit independent video confirmation',
    (tester) async {
      final id = await h.ready();
      await h.controller.start(id);
      h.clock.advance(10000);
      await h.controller.capturePhoto(
        id,
        HydrostaticEvidenceRole.manometer5Bar,
      );
      await h.controller.finish(id);
      await widgets.open(tester, h, page: HydrostaticPendingResultPage(id: id));
      await tester.tap(find.text('NO'));
      await widgets.settle(tester);
      expect(
        h.repo.get(id)!.state,
        HydrostaticTestState.approvalEvidencePending,
      );
      expect(find.text('TOMAR FOTO A 5 BAR'), findsNothing);
      await reveal(tester, find.text('TOMAR FOTO A 4 BAR'));
      await tester.tap(find.text('TOMAR FOTO A 4 BAR'));
      await widgets.settle(tester);
      await reveal(tester, find.text('GUARDAR APROBACIÓN'));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'GUARDAR APROBACIÓN'),
            )
            .onPressed,
        isNotNull,
      );
      // A countdown tick must not put an unchanged, completed validation back
      // into waiting. Real multi-megabyte camera originals can exceed a tick.
      await tester.pump(const Duration(seconds: 1));
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'GUARDAR APROBACIÓN'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.text('GUARDAR APROBACIÓN'));
      await widgets.settle(tester);
      expect(h.repo.get(id)!.state, HydrostaticTestState.passed);
      expect(h.repo.get(id)!.video.state, HydrostaticVideoState.pending);
      await reveal(tester, find.widgetWithText(FilledButton, 'VIDEO ENVIADO'));
      await tester.tap(find.widgetWithText(FilledButton, 'VIDEO ENVIADO'));
      await widgets.settle(tester);
      await tester.tap(find.text('CANCELAR'));
      await widgets.settle(tester);
      expect(h.repo.get(id)!.video.state, HydrostaticVideoState.pending);
      await tester.tap(find.widgetWithText(FilledButton, 'VIDEO ENVIADO'));
      await widgets.settle(tester);
      await tester.tap(find.text('CONFIRMAR'));
      await widgets.settle(tester);
      expect(h.repo.get(id)!.video.state, HydrostaticVideoState.declaredSent);
      expect(h.network.calls, 0);
    },
  );

  for (final system in [true, false]) {
    widgets.localWidgetTest(
      'draft Back $system persists incomplete pressure without closing',
      (tester) async {
        final id = await h.ended();
        await widgets.open(
          tester,
          h,
          page: HydrostaticPendingResultPage(id: id),
        );
        await reveal(tester, find.byKey(const Key('joint_J01')));
        await tester.tap(find.byKey(const Key('joint_J01')));
        await widgets.settle(tester);
        await reveal(tester, find.byKey(const Key('pressure_J01')));
        await tester.enterText(find.byKey(const Key('pressure_J01')), '2,');
        if (system) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.pageBack();
        }
        await widgets.settle(tester);
        expect(h.repo.get(id)!.state, HydrostaticTestState.leakDetailsPending);
        expect(
          h.repo.get(id)!.toJson()['leakDraft']['joints']['J01']['pressure'],
          '2,',
        );
        await tester.pumpWidget(const SizedBox());
        await h.restart();
        await widgets.open(
          tester,
          h,
          page: HydrostaticPendingResultPage(id: id),
        );
        await reveal(tester, find.byKey(const Key('pressure_J01')));
        expect(
          tester
              .widget<TextFormField>(find.byKey(const Key('pressure_J01')))
              .initialValue,
          '2,',
        );
      },
    );
  }

  widgets.localWidgetTest('change answer asks confirmation and keeps draft', (
    tester,
  ) async {
    final id = await h.ended();
    await widgets.open(tester, h, page: HydrostaticPendingResultPage(id: id));
    await tester.tap(find.text('CAMBIAR RESPUESTA'));
    await widgets.settle(tester);
    await tester.tap(find.text('CANCELAR'));
    await widgets.settle(tester);
    expect(h.repo.get(id)!.hadLeaks, true);
    await tester.tap(find.text('CAMBIAR RESPUESTA'));
    await widgets.settle(tester);
    await tester.tap(find.text('CONFIRMAR'));
    await widgets.settle(tester);
    expect(h.repo.get(id)!.hadLeaks, false);
  });
}
