import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/features/cabinets/cabinet_pages.dart';
import 'package:ddr001_levantamientos/features/cabinets/cabinet_safety_widgets.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'harness.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';

void main() {
  late Harness h;
  setUp(() async {
    h = Harness();
    await h.open();
  });
  tearDown(() async => h.close());
  Widget host(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: h.app),
      ChangeNotifierProvider.value(value: h.controller),
    ],
    child: MaterialApp(home: child),
  );

  Future<void> requireCompany() => h.store.saveCatalog(
    CabinetCatalog({
      ...fixtureCatalog().json,
      'capabilities': {'registrationCompany': true},
    }),
  );
  test(
    'missing company blocks new registration before queueing any work',
    () async {
      await requireCompany();
      await expectLater(
        h.controller.scan('AQ26000017', 'A1', false),
        throwsStateError,
      );
      expect(h.store.all(), isEmpty);
    },
  );
  test(
    'registration snapshots the login session company when profile has no company',
    () async {
      await requireCompany();
      const crew = '22222222-2222-4222-8222-222222222222';
      h.app.session = h.app.session!.copyWith(
        crewId: crew,
        crew: 'TEST LOGIN COMPANY',
      );
      final id = await h.controller.scan('AQ26000017', 'A3', true);
      final record = h.store.read(id)!;
      expect(record.working['registrationCompany']['id'], crew);
      expect(
        record.working['registrationCompany']['name'],
        'TEST LOGIN COMPANY',
      );
      expect(record.operations.first['body']['expectedCrewId'], crew);
      expect(record.working['model'], 'A3');
    },
  );

  testWidgets(
    'requires explicit model before camera or manual UID; floating label and order',
    (tester) async {
      await tester.pumpWidget(host(const CabinetRegisterPage()));
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, false);
      expect(
        tester
            .widget<CabinetBusyButton>(find.byType(CabinetBusyButton).first)
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .initialValue,
        isNull,
      );
      expect(
        tester.getTopLeft(find.byType(DropdownButtonFormField<String>)).dy,
        lessThan(tester.getTopLeft(find.text('Abrir cámara QR')).dy),
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A3').last);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, true);
      expect(
        tester
            .widget<CabinetBusyButton>(find.byType(CabinetBusyButton).first)
            .onPressed,
        isNotNull,
      );
      await tester.enterText(find.byType(TextField), 'AQ26-00001-7');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.labelText,
        'Numero de Hidrante',
      );
      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.labelText,
        'Ej. AQ26-00000-0',
      );
      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Continuar con UID escrito'),
      );
      expect(button.style!.alignment, Alignment.center);
    },
  );

  testWidgets(
    'photo future survives parent rebuilds and disappears on permission revocation',
    (tester) async {
      await tester.runAsync(() async {
        late String id;
        late Map<String, dynamic> photo;
        id = await h.controller.scan('AQ26000017', 'A1', false);
        photo = await h.photo(id, 'registration');
        await File(photo['localPath']).writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9i8AAAAASUVORK5CYII=',
          ),
        );
        late StateSetter rebuild;
        await tester.pumpWidget(
          host(
            StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return Scaffold(
                  body: CabinetPhotoImage(id: id, photo: photo),
                );
              },
            ),
          ),
        );
        final initial = tester
            .widget<FutureBuilder<Uint8List>>(
              find.byType(FutureBuilder<Uint8List>),
            )
            .future;
        for (var i = 0; i < 3; i++) {
          rebuild(() {});
          await tester.pump(const Duration(seconds: 1));
          expect(
            tester
                .widget<FutureBuilder<Uint8List>>(
                  find.byType(FutureBuilder<Uint8List>),
                )
                .future,
            same(initial),
          );
        }
        await initial;
        await tester.pump();
        h.setRole(ConstructionRole.contractor);
        rebuild(() {});
        await tester.pump();
        expect(find.byType(Image), findsNothing);
        expect(find.byType(FutureBuilder<Uint8List>), findsNothing);
      });
    },
  );
}
