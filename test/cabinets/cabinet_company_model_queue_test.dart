import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_controller.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_store.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'harness.dart';

class ModelRemote extends FakeCabinetRemote {
  bool blockDeletion = false;
  @override
  Future<Json> command(String id, Json body) async {
    final result = await super.command(id, body);
    if (body['type'] == 'identity_correct') {
      final c = object(result['cabinet'])
        ..['model'] = body['model']
        ..['automated'] = body['automated'];
      result['cabinet'] = c;
      documents[id] = c;
      receipts[body['operationId']] = result;
    }
    return result;
  }

  @override
  Future<Json> deletePhoto(String id, String photo) async {
    if (blockDeletion) throw failure(503, 'PHOTO_DELETE_NOT_READY');
    return super.deletePhoto(id, photo);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'offline registration, answers and A1 to A3 correction survive restart and lost response in order',
    () async {
      final remote = ModelRemote(), h = Harness();
      await h.open(remote: remote);
      try {
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        final photo = await h.photo(id, 'registration');
        await h.controller.enqueue(id, 'registration_close', {
          'evidence': evidence(photo),
        });
        final part = fixtureCatalog().parts('A1', false).first;
        final capture = {
          'code': part['code'],
          'present': false,
          'observations': 'Pendiente comprobado',
          'evidence': <Json>[],
        };
        await h.controller.patchPart(id, '${part['code']}', capture);
        await h.controller.enqueue(id, 'parts_save', {
          'parts': [capture],
        });
        await h.controller.enqueue(id, 'identity_correct', {
          'model': 'A3',
          'automated': false,
          'reason': 'Modelo comprobado por residente',
        });
        final before = jsonEncode(h.store.read(id)!.operations);
        final diagnostic = jsonEncode(h.controller.syncDiagnostics(id));
        expect(diagnostic, contains('registration_close'));
        expect(diagnostic, isNot(contains('Pendiente comprobado')));
        expect(diagnostic, isNot(contains('accessToken')));
        expect(h.store.read(id)!.working['model'], 'A3');
        expect(h.store.read(id)!.server, isEmpty);
        h.controller.dispose();
        await h.store.box.close();
        h.store = await CabinetStore.open();
        h.controller = CabinetController(
          app: h.app,
          store: h.store,
          remote: remote,
        );
        expect(jsonEncode(h.store.read(id)!.operations), before);
        remote.loseNextResponse = true;
        await h.sync();
        expect(h.store.read(id)!.pending, isNotEmpty);
        expect(File(photo['localPath']).existsSync(), true);
        await h.sync();
        expect(h.store.read(id)!.pending, isEmpty);
        expect(h.store.read(id)!.server['model'], 'A3');
        expect(remote.calls.map((c) => c['type']), [
          'register',
          'registration_close',
          'parts_save',
          'identity_correct',
        ]);
        expect(objects(remote.calls[2]['parts']).single, capture);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'an independent model correction is sent even when a legacy photo deletion is blocked',
    () async {
      final remote = ModelRemote(), h = Harness();
      await h.open(remote: remote);
      try {
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        final photo = await h.photo(id, 'registration');
        await h.controller.enqueue(id, 'registration_close', {
          'evidence': evidence(photo),
        });
        await h.sync();
        final r = clone(h.store.read(id)!.json);
        r['photos'] = [
          {
            ...photo,
            'verified': true,
            'deleting': true,
            'deleteActor': h.controller.actor,
          },
        ];
        await h.store.save(r);
        remote.blockDeletion = true;
        await h.controller.enqueue(id, 'identity_correct', {
          'model': 'A3',
          'automated': false,
          'reason': 'Corrección sin usar la foto pendiente',
        });
        await h.sync();
        expect(h.store.read(id)!.pending, isEmpty);
        expect(h.store.read(id)!.server['model'], 'A3');
        expect(h.store.read(id)!.photos.single['deleting'], true);
        expect(File(photo['localPath']).existsSync(), true);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'company conflict replacement preserves journal, dependent answers and photos',
    () async {
      final h = Harness();
      await h.open(remote: ModelRemote());
      try {
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        final photo = await h.photo(id, 'registration');
        await h.controller.enqueue(id, 'registration_close', {
          'evidence': evidence(photo),
        });
        final r = clone(h.store.read(id)!.json);
        final ops = objects(r['operations']);
        final originalBody = jsonEncode(ops.first['body']);
        final dependent = jsonEncode(ops.last);
        ops.first['state'] = 'conflict';
        ops.first['problem'] = {'code': 'COMPANY_CHANGED'};
        r['operations'] = ops;
        await h.store.save(r);
        await h.controller.reconcileRegistrationCompany(
          id,
          crewId: '22222222-2222-4222-8222-222222222222',
          crewName: 'EMPRESA ACTUAL',
        );
        final after = h.store.read(id)!;
        expect(after.operations.first['state'], 'superseded');
        expect(jsonEncode(after.operations.first['body']), originalBody);
        expect(jsonEncode(after.operations.last), dependent);
        expect(after.pending.map((op) => object(op['body'])['type']), [
          'register',
          'registration_close',
        ]);
        expect(
          object(after.pending.first['body'])['operationId'],
          isNot(object(ops.first['body'])['operationId']),
        );
        expect(
          object(after.working['registrationCompany'])['name'],
          'EMPRESA ACTUAL',
        );
        expect(File(photo['localPath']).existsSync(), true);
        await expectLater(
          h.controller.reconcileRegistrationCompany(
            id,
            crewId: '22222222-2222-4222-8222-222222222222',
            crewName: 'OTRA',
          ),
          throwsStateError,
        );
      } finally {
        await h.close();
      }
    },
  );
  test(
    'registration captures configured company only for an API declaring the capability',
    () async {
      final h = Harness();
      await h.open(remote: ModelRemote());
      try {
        const crew = '22222222-2222-4222-8222-222222222222';
        h.app.session = h.app.session!.copyWith(
          crewId: crew,
          crew: 'EMPRESA TEST',
        );
        await h.store.saveCatalog(
          CabinetCatalog({
            ...fixtureCatalog().json,
            'capabilities': {'registrationCompany': true},
          }),
        );
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        expect(
          object(h.store.read(id)!.pending.single['body'])['expectedCrewId'],
          crew,
        );
        expect(
          object(h.store.read(id)!.working['registrationCompany'])['name'],
          'EMPRESA TEST',
        );
      } finally {
        await h.close();
      }
    },
  );
}
