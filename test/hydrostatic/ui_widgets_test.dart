import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'package:ddr001_levantamientos/features/hydrostatic/hydrostatic_pages.dart';
import 'package:ddr001_levantamientos/features/hydrostatic/hydrostatic_scanner.dart';
import 'harness.dart';
import 'ui_harness.dart';

void localWidgetTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    await tester.runAsync(() => body(tester));
  });
}

Future<void> settle(WidgetTester tester) async {
  // Wait for actual I/O and visual idle, not a fixed 50 ms disk assumption.
  // The enclosing runAsync allows Hive flushes to finish even under suite load.
  var stable = 0;
  for (var n = 0; n < 1000; n++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 20));
    final loading =
        find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
        find.byType(LinearProgressIndicator).evaluate().isNotEmpty;
    if (!loading && !tester.binding.hasScheduledFrame) {
      stable++;
    } else {
      stable = 0;
    }
    if (stable >= 3) return;
  }
  fail('UI did not reach durable/visual idle within 10 seconds.');
}

Widget host(UiHarness h, {Widget page = const HydrostaticListPage()}) =>
    ChangeNotifierProvider.value(
      value: h.controller,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  settings: RouteSettings(
                    name: page is HydrostaticListPage
                        ? 'hydrostatic-list'
                        : null,
                  ),
                  builder: (_) => page,
                ),
              ),
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    );
Future<void> open(
  WidgetTester tester,
  UiHarness h, {
  Widget page = const HydrostaticListPage(),
}) async {
  await tester.pumpWidget(host(h, page: page));
  await tester.tap(find.text('OPEN'));
  await settle(tester);
}

Future<void> manual(WidgetTester tester) async {
  await tester.tap(find.text('NUEVA PRUEBA'));
  await settle(tester);
  await tester.enterText(find.byKey(const Key('hydro_uid')), 'AQ26-00001-7');
  await tester.tap(find.text('BUSCAR GABINETE'));
  await settle(tester);
}

