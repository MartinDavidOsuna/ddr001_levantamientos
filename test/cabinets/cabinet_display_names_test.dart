import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_store.dart';
import 'package:ddr001_levantamientos/features/cabinets/cabinet_pages.dart';
import 'harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  CabinetCatalog updated() => CabinetCatalog(
    object(
      jsonDecode(
        File('test/cabinets/fixtures/catalog-v2.json').readAsStringSync(),
      ),
    ),
  );
  test(
    'all eight variants preserve per-instance identity, names and historical fallback',
    () {
      final fresh = updated(), old = fixtureCatalog();
      for (final model in ['A1', 'A2', 'A3', 'A4']) {
        for (final automated in [false, true]) {
          final parts = fresh.parts(model, automated);
          expect(parts.length, old.parts(model, automated).length);
          expect(parts.map((p) => p['code']).toSet().length, parts.length);
          for (final p in parts) {
            expect(cabinetPartName(p), p['displayName'] ?? p['description']);
          }
          for (final p in old.parts(model, automated)) {
            expect(cabinetPartName(p), p['description']);
          }
        }
      }
    },
  );
  test(
    'new catalog survives Hive restart while an existing draft keeps its snapshot',
    () async {
      final h = Harness();
      await h.open(remote: FakeCabinetRemote());
      try {
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        final before = clone(h.store.read(id)!.working);
        await h.store.saveCatalog(updated());
        await h.store.box.close();
        h.store = await CabinetStore.open();
        expect(h.store.catalog()!.version, updated().version);
        expect(h.store.read(id)!.working, before);
        expect(
          h.store.catalog(before['catalogVersion'])!.version,
          before['catalogVersion'],
        );
        expect(
          h.store.catalog()!.parts('A4', true),
          updated().parts('A4', true),
        );
      } finally {
        await h.close();
      }
    },
  );
  testWidgets('piece checklist renders engineering displayName', (
    tester,
  ) async {
    final h = Harness();
    await tester.runAsync(() => h.open(remote: FakeCabinetRemote()));
    try {
      final catalog = updated();
      catalog.json['partsReviewPolicy'] = jsonDecode(
        File(
          'test/cabinets/fixtures/parts-review-policy.json',
        ).readAsStringSync(),
      );
      await tester.runAsync(() => h.store.saveCatalog(catalog));
      final id = (await tester.runAsync(
        () => h.controller.scan('AQ26000017', 'A1', false),
      ))!;
      final record = h.store.read(id)!.json;
      record['working']['status'] = 'registered';
      await tester.runAsync(() => h.store.save(record));
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: h.app),
            ChangeNotifierProvider.value(value: h.controller),
          ],
          child: MaterialApp(home: CabinetDetailPage(id: id, initialTab: 1)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('FLUJOMETRO MUT7000'), findsWidgets);
      expect(find.textContaining('MEDIDOR ELECTROMAGNETICO'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    } finally {
      await tester.runAsync(() => h.close());
    }
  });
}
