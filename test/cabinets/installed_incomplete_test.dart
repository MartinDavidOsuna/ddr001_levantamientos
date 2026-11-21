import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_store.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/features/cabinets/cabinet_pages.dart';
import 'harness.dart';

// HTTP receipts stand in for the API lifecycle independently certified in SQL TEST.
class LifecycleRemote extends FakeCabinetRemote {
  @override
  Future<Json> command(String id, Json body) async {
    final result = await super.command(id, body);
    final c = object(result['cabinet']);
    switch (body['type']) {
      case 'register':
        c['partDefinitions'] = fixtureCatalog().parts(
          body['model'],
          body['automated'],
        );
      case 'parts_save':
        c['partsValidated'] = false;
        c['approval'] = null;
        c['status'] = c['installationOperationId'] == null
            ? 'incomplete'
            : 'installed_incomplete';
      case 'parts_validate':
        c['partsValidated'] = partsPending(c).isEmpty;
        c['status'] = c['installationOperationId'] == null
            ? 'validated'
            : 'installed';
      case 'installation_save':
        c['installationValid'] = false;
      case 'installation_close':
        c['installationValid'] = true;
        c['installationOperationId'] = body['operationId'];
        c['status'] = c['partsValidated'] == true
            ? 'installed'
            : 'installed_incomplete';
      case 'final_review':
        c['status'] = 'deliverable';
    }
    documents[id] = c;
    result['cabinet'] = c;
    receipts[body['operationId']] = result;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late LifecycleRemote remote;
  setUp(() async {
    h = Harness();
    remote = LifecycleRemote();
    await h.open(remote: remote);
  });
  tearDown(() => h.close());
  Widget host(Widget child) => MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: h.app),
      ChangeNotifierProvider.value(value: h.controller),
    ],
    child: MaterialApp(home: child),
  );

  Future<String> seed(String status, {bool closed = false}) async {
    final id = await h.controller.scan('AQ26000017', 'A1', false);
    final value = clone(h.store.read(id)!.json);
    final w = h.store.read(id)!.working;
    w['status'] = status;
    w['partsValidated'] = false;
    if (closed) {
      w['installationOperationId'] = '22222222-2222-4222-8222-222222222222';
      w['installationValid'] = true;
      w['installation'] = {
        'baseId': '33333333-3333-4333-8333-333333333333',
        'gps': {'latitude': 20, 'longitude': -103, 'accuracy': 5},
        'answers': <Json>[],
        'evidence': <String, dynamic>{},
      };
    }
    value['working'] = w;
    await h.store.save(value);
    return id;
  }

  testWidgets(
    'incomplete opens installation and displays the informational warning',
    (tester) async {
      final id = (await tester.runAsync(() => seed('incomplete')))!;
      await tester.pumpWidget(
        host(Scaffold(body: CabinetInstallation(id: id))),
      );
      expect(
        find.textContaining('Este gabinete tiene piezas pendientes.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('installation_fixed_header')),
        findsOneWidget,
      );
      expect(
        find.text('Completa y valida las piezas antes de instalar.'),
        findsNothing,
      );
      final context = tester.element(find.byType(CabinetInstallation));
      expect(await cabinetInstallationMode(context, h.controller, id), isTrue);
    },
  );

  testWidgets(
    'installed incomplete is visible in installation list, filters and parts access',
    (tester) async {
      final id = (await tester.runAsync(
        () => seed('installed_incomplete', closed: true),
      ))!;
      await tester.pumpWidget(host(const CabinetsPage(installation: true)));
      expect(find.textContaining('Instalado · incompleto'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('status-')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Instalado · incompleto').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('Visibles: 1'), findsOneWidget);
      await tester.pumpWidget(host(CabinetDetailPage(id: id, fieldWork: true)));
      expect(find.text('Completar piezas pendientes'), findsOneWidget);
      await tester.tap(find.text('Completar piezas pendientes'));
      await tester.pumpAndSettle();
      expect(find.text('2 Distrito'), findsOneWidget);
      expect(find.byType(CabinetParts), findsWidgets);
    },
  );

  test(
    'offline install, complete parts, sync and reopen keep base/GPS/photos/journal',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      final registration = await h.photo(id, 'registration');
      await h.controller.enqueue(id, 'registration_close', {
        'evidence': evidence(registration),
      });
      await h.controller.enqueue(id, 'parts_save', {'parts': <Json>[]});
      expect(h.controller.record(id).working['status'], 'incomplete');
      final photo = await h.photo(id, 'installation');
      final w = h.controller.record(id).working;
      final installation = <String, dynamic>{
        'baseId': '33333333-3333-4333-8333-333333333333',
        'gps': {'latitude': 20.0, 'longitude': -103.0, 'accuracy': 5.0},
        'answers': fixtureCatalog()
            .applicable(w)
            .where((q) => q['kind'] == 'check')
            .map(
              (q) => <String, dynamic>{
                'code': q['code'],
                'answer': 'yes',
                'evidence': <Json>[],
              },
            )
            .toList(),
        'evidence': {
          for (final q
              in fixtureCatalog()
                  .applicable(w)
                  .where((q) => q['kind'] == 'evidence'))
            '${q['code']}': evidence(photo),
        },
      };
      await h.controller.enqueue(id, 'installation_save', {
        'installation': installation,
      });
      await h.controller.enqueue(id, 'installation_close', {});
      var r = h.controller.record(id);
      expect(r.working['status'], 'installed_incomplete');
      expect(r.working['installationValid'], isTrue);
      final operation = r.working['installationOperationId'];
      final queue = clone(r.json)['operations'];
      await h.controller.synchronize();
      expect(h.controller.record(id).operations, queue);
      expect(remote.calls, isEmpty);
      await expectLater(
        h.controller.enqueue(id, 'final_review', {
          'verdict': 'approve',
          'reason': 'Field checked',
        }),
        throwsStateError,
      );
      final partsPhoto = await h.photo(id, 'parts_validation');
      final parts = [
        for (final p in objects(w['partDefinitions']))
          <String, dynamic>{
            'code': p['code'],
            'present': true,
            'serial': p['serial'] == 'required' ? 'SERIAL001' : null,
            'evidence': evidence(partsPhoto),
          },
      ];
      await h.controller.enqueue(id, 'parts_save', {'parts': parts});
      await h.controller.enqueue(id, 'parts_validate', {});
      r = h.controller.record(id);
      expect(r.working['status'], 'installed');
      expect(r.working['installation'], installation);
      expect(r.working['installationOperationId'], operation);
      expect(
        r.pending
            .where((op) => object(op['body'])['type'] == 'installation_close')
            .length,
        1,
      );
      final beforePhotos = clone(r.json)['photos'];
      await h.sync();
      r = h.controller.record(id);
      expect(r.pending, isEmpty);
      expect(r.server['status'], 'installed');
      expect(h.controller.message, isNull);
      expect(r.working['installationOperationId'], operation);
      expect(r.photos.length, (beforePhotos as List).length);
      expect(File(photo['localPath']).existsSync(), isTrue);
      final finalPhoto = await h.photo(id, 'final_review');
      await h.controller.enqueue(id, 'final_review', {
        'verdict': 'approve',
        'reason': 'Field checked',
        'fieldChecked': true,
        'dossierConsulted': true,
        'evidenceConfirmed': true,
        'evidence': evidence(finalPhoto),
        'installationOperationId': operation,
      });
      await h.sync();
      expect(h.controller.record(id).server['status'], 'deliverable');
      final saved = clone(h.controller.record(id).json);
      await h.store.box.close();
      h.store = CabinetStore(
        await Hive.openBox<String>('cabinets_documents_v1'),
        h.store.media,
      );
      expect(h.store.read(id)!.json, saved);
      expect(h.store.read(id)!.working['installation'], installation);
    },
  );

  test(
    'restart preserves installed incomplete, photos and queued parts work',
    () async {
      final id = await seed('installed_incomplete', closed: true);
      final photo = await h.photo(id, 'parts_validation');
      await h.controller.patchPart(
        id,
        '${objects(h.controller.record(id).working['partDefinitions']).first['code']}',
        {'present': true, 'evidence': evidence(photo)},
      );
      final saved = clone(h.controller.record(id).json);
      await h.store.box.close();
      h.store = CabinetStore(
        await Hive.openBox<String>('cabinets_documents_v1'),
        h.store.media,
      );
      final reopened = h.store.read(id)!;
      expect(reopened.json, saved);
      expect(reopened.working['status'], 'installed_incomplete');
      expect(reopened.working['installationValid'], isTrue);
      expect(reopened.pending, isNotEmpty);
      expect(reopened.json['dirty'], isTrue);
      expect(File(photo['localPath']).existsSync(), isTrue);
    },
  );

  test(
    'new server closure survives pending local work and rejects stale snapshots',
    () async {
      final id = await seed('incomplete');
      final local = clone(h.store.read(id)!.json);
      final working = h.store.read(id)!.working;
      remote.documents[id] = {
        ...working,
        'cabinetId': id,
        'version': 8,
        'status': 'installed_incomplete',
        'installationOperationId': '22222222-2222-4222-8222-222222222222',
        'installationValid': true,
        'installation': {
          'baseId': 'base-kept',
          'gps': {'latitude': 20, 'longitude': -103, 'accuracy': 5},
          'evidence': {'CI079': <Json>[]},
          'answers': <Json>[],
        },
      };
      await h.controller.pull(id);
      var r = h.controller.record(id);
      expect(r.working['status'], 'installed_incomplete');
      expect(r.operations, local['operations']);
      expect(r.photos, local['photos']);
      expect(object(r.working['installation'])['baseId'], 'base-kept');
      final before = clone(r.json);
      remote.documents[id]!['version'] = 7;
      remote.documents[id]!['status'] = 'incomplete';
      await h.controller.pull(id);
      expect(h.controller.record(id).json, before);
    },
  );
}