void main() {
  late UiHarness h;
  setUp(() async {
    h = UiHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  localWidgetTest(
    'empty list, manual identify, disabled start, cancel, recover same durable preparation',
    (tester) async {
      await open(tester, h);
      expect(
        find.text('Aún no hay pruebas hidrostáticas registradas.'),
        findsOneWidget,
      );
      await manual(tester);
      expect(find.text('PRUEBA HIDROSTÁTICA'), findsOneWidget);
      expect(find.text('Prueba #1 provisional'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('hydro_start')))
            .onPressed,
        isNull,
      );
      expect(
        find.textContaining('Esta función se habilitará próximamente'),
        findsOneWidget,
      );
      final id = h.controller.preparations.single.id;
      await tester.ensureVisible(find.text('CANCELAR'));
      await settle(tester);
      await tester.tap(find.text('CANCELAR'));
      await settle(tester);
      expect(find.text('PREPARACIONES GUARDADAS'), findsOneWidget);
      expect(
        find.text('Aún no hay pruebas hidrostáticas registradas.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(ValueKey('preparation_$id')));
      await settle(tester);
      expect(find.text('Prueba #1 provisional'), findsOneWidget);
      await tester.pageBack();
      await settle(tester);
      expect(h.repo.get(id)!.state, HydrostaticTestState.preparation);
      expect(h.repo.sequences.last('AQ26000017'), 0);
    },
  );
  localWidgetTest('system back and rebuilt widgets preserve preparation', (
    tester,
  ) async {
    await open(tester, h);
    await manual(tester);
    final id = h.controller.preparations.single.id;
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('PREPARACIONES GUARDADAS'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await open(tester, h, page: HydrostaticPreparationPage(id: id));
    expect(find.text('PRUEBA HIDROSTÁTICA'), findsOneWidget);
    expect(h.repo.get(id)!.attemptNumber, isNull);
  });
  localWidgetTest(
    'no local cabinet reports explicit message without preparation',
    (tester) async {
      h.records = [];
      await open(tester, h);
      await manual(tester);
      expect(
        find.textContaining(
          'Este gabinete no está disponible en este dispositivo',
        ),
        findsOneWidget,
      );
      expect(h.store.all(), isEmpty);
    },
  );
  localWidgetTest('invalid QR/manual input stays on identification', (
    tester,
  ) async {
    await open(tester, h, page: const HydrostaticIdentifyPage());
    await tester.enterText(find.byKey(const Key('hydro_uid')), 'AQ26-00001-8');
    await tester.tap(find.text('BUSCAR GABINETE'));
    await settle(tester);
    expect(find.textContaining('verificador'), findsOneWidget);
    expect(h.store.all(), isEmpty);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('OPEN'), findsOneWidget);
  });
  localWidgetTest(
    'double button press creates only one preparation and route',
    (tester) async {
      await open(tester, h, page: const HydrostaticIdentifyPage());
      await tester.enterText(find.byKey(const Key('hydro_uid')), 'AQ26000017');
      await tester.tap(find.text('BUSCAR GABINETE'));
      await tester.tap(find.text('BUSCAR GABINETE'));
      await settle(tester);
      expect(find.text('PRUEBA HIDROSTÁTICA'), findsOneWidget);
      expect(h.store.all().length, 1);
    },
  );
  localWidgetTest('QR repeated reads return once and identify locally', (
    tester,
  ) async {
    await open(
      tester,
      h,
      page: HydrostaticIdentifyPage(
        scannerBuilder: (_) => HydrostaticScannerPage(
          surface: (context, onRead) => TextButton(
            onPressed: () {
              onRead('https://id.aquafim.com/ddr001/AQ26000017');
              onRead('AQ26000017');
            },
            child: const Text('SYNTHETIC QR'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ESCANEAR QR'));
    await settle(tester);
    await tester.tap(find.text('SYNTHETIC QR'));
    await settle(tester);
    expect(find.text('PRUEBA HIDROSTÁTICA'), findsOneWidget);
    expect(h.store.all().length, 1);
  });
  localWidgetTest('scanner invalid read and cancellation never write', (
    tester,
  ) async {
    await open(
      tester,
      h,
      page: HydrostaticIdentifyPage(
        scannerBuilder: (_) => HydrostaticScannerPage(
          surface: (context, onRead) => TextButton(
            onPressed: () => onRead('https://evil.example/AQ26000017'),
            child: const Text('INVALID QR'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('ESCANEAR QR'));
    await settle(tester);
    await tester.tap(find.text('INVALID QR'));
    await settle(tester);
    expect(find.textContaining('QR no pertenece'), findsOneWidget);
    await tester.tap(find.text('CANCELAR ESCANEO'));
    await settle(tester);
    expect(find.text('IDENTIFICAR GABINETE'), findsOneWidget);
    expect(h.store.all(), isEmpty);
  });
  localWidgetTest('scanner system back returns to identification', (
    tester,
  ) async {
    await open(
      tester,
      h,
      page: HydrostaticIdentifyPage(
        scannerBuilder: (_) => HydrostaticScannerPage(
          surface: (context, onRead) => const Text('FAKE CAMERA'),
        ),
      ),
    );
    await tester.tap(find.text('ESCANEAR QR'));
    await settle(tester);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(find.text('IDENTIFICAR GABINETE'), findsOneWidget);
    expect(h.store.all(), isEmpty);
  });
  localWidgetTest('direct unauthorized route hides dossier', (tester) async {
    final id = await h.prepare();
    h.access = HydrostaticAccess(
      actor: h.access.actor,
      authorized: false,
      fieldSession: true,
    );
    await open(tester, h, page: HydrostaticPreparationPage(id: id));
    expect(find.textContaining('Sesión sin autorización'), findsOneWidget);
    expect(find.textContaining('SYNTHETIC OPERATOR'), findsNothing);
    expect(find.textContaining('AQ26-00001-7'), findsNothing);
  });
  localWidgetTest(
    'session change hides current and stacked routes without deleting',
    (tester) async {
      await open(tester, h);
      await manual(tester);
      final original = h.controller.preparations.single;
      h.access = HydrostaticAccess(
        actor: HydrostaticActorSnapshot(
          userId: uuid(),
          name: 'NEW USER',
          sessionId: uuid(),
          deviceInstallationId: uuid(),
        ),
        authorized: true,
        fieldSession: true,
      );
      h.changes.notifyListeners();
      await settle(tester);
      expect(find.textContaining('Sesión sin autorización'), findsOneWidget);
      expect(find.text('SYNTHETIC OPERATOR'), findsNothing);
      await tester.pageBack();
      await settle(tester);
      expect(find.textContaining('Sesión sin autorización'), findsOneWidget);
      expect(h.store.test(original.id)!.actor.userId, original.actor.userId);
    },
  );
  localWidgetTest('resume verifies session and blocks data', (tester) async {
    await open(tester, h);
    await manual(tester);
    h.verify = () async {
      h.access = HydrostaticAccess(
        actor: h.access.actor,
        authorized: false,
        fieldSession: true,
      );
      h.changes.notifyListeners();
    };
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(find.textContaining('Sesión sin autorización'), findsOneWidget);
    expect(h.store.all().length, 1);
  });
  localWidgetTest(
    'list/history/detail displays real results and returns correctly',
    (tester) async {
      final id = await h.passed();
      await open(tester, h);
      expect(find.text('APROBADO'), findsOneWidget);
      expect(find.text('VIDEO PENDIENTE'), findsOneWidget);
      await tester.tap(find.text('AQ26-00001-7'));
      await settle(tester);
      expect(find.text('HISTORIAL DE PRUEBAS'), findsOneWidget);
      await tester.tap(find.text('Prueba #1'));
      await settle(tester);
      expect(find.text('DETALLE DE PRUEBA'), findsOneWidget);
      expect(find.text('Duración: 00:00:11'), findsOneWidget);
      expect(find.text('VIDEO ENVIADO'), findsNothing);
      await tester.pageBack();
      await settle(tester);
      expect(find.text('HISTORIAL DE PRUEBAS'), findsOneWidget);
      await tester.pageBack();
      await settle(tester);
      expect(find.text('PRUEBAS HIDROSTÁTICAS'), findsOneWidget);
      expect(h.repo.get(id)!.result, HydrostaticResult.pass);
    },
  );
  localWidgetTest('foreign detail direct route never leaks', (tester) async {
    final id = await h.passed();
    h.access = HydrostaticAccess(
      actor: HydrostaticActorSnapshot(
        userId: uuid(),
        name: 'FOREIGN',
        sessionId: uuid(),
        deviceInstallationId: uuid(),
      ),
      authorized: true,
      fieldSession: true,
    );
    await open(tester, h, page: HydrostaticDetailPage(id: id));
    expect(find.text('AQ26-00001-7'), findsNothing);
    expect(find.textContaining('actor original'), findsOneWidget);
  });
  localWidgetTest('delete hidden under production defaults', (tester) async {
    final id = await h.passed();
    h.policy = const HydrostaticDevelopmentPolicy();
    h.controller.dispose();
    await h.reopen();
    h.makeController();
    await open(tester, h, page: HydrostaticDetailPage(id: id));
    expect(find.text('ELIMINAR PRUEBA LOCAL'), findsNothing);
  });
  localWidgetTest(
    'delete requires confirmation, cancellation preserves, confirmed removes only target',
    (tester) async {
      final id = await h.passed();
      final other = await h.prepare();
      await open(tester, h, page: HydrostaticDetailPage(id: id));
      final delete = find.text('ELIMINAR PRUEBA LOCAL');
      await tester.ensureVisible(delete);
      await tester.tap(delete);
      await settle(tester);
      expect(find.textContaining('UUID: $id'), findsOneWidget);
      await tester.tap(find.text('CANCELAR'));
      await settle(tester);
      expect(h.repo.get(id), isNotNull);
      await tester.tap(delete);
      await settle(tester);
      await tester.tap(find.text('ELIMINAR'));
      await settle(tester);
      expect(h.repo.get(id), isNull);
      expect(h.repo.get(other), isNotNull);
      expect(h.repo.sequences.last('AQ26000017'), 1);
      expect(h.records.length, 1);
    },
  );
  localWidgetTest('active detail has no delete or execution controls', (
    tester,
  ) async {
    final id = await h.active();
    await open(tester, h, page: HydrostaticDetailPage(id: id));
    expect(find.text('EN PROCESO'), findsOneWidget);
    expect(find.text('ELIMINAR PRUEBA LOCAL'), findsNothing);
    expect(find.text('TERMINAR PRUEBA'), findsNothing);
    expect(find.text('Duración: Pendiente'), findsOneWidget);
  });
  localWidgetTest(
    'camera permission failure offers manual fallback and cancel',
    (tester) async {
      await open(
        tester,
        h,
        page: HydrostaticIdentifyPage(
          scannerBuilder: (_) => HydrostaticScannerPage(
            surface: (context, onRead) => const HydrostaticCameraUnavailable(),
          ),
        ),
      );
      await tester.tap(find.text('ESCANEAR QR'));
      await settle(tester);
      expect(find.textContaining('Revisa su permiso'), findsOneWidget);
      await tester.tap(find.text('CANCELAR ESCANEO'));
      await settle(tester);
      expect(find.byKey(const Key('hydro_uid')), findsOneWidget);
      expect(h.store.all(), isEmpty);
    },
  );
  localWidgetTest('session change also redacts deletion confirmation modal', (
    tester,
  ) async {
    final id = await h.passed();
    await open(tester, h, page: HydrostaticDetailPage(id: id));
    await tester.ensureVisible(find.text('ELIMINAR PRUEBA LOCAL'));
    await tester.tap(find.text('ELIMINAR PRUEBA LOCAL'));
    await settle(tester);
    h.access = HydrostaticAccess(
      actor: h.access.actor,
      authorized: false,
      fieldSession: true,
    );
    h.changes.notifyListeners();
    await settle(tester);
    expect(find.textContaining('UUID:'), findsNothing);
    expect(find.text('ELIMINAR'), findsNothing);
    expect(find.text('Sesión modificada'), findsOneWidget);
    expect(h.store.test(id), isNotNull);
  });
  localWidgetTest('failed detail includes text result and per-joint pressure', (
    tester,
  ) async {
    final id = await h.ended();
    await h.repo.saveLeaks(id, uuid(), [
      HydrostaticLeak(
        id: uuid(),
        jointCode: 'J11',
        pressureMilliBar: 2500,
        description: 'Unión sintética',
      ),
    ]);
    await h.add(id, HydrostaticEvidenceRole.leakEvidence);
    await h.repo.closeLeak(id, uuid());
    await open(tester, h, page: HydrostaticDetailPage(id: id));
    expect(find.text('FUGA'), findsOneWidget);
    expect(find.textContaining('2.5 bar'), findsOneWidget);
    expect(find.textContaining('Unión sintética'), findsOneWidget);
  });
}
