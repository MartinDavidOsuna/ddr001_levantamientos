import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_safety.dart';
import 'package:ddr001_levantamientos/features/cabinets/cabinet_safety_widgets.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  setUp(() async {
    h = Harness();
    await h.open(remote: FakeCabinetRemote());
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

  test(
    'dialog drafts are retained separately for each authorized resident',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      await h.sync();
      final first = h.controller.actor!;
      await h.controller.saveAuxDraft(id, 'modelCorrectionDraft', {
        'reason': 'Primer residente',
      });
      final other = testSession(user: '22222222-2222-4222-8222-222222222222');
      h.app.session = other;
      h.sessions.value = other;
      h.setRole(ConstructionRole.resident);
      await h.store.authorize(other.userId, true);
      await h.controller.saveAuxDraft(id, 'modelCorrectionDraft', {
        'reason': 'Segundo residente',
      });
      final drafts = object(h.store.read(id)!.json['uiDrafts']);
      expect(
        drafts[first]['modelCorrectionDraft']['reason'],
        'Primer residente',
      );
      expect(
        drafts[other.userId]['modelCorrectionDraft']['reason'],
        'Segundo residente',
      );
    },
  );
  test(
    'rapid and repeated completion creates exactly one durable operation',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      final p = await h.photo(id, 'registration');
      await Future.wait(
        List.generate(
          3,
          (_) => h.controller.enqueue(id, 'registration_close', {
            'evidence': evidence(p),
          }),
        ),
      );
      await h.controller.enqueue(id, 'registration_close', {
        'evidence': evidence(p),
      });
      expect(
        h.store
            .read(id)!
            .pending
            .where((p) => object(p['body'])['type'] == 'registration_close'),
        hasLength(1),
      );
    },
  );
  test(
    'concurrent different part fields merge without losing captured serial',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      await Future.wait([
        h.controller.patchPart(id, 'A1.r5.u1', {'serial': '00001O'}),
        h.controller.patchPart(id, 'A1.r5.u1', {
          'observations': 'Placa revisada',
        }),
      ]);
      final part = objects(h.store.read(id)!.working['parts']).single;
      expect(part['serial'], '00001O');
      expect(part['observations'], 'Placa revisada');
      expect(h.store.read(id)!.json['dirty'], isTrue);
      expect(h.store.read(id)!.json['draftSavedAt'], isNotNull);
    },
  );
  test(
    'bad model correction reason preserves working data and queue',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      final before = clone(h.store.read(id)!.json);
      for (final reason in ['  ', 'ab', 'a' * 2001]) {
        await expectLater(
          h.controller.enqueue(id, 'identity_correct', {
            'model': 'A4',
            'automated': true,
            'reason': reason,
          }),
          throwsStateError,
        );
        expect(h.store.read(id)!.json, before);
      }
    },
  );
  test(
    'model correction remaps only compatible physical pieces and retains photos',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      final photo = await h.photo(id, 'registration');
      await h.controller.enqueue(id, 'registration_close', {
        'evidence': evidence(photo),
      });
      final old = h.store.read(id)!.working;
      final captures = objects(old['partDefinitions'])
          .map(
            (p) => <String, dynamic>{
              'code': p['code'],
              'present': true,
              'serial': p['serial'] == 'none' ? null : '00001',
              'evidence': evidence(photo),
            },
          )
          .toList();
      await h.controller.saveDraft(id, 'parts', captures);
      final before = h.store.read(id)!.working;
      final expected = compatibleParts(
        before,
        fixtureCatalog().parts('A4', true),
      );
      expect(expected, isNotEmpty);
      await h.controller.enqueue(id, 'identity_correct', {
        'model': 'A4',
        'automated': true,
        'reason': 'Modelo correcto',
      });
      final next = h.store.read(id)!;
      expect(next.working['parts'], expected);
      expect(next.photos.single['id'], photo['id']);
      expect(next.working['partsValidated'], isFalse);
    },
  );
  test(
    'serial normalization preserves zeros and ambiguous letters; repetitions are warnings',
    () {
      expect(normalizeSerial('  0001O  I2  '), '0001O I2');
      expect(
        duplicateSerialWarnings({
          'parts': [
            {'code': 'A', 'serial': ' 001o '},
            {'code': 'B', 'serial': '001O'},
          ],
        }),
        hasLength(1),
      );
      expect(reasonError('   '), isNotNull);
      expect(reasonError(' válido '), isNull);
    },
  );
  test(
    'old missing and future GPS require new capture; distance remains measurable',
    () {
      final now = DateTime.utc(2026, 10, 6, 12);
      expect(freshInstallationGps(null, now), isFalse);
      expect(
        freshInstallationGps(
          now.subtract(const Duration(minutes: 16)).toIso8601String(),
          now,
        ),
        isFalse,
      );
      expect(
        freshInstallationGps(
          now.add(const Duration(minutes: 5)).toIso8601String(),
          now,
        ),
        isFalse,
      );
      expect(freshInstallationGps(now.toIso8601String(), now), isTrue);
      expect(distanceMeters(20, -103, 25, -100), greaterThan(500000));
      expect(distanceMeters(20, -103, 20, -103), 0);
    },
  );
  testWidgets('action button blocks double taps until action completes', (
    tester,
  ) async {
    final done = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CabinetBusyButton(
            onPressed: () async {
              calls++;
              await done.future;
            },
            child: const Text('Guardar'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Guardar'));
    await tester.pump();
    await tester.tap(find.text('Guardar'));
    await tester.pump();
    expect(calls, 1);
    done.complete();
    await tester.pumpAndSettle();
  });
  testWidgets(
    'model dialog scrolls with large text and keyboard and retains invalid input',
    (tester) async {
      final id = (await tester.runAsync(
        () => h.controller.scan('AQ26000017', 'A1', false),
      ))!;
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        host(
          Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(1.8)),
              child: CabinetModelDialog(id: id),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await tester.enterText(find.byType(TextFormField), ' x ');
        await h.controller.flushDrafts();
      });
      await tester.tap(find.text('Aplicar corrección'));
      await tester.pumpAndSettle();
      expect(find.byType(CabinetModelDialog), findsOneWidget);
      expect(
        h.store.read(id)!.json['uiDrafts'][h
            .controller
            .actor]['modelCorrectionDraft']['reason'],
        ' x ',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
