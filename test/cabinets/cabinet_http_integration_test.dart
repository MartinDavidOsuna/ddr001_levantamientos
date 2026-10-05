import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['CABINETS_TEST_SESSION'];
  test(
    'real Dart/Hive -> local API -> SQL TEST/storage: offline registration, shared evidence, install, review and history',
    () async {
      HttpOverrides.global = null;
      final fixture = object(jsonDecode(File(path!).readAsStringSync()));
      expect(
        object(fixture['identity'])['databaseName'],
        'DDR001_Hidrantes_TEST',
      );
      expect(
        '${fixture['apiCommit']}',
        startsWith('46b0265b9c8698363f3eca73257bc47382c4d8f2'),
      );
      final s = object(fixture['session']);
      final session = FieldSession(
        sessionId: s['sessionId'].toString().toLowerCase(),
        userId: s['userId'].toString().toLowerCase(),
        accessToken: s['accessToken'],
        refreshToken: s['refreshToken'],
        installationId: fixture['installationId'],
        name: 'Mobile TEST',
        email: 'test@example.invalid',
        phone: '7777777777',
        crew: '9',
      );
      final h = Harness();
      await h.open(session: session);
      try {
        final version = object((await h.client.dio.get('/version')).data);
        expect(version['environment'], 'test');
        expect('${version['commit']}', startsWith('46b0265'));
        final catalog = CabinetCatalog(
          await h.controller.remote.get('/catalog'),
        );
        await h.store.saveCatalog(catalog);
        final id = await h.controller.scan(fixture['uid'], 'A4', true);
        final image = File('test/cabinets/fixtures/evidence.jpg');
        final reg = await h.photo(id, 'registration', source: image);
        await h.controller.enqueue(id, 'registration_close', {
          'evidence': evidence(reg),
        });
        final plate = await h.photo(id, 'parts_validation', source: image);
        final parts = catalog
            .parts('A4', true)
            .map(
              (p) => <String, dynamic>{
                'code': p['code'],
                'present': true,
                if (p['serial'] == 'required') 'serial': 'AB00001',
                'evidence': evidence(plate, serial: true),
              },
            )
            .toList();
        await h.controller.enqueue(id, 'parts_save', {'parts': parts});
        await h.controller.enqueue(id, 'parts_validate', {});
        final installationPhoto = await h.photo(
          id,
          'installation',
          source: image,
        );
        final installation = <String, dynamic>{
          'baseId': fixture['baseId'],
          'accountNumber': null,
          'gps': {'latitude': 20.0001, 'longitude': -103.0001, 'accuracy': 5.0},
          'answers': [
            for (final q in catalog.questions.where(
              (q) => q['kind'] == 'check',
            ))
              {
                'code': q['code'],
                'answer': 'yes',
                'evidence': q['code'] == 'CI031'
                    ? evidence(plate, serial: true)
                    : <Json>[],
                if (q['code'] == 'CI031')
                  'serialComponents': parts
                      .where((p) => p['serial'] != null)
                      .map((p) => p['code'])
                      .toList(),
              },
          ],
          'evidence': {
            for (final q in catalog.questions.where(
              (q) => q['kind'] == 'evidence',
            ))
              q['code']: evidence(installationPhoto),
          },
        };
        await h.controller.enqueue(id, 'installation_save', {
          'installation': installation,
        });
        await h.controller.enqueue(id, 'installation_close', {});
        expect(h.store.read(id)!.server, isEmpty);
        expect(h.store.read(id)!.working['status'], 'installed');
        await h.sync();
        expect(
          h.store.read(id)!.pending,
          isEmpty,
          reason: '${h.store.read(id)!.pending}',
        );
        expect(h.store.read(id)!.server['status'], 'installed');
        final finalPhoto = await h.photo(id, 'final_review', source: image);
        await h.controller.enqueue(id, 'final_review', {
          'fieldChecked': true,
          'dossierConsulted': true,
          'installationOperationId': h.store
              .read(id)!
              .server['installationOperationId'],
          'verdict': 'approve',
          'reason': 'Comprobación sintética en TEST',
          'evidence': evidence(finalPhoto),
          'evidenceConfirmed': true,
        });
        await h.sync();
        expect(
          h.store.read(id)!.pending,
          isEmpty,
          reason: '${h.store.read(id)!.pending}',
        );
        expect(h.store.read(id)!.server['status'], 'deliverable');
        final detail = object(
          (await h.controller.remote.get('/$id'))['cabinet'],
        );
        expect(detail, h.store.read(id)!.server);
        expect(objects(detail['parts']).length, 41);
        expect(
          objects(detail['parts'])
              .where((p) => p['serial'] != null)
              .every((p) => p['serial'] == 'AB00001'),
          isTrue,
        );
        final photos = objects(
          (await h.controller.remote.get('/$id/photos', {
            'page': 1,
            'limit': 100,
          }))['items'],
        );
        expect(photos.length, 4);
        final history = await h.controller.history(id);
        expect(history.length, 7);
        expect(history.last['command_type'], 'final_review');
        final operation = object(h.store.read(id)!.operations.last['body']);
        final replay = await h.controller.remote.command(id, operation);
        expect(replay['replayed'], isTrue);
        expect(object(replay['cabinet'])['version'], 7);
        final verify = await h.controller.remote.verify(
          id,
          h.store.read(id)!.photos.map((p) => p['id'] as String).toList(),
        );
        expect(
          objects(verify['items']).every((p) => p['storageVerified'] == true),
          isTrue,
        );
        // Real correction invalidates approval without losing the original evidence.
        await h.controller.enqueue(id, 'parts_save', {
          'parts': parts,
          'reason': 'Comprobación posterior sintética TEST',
        });
        await h.controller.enqueue(id, 'parts_validate', {});
        await h.controller.enqueue(id, 'installation_close', {});
        await h.sync();
        expect(
          h.store.read(id)!.pending,
          isEmpty,
          reason: '${h.store.read(id)!.pending}',
        );
        expect(h.store.read(id)!.server['status'], 'installed');
        expect(h.store.read(id)!.server['approval'], isNull);
        final correctionPhoto = await h.photo(
          id,
          'final_review',
          source: image,
        );
        await h.controller.enqueue(id, 'final_review', {
          'fieldChecked': true,
          'dossierConsulted': true,
          'installationOperationId': h.store
              .read(id)!
              .server['installationOperationId'],
          'verdict': 'correction_required',
          'reason': 'Revisión sintética pendiente de corrección',
          'evidence': evidence(correctionPhoto),
          'evidenceConfirmed': true,
        });
        await h.sync();
        expect(
          h.store.read(id)!.pending,
          isEmpty,
          reason: '${h.store.read(id)!.pending}',
        );
        final negative = object(h.store.read(id)!.server['reviewCorrection']);
        expect(negative, isNotEmpty);
        final resolvedPhoto = await h.photo(id, 'final_review', source: image);
        await h.controller.enqueue(id, 'final_review', {
          'fieldChecked': true,
          'dossierConsulted': true,
          'installationOperationId': h.store
              .read(id)!
              .server['installationOperationId'],
          'verdict': 'approve',
          'reason': 'Corrección comprobada sintética TEST',
          'evidence': evidence(resolvedPhoto),
          'evidenceConfirmed': true,
          'resolvesReview': {
            'operationId': negative['operationId'],
            'reason': 'Residente confirma subsanación en prueba TEST',
          },
        });
        await h.sync();
        expect(
          h.store.read(id)!.pending,
          isEmpty,
          reason: '${h.store.read(id)!.pending}',
        );
        final finalDetail = object(
          (await h.controller.remote.get('/$id'))['cabinet'],
        );
        expect(finalDetail, h.store.read(id)!.server);
        expect(finalDetail['status'], 'deliverable');
        final finalHistory = await h.controller.history(id);
        expect(finalHistory.length, 12);
        final log = {
          'cabinetId': id,
          'uid': fixture['uid'],
          'apiCommit': version['commit'],
          'database': fixture['identity'],
          'version': finalDetail['version'],
          'status': finalDetail['status'],
          'parts': objects(detail['parts']).length,
          'photos': h.store.read(id)!.photos.length,
          'historyOperations': finalHistory.length,
          'approvalInvalidationAndNegativeReviewResolved': true,
          'allPhotosVerified': true,
        };
        await File('.test-cabinets/result.json').writeAsString(jsonEncode(log));
        // Retain the synthetic record and its references as TEST evidence, no deletion.
      } finally {
        await h.close();
      }
    },
    skip: path == null
        ? 'Set CABINETS_TEST_SESSION after identity-verified TEST preparation'
        : false,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
