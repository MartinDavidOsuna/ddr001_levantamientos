import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'package:ddr001_levantamientos/features/hydrostatic/hydrostatic_execution_pages.dart';
import 'package:ddr001_levantamientos/features/hydrostatic/hydrostatic_pages.dart';
import 'execution_harness.dart';
import 'ui_widgets_test.dart' as widgets;

Future<void> reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
    );
  } else {
    await tester.ensureVisible(target);
  }
  await widgets.settle(tester);
}

void main() {
  late ExecutionHarness h;
  setUp(() async {
    h = ExecutionHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  widgets.localWidgetTest(
    'capture initial, GPS start, capture 5 bar and finish pending with enabled answers',
    (tester) async {
      await widgets.open(tester, h);
      await widgets.manual(tester);
      final id = h.controller.preparations.single.id;
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('hydro_start')))
            .onPressed,
        isNull,
      );
      await reveal(tester, find.text('TOMAR FOTO'));
      await tester.tap(find.text('TOMAR FOTO'));
      await widgets.settle(tester);
      expect(h.repo.get(id)!.evidence.single.ready, isTrue);
      await reveal(tester, find.byKey(const Key('hydro_start')));
      await widgets.settle(tester);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('hydro_start')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('hydro_start')));
      await widgets.settle(tester);
      expect(find.text('PRUEBA HIDROSTÁTICA EN CURSO'), findsOneWidget);
      expect(find.byKey(const Key('hydro_clock')), findsOneWidget);
      expect(h.repo.get(id)!.state, HydrostaticTestState.active);
      h.clock.advance(15000);
      await tester.pump(const Duration(seconds: 1));
      await reveal(tester, find.text('TOMAR FOTO A 5 BAR'));
      await tester.tap(find.text('TOMAR FOTO A 5 BAR'));
      await widgets.settle(tester);
      expect(
        h.repo.get(id)!.evidence.last.role,
        HydrostaticEvidenceRole.manometer5Bar,
      );
      await reveal(tester, find.text('TERMINAR PRUEBA'));
      await tester.tap(find.text('TERMINAR PRUEBA'));
      await widgets.settle(tester);
      expect(find.text('¿SE REGISTRARON FUGAS?'), findsOneWidget);
      for (final answer in ['SÍ', 'NO']) {
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, answer))
              .onPressed,
          isNotNull,
        );
      }
      expect(h.repo.get(id)!.state, HydrostaticTestState.endedPendingResult);
      expect(h.repo.get(id)!.hadLeaks, isNull);
      expect(find.text('APROBADO'), findsNothing);
      final end = h.repo.get(id)!.endedAt;
      await tester.tap(find.text('VOLVER A LA LISTA'));
      await widgets.settle(tester);
      await tester.tap(find.text('COMPLETAR RESULTADO'));
      await widgets.settle(tester);
      expect(h.repo.get(id)!.endedAt, end);
      expect(find.text('¿SE REGISTRARON FUGAS?'), findsOneWidget);
    },
  );
  for (final systemBack in [true, false]) {
    widgets.localWidgetTest(
      'back ${systemBack ? 'system' : 'AppBar'} confirms, preserves ACTIVE and resumes same UUID',
      (tester) async {
        final id = await h.ready();
        await h.controller.start(id);
        final initial = h.repo.get(id)!.startedAt;
        await widgets.open(tester, h);
        await tester.tap(find.text('PRUEBA EN CURSO — REANUDAR'));
        await widgets.settle(tester);
        if (systemBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.pageBack();
        }
        await widgets.settle(tester);
        expect(find.text('HAY UNA PRUEBA EN CURSO'), findsOneWidget);
        await tester.tap(find.text('CONTINUAR PRUEBA'));
        await widgets.settle(tester);
        expect(find.text('PRUEBA HIDROSTÁTICA EN CURSO'), findsOneWidget);
        await tester.binding.handlePopRoute();
        await widgets.settle(tester);
        await tester.tap(find.text('SALIR Y CONSERVAR'));
        await widgets.settle(tester);
        expect(find.text('PRUEBAS HIDROSTÁTICAS'), findsOneWidget);
        h.clock.advance(2000);
        await tester.tap(find.text('PRUEBA EN CURSO — REANUDAR'));
        await widgets.settle(tester);
        expect(h.repo.get(id)!.startedAt, initial);
        expect(h.repo.get(id)!.attemptNumber, 1);
        expect(h.repo.get(id)!.state, HydrostaticTestState.active);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  widgets.localWidgetTest(
    'pause resume and reconstruction show elapsed without per-second writes',
    (tester) async {
      final id = await h.ready();
      await h.controller.start(id);
      await widgets.open(tester, h, page: HydrostaticExecutionPage(id: id));
      final revision = h.repo.get(id)!.revision,
          journal = h.repo.journal.entries.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      h.clock.advance(25 * 3600 * 1000 + 5000);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await widgets.settle(tester);
      expect(find.text('25:00:05'), findsOneWidget);
      expect(h.repo.get(id)!.revision, revision);
      expect(h.repo.journal.entries.length, journal);
      await tester.pumpWidget(const SizedBox());
      await h.restart();
      await widgets.open(tester, h, page: HydrostaticExecutionPage(id: id));
      expect(find.textContaining('Duración reconstruida'), findsOneWidget);
      h.clock.utc = h.clock.utc.subtract(const Duration(days: 2));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await tester.pump();
      expect(
        find.textContaining('ADVERTENCIA: cambio de reloj'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  widgets.localWidgetTest(
    'GPS failure conserves preparation and shows error, retry enables same attempt',
    (tester) async {
      final id = await h.ready();
      h.gps.error = StateError('Permiso GPS denegado');
      await widgets.open(tester, h, page: HydrostaticPreparationPage(id: id));
      await reveal(tester, find.byKey(const Key('hydro_start')));
      await tester.tap(find.byKey(const Key('hydro_start')));
      await widgets.settle(tester);
      expect(find.textContaining('Permiso GPS denegado'), findsOneWidget);
      expect(h.repo.get(id)!.state, HydrostaticTestState.preparation);
      expect(h.repo.get(id)!.evidence.length, 1);
      h.gps.error = null;
      await tester.tap(find.byKey(const Key('hydro_start')));
      await widgets.settle(tester);
      expect(h.repo.get(id)!.attemptNumber, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  widgets.localWidgetTest(
    'session revoked on execution hides photos clock and controls',
    (tester) async {
      final id = await h.ready();
      await h.controller.start(id);
      await widgets.open(tester, h, page: HydrostaticExecutionPage(id: id));
      h.access = HydrostaticAccess(
        actor: h.access.actor,
        authorized: false,
        fieldSession: true,
      );
      h.changes.notifyListeners();
      await widgets.settle(tester);
      expect(find.byKey(const Key('hydro_clock')), findsNothing);
      expect(find.text('TERMINAR PRUEBA'), findsNothing);
      expect(find.textContaining('Sesión sin autorización'), findsOneWidget);
      expect(h.store.test(id)!.state, HydrostaticTestState.active);
    },
  );
}
