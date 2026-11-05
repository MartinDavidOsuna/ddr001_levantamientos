import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/features/cabinets/cabinet_pages.dart';
import 'harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  setUp(() async {
    h = Harness();
    await h.open(remote: FakeCabinetRemote());
    final catalog = CabinetCatalog(
      object(
        jsonDecode(
          File('test/cabinets/fixtures/catalog-v2.json').readAsStringSync(),
        ),
      ),
    );
    catalog.json['partsReviewPolicy'] = jsonDecode(
      File(
        'test/cabinets/fixtures/parts-review-policy.json',
      ).readAsStringSync(),
    );
    await h.store.saveCatalog(catalog);
  });
  tearDown(() => h.close());

  test(
    'side save defaults missing presence, preserves false and historical evidence, persists policy',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A4', true);
      final r = h.store.read(id)!.json;
      r['working']['status'] = 'registered';
      await h.store.save(r);
      final policy = object(h.store.catalog()!.json['partsReviewPolicy']);
      final definitions = objects(r['working']['partDefinitions']);
      final flow = definitions.firstWhere(
        (p) =>
            object(object(policy['parts'])[p['code']])['serial'] == 'required',
      );
      await h.controller.patchPart(id, flow['code'], {
        'serial': 'AB00001',
        'present': true,
      });
      final missing = definitions.firstWhere((p) => p['code'] != flow['code']);
      await h.controller.patchPart(id, missing['code'], {
        'present': false,
        'observations': 'Falta en campo',
        'evidence': [
          {'photoId': 'historic', 'confirmed': true},
        ],
      });
      await h.controller.savePartsSide(id, 'district');
      await h.controller.savePartsSide(id, 'producer');
      await h.controller.savePartsSide(id, 'automation');
      final saved = h.store.read(id)!.working;
      expect(saved['partsValidated'], false);
      expect(partsPending(saved).length, 1);
      final capture = objects(
        saved['parts'],
      ).firstWhere((p) => p['code'] == missing['code']);
      expect(capture['present'], false);
      expect(capture['evidence'], [
        {'photoId': 'historic', 'confirmed': true},
      ]);
      expect(objects(saved['parts']).length, definitions.length);
      expect(saved['partsReviewPolicyVersion'], policy['version']);
      await h.controller.patchPart(id, missing['code'], {'present': true});
      await h.controller.savePartsSide(id, 'producer');
      await h.controller.savePartsSide(id, 'automation');
      expect(h.store.read(id)!.working['partsValidated'], true);
      expect(partsPending(h.store.read(id)!.working), isEmpty);
    },
  );

  test(
    'manual A4 adds all seven solenoids from API policy without duplication and validates',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A4', false);
      final r = h.store.read(id)!.json;
      r['working']['status'] = 'registered';
      await h.store.save(r);
      final policy = object(h.store.catalog()!.json['partsReviewPolicy']);
      final definitions = cabinetReviewDefinitions(
        h.store.read(id)!.working,
        policy,
      );
      final universal = objects(
        policy['universalParts'],
      ).where((p) => '${p['code']}'.startsWith('A4.')).toList();
      expect(universal.length, 7);
      for (final p in universal) {
        expect(definitions.where((d) => d['code'] == p['code']).length, 1);
        expect(cabinetPartStep(p, policy), isNot('automation'));
      }
      final flow = definitions.firstWhere(
        (p) =>
            object(object(policy['parts'])[p['code']])['serial'] == 'required',
      );
      await h.controller.patchPart(id, flow['code'], {'serial': 'AB00001'});
      await h.controller.savePartsSide(id, 'district');
      await h.controller.savePartsSide(id, 'producer');
      expect(h.store.read(id)!.working['partsValidated'], true);
      expect(
        objects(h.store.read(id)!.working['parts']).length,
        definitions.length,
      );
    },
  );

  for (final automated in [false, true]) {
    testWidgets(
      'last checklist save modal cancels or saves and returns to list automated=$automated',
      (tester) async {
        final id = (await tester.runAsync(
          () => h.controller.scan('AQ26000017', 'A1', automated),
        ))!;
        await tester.runAsync(() async {
          final record = h.store.read(id)!.json;
          record['working']['status'] = 'registered';
          await h.store.save(record);
          if (automated) {
            final flow = objects(
              record['working']['partDefinitions'],
            ).firstWhere((p) => p['serial'] == 'required');
            await h.controller.patchPart(id, flow['code'], {
              'serial': '000AB123',
            });
          }
          await h.controller.savePartsSide(id, 'district');
          if (automated) await h.controller.savePartsSide(id, 'producer');
        });
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider.value(value: h.app),
              ChangeNotifierProvider.value(value: h.controller),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => CabinetDetailPage(
                          id: id,
                          initialTab: automated ? 3 : 2,
                        ),
                      ),
                    ),
                    child: const Text('Listado de gabinetes'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Listado de gabinetes'));
        await tester.pumpAndSettle();
        expect(find.text('Guardar y salir'), findsOneWidget);
        final operations = h.store.read(id)!.operations.length;
        await tester.runAsync(() => tester.tap(find.text('Guardar y salir')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Continuar revisión'), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.text('Continuar revisión'));
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pumpAndSettle();
        expect(h.store.read(id)!.operations.length, operations);
        expect(find.byType(CabinetDetailPage), findsOneWidget);
        await tester.runAsync(() => tester.tap(find.text('Guardar y salir')));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.runAsync(
          () =>
              tester.tap(find.widgetWithText(FilledButton, 'Guardar gabinete')),
        );
        for (var i = 0; i < 40; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(CabinetDetailPage).evaluate().isEmpty) break;
        }
        expect(find.byType(CabinetDetailPage), findsNothing);
        expect(find.text('Listado de gabinetes'), findsOneWidget);
        expect(
          h.store.read(id)!.working['status'],
          automated ? 'validated' : 'incomplete',
        );
        expect(h.store.read(id)!.working['installation'], isNull);
        expect(
          h.store
              .read(id)!
              .operations
              .any(
                (op) =>
                    '${object(op['body'])['type']}'.startsWith('installation'),
              ),
          false,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'four registration steps show all side pieces checked without panels, photo controls or blue pending links',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final id = (await tester.runAsync(
        () => h.controller.scan('AQ26000017', 'A4', true),
      ))!;
      final r = h.store.read(id)!.json;
      r['working']['status'] = 'registered';
      await tester.runAsync(() => h.store.save(r));
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
      expect(
        DefaultTabController.of(tester.element(find.byType(TabBar))).length,
        4,
      );
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.textContaining('Revisar pendientes'), findsNothing);
      expect(find.text('Número de serie del flujómetro'), findsOneWidget);
      final rules = object(
        object(h.store.catalog()!.json['partsReviewPolicy'])['parts'],
      );
      final district = objects(
        r['working']['partDefinitions'],
      ).where((p) => object(rules[p['code']])['step'] == 'district');
      for (final p in district) {
        final box = find.byKey(ValueKey('present-${p['code']}'));
        expect(tester.widget<Checkbox>(box).value, true);
        expect(box.hitTestable(), findsOneWidget);
      }
      final ordered = district.toList()
        ..sort(
          (a, b) => (object(rules[a['code']])['order'] as num).compareTo(
            object(rules[b['code']])['order'] as num,
          ),
        );
      final serial = find.byKey(ValueKey('${ordered.first['code']}-serial'));
      expect(
        tester.getTopLeft(serial).dy,
        greaterThan(
          tester
              .getBottomLeft(
                find.byKey(ValueKey('present-${ordered.first['code']}')),
              )
              .dy,
        ),
      );
      expect(
        tester.getBottomLeft(serial).dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(ValueKey('present-${ordered[1]['code']}')))
              .dy,
        ),
      );
      expect(
        tester
                .getCenter(
                  find.byKey(ValueKey('present-${ordered[2]['code']}')),
                )
                .dy -
            tester
                .getCenter(
                  find.byKey(ValueKey('present-${ordered[1]['code']}')),
                )
                .dy,
        lessThanOrEqualTo(40),
      );
      DefaultTabController.of(tester.element(find.byType(TabBar))).animateTo(2);
      await tester.pumpAndSettle();
      expect(find.text('PIEZAS DEL PRODUCTOR'), findsOneWidget);
      expect(find.text('Número de serie del flujómetro'), findsNothing);
      for (final p in objects(
        r['working']['partDefinitions'],
      ).where((p) => object(rules[p['code']])['step'] == 'producer')) {
        expect(
          find.byKey(ValueKey('present-${p['code']}')).hitTestable(),
          findsOneWidget,
        );
      }
      DefaultTabController.of(tester.element(find.byType(TabBar))).animateTo(3);
      await tester.pumpAndSettle();
      expect(find.text('PIEZAS DE AUTOMATIZACIÓN'), findsOneWidget);
      for (final p in objects(
        r['working']['partDefinitions'],
      ).where((p) => object(rules[p['code']])['step'] == 'automation')) {
        expect(
          find.byKey(ValueKey('present-${p['code']}')).hitTestable(),
          findsOneWidget,
        );
        expect(find.text(cabinetPartName(p).toUpperCase()), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}
