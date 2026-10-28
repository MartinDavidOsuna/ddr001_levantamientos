import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_approval_policy.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'package:ddr001_levantamientos/features/hydrostatic/hydrostatic_execution_pages.dart';
import 'execution_harness.dart';
import 'harness.dart';
import 'execution_widgets_test.dart' show reveal;
import 'ui_widgets_test.dart' as widgets;

void main() {
  late ExecutionHarness h;
  setUp(() async {
    h = ExecutionHarness();
    await h.open();
    h.approvalPolicy = HydrostaticApprovalPolicy.approved;
    await h.restart();
  });
  tearDown(() async => h.close());
  Future<String> ended() async {
    final id = await h.active();
    h.clock.advance(1000);
    await h.repo.finish(id, uuid());
    return id;
  }

  Future<void> tick(WidgetTester tester) async {
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await widgets.settle(tester);
  }

  widgets.localWidgetTest(
    'visible countdown ticks without journal writes and warns before expiry',
    (tester) async {
      final id = await ended();
      await widgets.open(tester, h, page: HydrostaticPendingResultPage(id: id));
      expect(
        find.text('TIEMPO RESTANTE PARA REGISTRAR RESULTADO'),
        findsOneWidget,
      );
      expect(find.text('30:00'), findsOneWidget);
      final entries = h.repo.journal.entries.length;
      h.clock.advance(1501000);
      await tick(tester);
      expect(find.text('04:59'), findsOneWidget);
      expect(find.textContaining('El plazo está por terminar'), findsOneWidget);
      expect(h.repo.journal.entries.length, entries);
      expect(h.repo.get(id)!.closedAt, null);
      await tester.pumpWidget(const SizedBox());
    },
  );
  widgets.localWidgetTest(
    'open result expires durably and offers independent new preparation',
    (tester) async {
      final id = await ended();
      await widgets.open(tester, h, page: HydrostaticPendingResultPage(id: id));
      h.clock.advance(1800001);
      await tick(tester);
      expect(h.repo.get(id)!.isDiscarded, true);
      expect(
        find.text('DESCARTADA — TIEMPO DE REGISTRO AGOTADO'),
        findsOneWidget,
      );
      await reveal(tester, find.text('INICIAR NUEVO INTENTO'));
      await tester.tap(find.text('INICIAR NUEVO INTENTO'));
      await widgets.settle(tester);
      expect(h.controller.preparations.single.id, isNot(id));
      expect(h.controller.preparations.single.attemptNumber, null);
      expect(h.repo.get(id)!.attemptNumber, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  widgets.localWidgetTest(
    'background/resume reconstructs deadline from repository',
    (tester) async {
      final id = await ended();
      await widgets.open(tester, h, page: HydrostaticPendingResultPage(id: id));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      h.clock.advance(1800001);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await widgets.settle(tester);
      expect(h.repo.get(id)!.isDiscarded, true);
      expect(
        find.text('DESCARTADA — TIEMPO DE REGISTRO AGOTADO'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  widgets.localWidgetTest(
    'failed expiry write never presents uncommitted discard as success',
    (tester) async {
      final id = await ended();
      await widgets.open(tester, h, page: HydrostaticPendingResultPage(id: id));
      h.store.fault = (p) async {
        if (p == 'before:document') {
          throw const FileSystemException('synthetic full');
        }
      };
      h.clock.advance(1800001);
      await tick(tester);
      expect(h.store.test(id)!.isDiscarded, false);
      expect(
        find.text('DESCARTADA — TIEMPO DE REGISTRO AGOTADO'),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
      h.store.fault = null;
      await h.restart();
      expect(h.repo.get(id)!.isDiscarded, true);
    },
  );
  widgets.localWidgetTest(
    'clock inconsistency shows review without fabricated countdown',
    (tester) async {
      final id = await ended();
      await widgets.open(tester, h, page: HydrostaticPendingResultPage(id: id));
      h.clock.utc = h.clock.utc.add(const Duration(hours: 1));
      await tick(tester);
      expect(h.repo.get(id)!.isDiscarded, false);
      expect(h.repo.get(id)!.timeState, HydrostaticTimeState.needsReview);
      expect(find.text('--:--'), findsOneWidget);
      expect(find.text('REVISIÓN TEMPORAL REQUERIDA'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final system in [true, false]) {
    widgets.localWidgetTest(
      'Back $system from result does not decide or expire early',
      (tester) async {
        final id = await ended();
        final before = h.repo.get(id)!.toJson();
        await widgets.open(
          tester,
          h,
          page: HydrostaticPendingResultPage(id: id),
        );
        if (system) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.pageBack();
        }
        await widgets.settle(tester);
        expect(h.repo.get(id)!.toJson(), before);
      },
    );
  }
  widgets.localWidgetTest(
    'small screen result controls remain scrollable without layout errors',
    (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final id = await ended();
      await widgets.open(tester, h, page: HydrostaticPendingResultPage(id: id));
      await reveal(tester, find.widgetWithText(FilledButton, 'SÍ'));
      await tester.tap(find.widgetWithText(FilledButton, 'SÍ'));
      await widgets.settle(tester);
      expect(h.repo.get(id)!.state, HydrostaticTestState.leakDetailsPending);
      await reveal(tester, find.byKey(const Key('joint_J11')));
      await tester.tap(find.byKey(const Key('joint_J11')));
      await widgets.settle(tester);
      await reveal(tester, find.byKey(const Key('other_description')));
      await tester.enterText(
        find.byKey(const Key('other_description')),
        'Unión sintética con descripción larga para verificar desplazamiento',
      );
      await widgets.settle(tester);
      expect(tester.takeException(), null);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
