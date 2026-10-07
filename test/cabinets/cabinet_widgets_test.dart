import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/features/cabinets/cabinet_pages.dart';
import 'package:ddr001_levantamientos/features/home/home_page.dart';
import 'harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late HistoryRemote historyRemote;
  setUp(() async {
    h = Harness();
    historyRemote = HistoryRemote();
    await h.open(remote: historyRemote);
  });
  tearDown(() async {
    await h.close();
  });
  Widget host(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: h.app),
      ChangeNotifierProvider.value(value: h.controller),
    ],
    child: MaterialApp(home: child),
  );
  testWidgets('history loads on entry and explains empty results', (
    tester,
  ) async {
    final id = (await tester.runAsync(
      () => h.controller.scan('AQ26000017', 'A1', false),
    ))!;
    final cached = h.store.read(id)!.json;
    cached['operations'] = [];
    await tester.runAsync(() => h.store.save(cached));
    await tester.runAsync(() async {
      await tester.pumpWidget(host(CabinetHistoryPage(id: id)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(historyRemote.callsToHistory, 1);
    expect(find.text('Este gabinete aún no tiene historial.'), findsOneWidget);
  });
  testWidgets('failed history preserves cache and can retry', (tester) async {
    final id = (await tester.runAsync(
      () => h.controller.scan('AQ26000017', 'A1', false),
    ))!;
    final cached = h.store.read(id)!.json;
    cached['operations'] = [];
    cached['history'] = [
      {'result_version': 7, 'command_type': 'create_draft'},
    ];
    await tester.runAsync(() => h.store.save(cached));
    historyRemote.fail = true;
    await tester.runAsync(() async {
      await tester.pumpWidget(host(CabinetHistoryPage(id: id)));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('v7'), findsOneWidget);
    expect(find.text('No se pudo actualizar el historial.'), findsOneWidget);
    historyRemote.fail = false;
    historyRemote.items = [
      {'result_version': 8, 'command_type': 'create_draft'},
    ];
    await tester.runAsync(() async {
      await tester.tap(find.text('Reintentar'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('v8'), findsOneWidget);
    expect(find.text('No se pudo actualizar el historial.'), findsNothing);
    expect(historyRemote.callsToHistory, 2);
  });
  testWidgets(
    'resident navigation order includes cabinet and final review replacing placeholder',
    (tester) async {
      await tester.pumpWidget(host(const HomePage()));
      expect(find.text('REGISTRAR GABINETE'), findsOneWidget);
      expect(find.text('REGISTRAR INSTALACIÓN'), findsNothing);
      expect(find.text('REVISIÓN DE HIDRANTE'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('REVISIÓN DE BASE')).dy,
        lessThan(tester.getTopLeft(find.text('REVISIÓN DE HIDRANTE')).dy),
      );
      await tester.tap(find.text('REGISTRAR GABINETE'));
      await tester.pumpAndSettle();
      expect(find.text('Escanear gabinete'), findsOneWidget);
      expect(find.byType(CabinetScannerPage), findsNothing);
    },
  );
  testWidgets(
    'contractor direct dossier route hides cached UID, photos and actions',
    (tester) async {
      final id = (await tester.runAsync(
        () => h.controller.scan('AQ26000017', 'A1', false),
      ))!;
      h.setRole(ConstructionRole.contractor);
      await tester.pumpWidget(host(CabinetDetailPage(id: id)));
      expect(find.text('AQ26-00001-7'), findsNothing);
      expect(find.byType(EvidenceEditor), findsNothing);
      expect(find.textContaining('Acceso exclusivo'), findsOneWidget);
      await tester.pumpWidget(host(const HomePage()));
      expect(find.text('REGISTRAR GABINETE'), findsNothing);
      expect(find.text('REVISIÓN DE HIDRANTE'), findsNothing);
    },
  );
  testWidgets('admin reviewer does not receive cabinet actions', (
    tester,
  ) async {
    h.setRole(ConstructionRole.superadmin);
    await tester.pumpWidget(host(const HomePage()));
    expect(find.text('REVISIÓN DE BASE'), findsOneWidget);
    expect(find.text('REGISTRAR GABINETE'), findsNothing);
  });
  testWidgets('registration stays draft until identification evidence exists', (
    tester,
  ) async {
    final id = (await tester.runAsync(
      () => h.controller.scan('AQ26000017', 'A1', false),
    ))!;
    await tester.pumpWidget(host(CabinetDetailPage(id: id)));
    await tester.tap(find.text('Completar registro local'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Falta fotografía'), findsOneWidget);
    expect(h.store.read(id)!.working['status'], 'draft');
  });
  testWidgets(
    '84 checks rendered as applicable groups and physical answers stay pending',
    (tester) async {
      final id = (await tester.runAsync(
        () => h.controller.scan('AQ26000017', 'A1', false),
      ))!;
      final r = h.store.read(id)!.json;
      r['working']['status'] = 'validated';
      r['working']['partsValidated'] = true;
      await tester.runAsync(() => h.store.save(r));
      await tester.pumpWidget(host(CabinetDetailPage(id: id, initialTab: 2)));
      await tester.pumpAndSettle();
      expect(find.textContaining('bloqueos'), findsOneWidget);
      expect(find.textContaining('GPS de instalación'), findsOneWidget);
      expect(find.textContaining('Confirmar puntos revisados'), findsNothing);
    },
  );
}

class HistoryRemote extends FakeCabinetRemote {
  int callsToHistory = 0;
  bool fail = false;
  List<Map<String, dynamic>> items = [];
  @override
  Future<Map<String, dynamic>> get(
    String path, [
    Map<String, dynamic>? query,
  ]) async {
    if (path.endsWith('/history')) {
      callsToHistory++;
      if (fail) throw StateError('offline');
      return {'items': items};
    }
    return super.get(path, query);
  }
}
