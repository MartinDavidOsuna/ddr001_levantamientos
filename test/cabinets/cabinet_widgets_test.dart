import 'dart:io';
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
  testWidgets('permanent deletion requires acknowledgment and matching UID', (
    tester,
  ) async {
    final id = (await tester.runAsync(
      () => h.controller.scan('AQ26000017', 'A1', false),
    ))!;
    await tester.pumpWidget(host(CabinetDeleteDialog(id: id)));
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'AQ26-00002-5');
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('Debe coincidir con el número mostrado.'), findsOneWidget);
    expect(h.store.read(id)!.json['deletion'], isNull);
  });
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
      expect(find.text('INSTALAR GABINETE'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('REVISIÓN DE BASE')).dy,
        lessThan(tester.getTopLeft(find.text('INSTALAR GABINETE')).dy),
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
      expect(find.text('INSTALAR GABINETE'), findsNothing);
    },
  );
  testWidgets('install entry resolves local UID and opens only field stages', (
    tester,
  ) async {
    final id = (await tester.runAsync(
      () => h.controller.scan('AQ26000017', 'A1', true),
    ))!;
    await tester.pumpWidget(host(CabinetDetailPage(id: id, initialTab: 5)));
    expect(
      DefaultTabController.of(tester.element(find.byType(TabBar))).length,
      4,
    );
    expect(find.text('Instalación'), findsNothing);
    expect(find.text('Revisión final'), findsNothing);
    await tester.pumpWidget(host(const HomePage()));
    await tester.tap(find.text('INSTALAR GABINETE'));
    await tester.pumpAndSettle();
    expect(find.text('Modelo base'), findsNothing);
    await tester.enterText(find.byType(TextField), 'AQ26-00001-7');
    await tester.runAsync(() => tester.tap(find.text('Buscar gabinete')));
    await tester.pumpAndSettle();
    expect(find.text('Instalación'), findsOneWidget);
    expect(find.text('Revisión final'), findsOneWidget);
    expect(find.text('1 Registro'), findsNothing);
    expect(
      DefaultTabController.of(tester.element(find.byType(TabBar))).length,
      2,
    );
    await tester.tap(find.text('Revisión final'));
    await tester.pumpAndSettle();
    expect(
      find.text('La revisión final requiere instalación completada.'),
      findsOneWidget,
    );
    h.setRole(ConstructionRole.contractor);
    await tester.pumpWidget(host(CabinetDetailPage(id: id, fieldWork: true)));
    expect(find.textContaining('Acceso exclusivo'), findsOneWidget);
    expect(find.text('AQ26-00001-7'), findsNothing);
  });

  testWidgets('missing cabinet explains absence and prefills registration', (
    tester,
  ) async {
    h.app.online = true;
    await tester.pumpWidget(
      host(const CabinetRegisterPage(installation: true)),
    );
    await tester.enterText(find.byType(TextField), 'AQ26-00001-7');
    await tester.runAsync(() => tester.tap(find.text('Buscar gabinete')));
    await tester.pumpAndSettle();
    expect(find.text('Gabinete no encontrado'), findsOneWidget);
    expect(h.controller.records, isEmpty);
    await tester.runAsync(() => tester.tap(find.text('Registrar gabinete')));
    await tester.pumpAndSettle();
    expect(find.text('Modelo base'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'AQ26-00001-7',
    );
    expect(h.controller.records, isEmpty);
  });

  testWidgets('admin reviewer does not receive cabinet actions', (
    tester,
  ) async {
    h.setRole(ConstructionRole.superadmin);
    await tester.pumpWidget(host(const HomePage()));
    expect(find.text('REVISIÓN DE BASE'), findsOneWidget);
    expect(find.text('REGISTRAR GABINETE'), findsNothing);
  });
  testWidgets(
    'registration uses a photo count and Next closes locally then opens Parts',
    (tester) async {
      final id = (await tester.runAsync(
        () => h.controller.scan('AQ26000017', 'A1', false),
      ))!;
      await tester.runAsync(() async {
        final photo = await h.photo(
          id,
          'registration',
          source: File('test/cabinets/fixtures/evidence.jpg'),
        );
        await h.controller.saveDraft(id, 'registrationEvidence', [
          {'photoId': photo['id'], 'confirmed': true},
        ]);
      });
      await tester.pumpWidget(host(CabinetDetailPage(id: id)));
      await tester.pumpAndSettle();
      expect(find.text('Foto(s) del gabinete'), findsOneWidget);
      expect(find.text('1 foto'), findsOneWidget);
      expect(find.textContaining('Catálogo:'), findsNothing);
      expect(find.textContaining('Confirmado por servidor'), findsNothing);
      await tester.ensureVisible(find.text('Siguiente'));
      await tester.runAsync(() => tester.tap(find.text('Siguiente')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Confirmar identificación'), findsNothing);
      expect(find.text('Corresponde a este gabinete'), findsNothing);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        if (DefaultTabController.of(
              tester.element(find.byType(TabBar)),
            ).index ==
            1) {
          break;
        }
      }
      await tester.pump(const Duration(seconds: 1));
      final context = tester.element(find.byType(TabBar));
      expect(h.store.read(id)!.working['status'], 'registered');
      expect(DefaultTabController.of(context).index, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('registration stays draft until identification evidence exists', (
    tester,
  ) async {
    final id = (await tester.runAsync(
      () => h.controller.scan('AQ26000017', 'A1', false),
    ))!;
    await tester.pumpWidget(host(CabinetDetailPage(id: id)));
    await tester.tap(find.text('Siguiente'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Agrega al menos una foto'), findsOneWidget);
    expect(h.store.read(id)!.working['status'], 'draft');
  });
  testWidgets(
    '84 checks rendered as applicable groups and physical answers stay pending',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final id = (await tester.runAsync(
        () => h.controller.scan('AQ26000017', 'A1', false),
      ))!;
      final r = h.store.read(id)!.json;
      r['working']['status'] = 'validated';
      r['working']['partsValidated'] = true;
      await tester.runAsync(() => h.store.save(r));
      await tester.pumpWidget(host(CabinetDetailPage(id: id, fieldWork: true)));
      await tester.pumpAndSettle();
      expect(find.textContaining('bloqueos'), findsOneWidget);
      expect(find.textContaining('GPS de instalación:'), findsOneWidget);
      expect(
        DefaultTabController.of(tester.element(find.byType(TabBar))).length,
        2,
      );
      expect(find.text('4 Automatización'), findsNothing);
      expect(find.textContaining('Confirmar puntos revisados'), findsNothing);
      await tester.ensureVisible(find.text('Siguiente'));
      await tester.tap(find.text('Siguiente'));
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.text('Modelo del gabinete correcto'), findsOneWidget);
      expect(find.text('Modelo · A1'), findsOneWidget);
      expect(find.textContaining('Guardado en este teléfono'), findsNothing);
      expect(find.textContaining('Los campos se guardan'), findsNothing);
      await tester.binding.setSurfaceSize(const Size(1000, 1000));
      await tester.pumpAndSettle();
      final header = find.byKey(const ValueKey('installation_fixed_header'));
      final headerPosition = tester.getTopLeft(header);
      await tester.drag(find.byType(ListView).first, const Offset(0, -350));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(header), headerPosition);
      expect(find.textContaining('Comprueba y responde'), findsOneWidget);

      expect(find.text('Identificación del gabinete visible'), findsNothing);
      expect(find.text('QR visible y legible'), findsNothing);
      expect(find.text('Número de serie visible y legible'), findsNothing);
      expect(find.textContaining('CI032'), findsNothing);
      await tester.ensureVisible(find.text('Anterior'));
      await tester.tap(find.text('Anterior'));
      await tester.pumpAndSettle();
      expect(find.textContaining('GPS de instalación:'), findsOneWidget);
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
