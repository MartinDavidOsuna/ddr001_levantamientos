import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/core/persistence/local_store.dart';
import 'package:ddr001_levantamientos/core/services/app_controller.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_store.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_cabinet_lookup.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/features/home/home_page.dart';
import 'package:ddr001_levantamientos/features/hydrostatic/hydrostatic_controller.dart';
import 'ui_harness.dart';
import 'harness.dart';
import 'ui_widgets_test.dart' as widgets;
import '../widgets/build_one_widgets_test.dart' as existing;

void main() {
  late UiHarness h;
  setUp(() async {
    h = UiHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  test(
    'real CabinetStore read leaves all foreign Hive boxes unchanged',
    () async {
      final boxes = <Box<String>>[];
      for (var n = 0; n < 6; n++) {
        final b = await Hive.openBox<String>(
          'synthetic_foreign_$n',
          path: h.root.path,
        );
        await b.put('sentinel', 'preserved');
        boxes.add(b);
      }
      final cabinets = CabinetStore(
        boxes[0],
        LocalStore(boxes[1], boxes[2], boxes[3], boxes[4], boxes[5]),
      );
      final record = h.records.single;
      await boxes[0].put('cabinet:${record.id}', jsonEncode(record.json));
      await boxes[0].put('authorized:${h.access.actor.userId}', 'true');
      final before = boxes.map((b) => Map.of(b.toMap())).toList();
      final lookup = LocalHydrostaticCabinetLookup.fromStore(cabinets);
      final snapshot = await lookup.findLocal('AQ26000017', h.access);
      expect(snapshot!.cabinetId, record.id);
      await h.repo.prepare(
        operationId: uuid(),
        testId: uuid(),
        cabinet: snapshot,
      );
      expect(boxes.map((b) => b.toMap()).toList(), before);
      for (final b in boxes) {
        await b.close();
      }
      expect(h.network.calls, 0);
    },
  );
  for (final allowed in [true, false]) {
    testWidgets('Home card always visible, authorized navigation $allowed', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final (app, root) = await existing.controller(
          ConstructionRole.resident,
        );
        if (!allowed) {
          h.access = HydrostaticAccess(
            actor: h.access.actor,
            authorized: false,
            fieldSession: true,
          );
        }
        try {
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider<AppController>.value(value: app),
                ChangeNotifierProvider<HydrostaticController>.value(
                  value: h.controller,
                ),
              ],
              child: const MaterialApp(home: HomePage()),
            ),
          );
          expect(
            find.byKey(const Key('resident_review_action')),
            findsOneWidget,
          );
          expect(find.byKey(const Key('hydrostatic_action')), findsOneWidget);
          if (!allowed) {
            await tester.tap(find.byKey(const Key('hydrostatic_action')));
            await tester.pump();
            expect(find.byType(SnackBar), findsOneWidget);
            expect(h.controller.ready, isFalse);
            expect(find.text('NUEVA PRUEBA'), findsNothing);
          }
          if (allowed) {
            await tester.tap(find.byKey(const Key('hydrostatic_action')));
            await widgets.settle(tester);
            expect(
              find.text('Aún no hay pruebas hidrostáticas registradas.'),
              findsOneWidget,
            );
            await tester.pageBack();
            await widgets.settle(tester);
            expect(
              find.byKey(const Key('resident_review_action')),
              findsOneWidget,
            );
          }
          await tester.pumpWidget(const SizedBox());
        } finally {
          app.dispose();
          for (final b in [
            app.local.surveysBox,
            app.local.photosBox,
            app.local.queueBox,
            app.local.metadataBox,
            app.local.journalBox,
          ]) {
            await b.close();
          }
          await root.delete(recursive: true);
        }
      });
    });
  }
}
