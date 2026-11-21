import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_controller.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_cabinet_recovery.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/recovery/cabinet_backup.dart'
    show fileHash, verifyBundle, extractBundle;
import 'harness.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_legacy_scope.dart';
import 'package:ddr001_levantamientos/core/media/photo_capture_service.dart';
import 'package:ddr001_levantamientos/core/media/camera_capture_broker.dart';
import 'cabinet_api_test.dart' show Adapter, response;
import 'consistency_test.dart' show syntheticUid;

const pilotId = 'b0000000-0000-4000-8000-000000000006';
const photoId = 'b1000000-0000-4000-8000-000000000006';
String opId(int n) =>
    'b2000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';

class LegacyRemote extends FakeCabinetRemote {
  String selectedId = pilotId;
  final photoRows = <String, Json>{};
  final traces = <String>[];
  bool allowOrdinaryOther = false,
      incompleteValidation = false,
      unavailable = false;
  bool lostCommand = false, lostUpload = false, genericReceipt404 = false;
  bool verificationPending = false, verifyUnavailable = false;
  bool wireReceiptFlags = false;
  bool normalizeChecklist = false;
  Json? catalogOverride;
  String? loseOperation;
  void Function()? afterRead;
  Future<void> Function()? beforeCommand, beforeUpload;
  @override
  Future<Json> get(String path, [Json? query]) async {
    traces.add('GET $path');
    if (unavailable) throw failure(503, 'SIMULATED_OFFLINE');
    if (path == '/catalog') {
      if (catalogOverride != null) return clone(catalogOverride!);
      return {
        ...fixtureCatalog().json,
        'partsReviewPolicy': jsonDecode(
          File(
            'test/cabinets/fixtures/parts-review-policy.json',
          ).readAsStringSync(),
        ),
      };
    }
    if (path == '/resolve') return {'cabinet': clone(documents[selectedId]!)};
    if (path == '/$selectedId/photos') {
      return {
        'items': photoRows.values
            .where(
              (p) =>
                  p['_testCabinet'] == null || p['_testCabinet'] == selectedId,
            )
            .map((p) => clone(p)..remove('storage_verified'))
            .toList(),
      };
    }
    if (genericReceipt404 && path.contains('/operations/')) {
      throw failure(404, 'ROUTE_MISSING');
    }
    final result = clone(await super.get(path, query));
    afterRead?.call();
    if (wireReceiptFlags && path.contains('/operations/')) {
      result['replayed'] = true;
    }
    return result;
  }

  @override
  Future<Json> upload(String id, Json photo) async {
    traces.add('UPLOAD $id/${photo['id']}');
    await beforeUpload?.call();
    uploads[photo['id']] = (uploads[photo['id']] ?? 0) + 1;
    photoRows[photo['id']] = {
      'photo_id': photo['id'],
      '_testCabinet': id,
      'server_sha256': '0' * 64,
      'client_sha256': object(photo['metadata'])['clientSha256'],
      'metadata': clone(object(photo['metadata'])),
      'actor_user_id': photo['actor'],
      'storage_verified': false,
    };
    if (lostUpload) {
      lostUpload = false;
      throw failure(503, 'LOST_UPLOAD_RESPONSE');
    }
    return {};
  }

  @override
  Future<Json> verify(String id, List<String> ids) async {
    traces.add('VERIFY $id');
    if (verifyUnavailable) throw failure(503, 'STORAGE_UNAVAILABLE');
    for (final p in ids) {
      if (photoRows[p] != null && !verificationPending) {
        photoRows[p]!['storage_verified'] = true;
      }
    }
    return {
      'items': ids
          .map(
            (p) => {
              'photoId': p.toUpperCase(), // SQL uniqueidentifier spelling
              'storageVerified': photoRows[p]?['storage_verified'] == true,
            },
          )
          .toList(),
    };
  }

  @override
  Future<Json> command(String id, Json body) async {
    traces.add('COMMAND $id/${body['type']}');
    await beforeCommand?.call();
    if (id != selectedId && allowOrdinaryOther) return super.command(id, body);
    if (id != selectedId || body['type'] == 'register') {
      throw StateError('Out of recovery scope');
    }
    calls.add(clone(body));
    if (receipts[body['operationId']] != null) {
      return clone(receipts[body['operationId']]!);
    }
    final doc = clone(documents[id]!);
    if (conflictId == id || doc['version'] != body['expectedVersion']) {
      throw failure(409, 'VERSION_CONFLICT');
    }
    final type = body['type'];
    if (type == 'registration_close') {
      if (doc['status'] != 'draft' ||
          objects(body['evidence']).isEmpty ||
          objects(body['evidence']).any(
            (e) =>
                photoRows[e['photoId']]?['storage_verified'] != true ||
                e['confirmed'] != true,
          )) {
        throw failure(422, 'PHOTO_NOT_VERIFIED');
      }
      doc['registrationEvidence'] = body['evidence'];
      doc['status'] = 'registered';
    } else if (type == 'parts_save') {
      if (!['registered', 'incomplete'].contains(doc['status'])) {
        throw failure(422, 'REGISTRATION_REQUIRED');
      }
      if (body['partsReviewPolicyVersion'] != null) {
        doc['partsReviewPolicyVersion'] = body['partsReviewPolicyVersion'];
        doc['partsReviewPolicy'] = jsonDecode(
          File(
            'test/cabinets/fixtures/parts-review-policy.json',
          ).readAsStringSync(),
        );
        doc['partDefinitions'] = cabinetReviewDefinitions(
          doc,
          object(doc['partsReviewPolicy']),
        );
      }
      final incomingParts = normalizeChecklist
          ? objects(body['parts'])
                .map(
                  (p) => {
                    for (final key in [
                      'code',
                      'present',
                      'serial',
                      'serialException',
                      'reason',
                      'observations',
                      'evidence',
                    ])
                      if (p.containsKey(key))
                        key:
                            (['serial', 'reason'].contains(key) &&
                                p[key] is String)
                            ? (p[key] as String).trim()
                            : p[key],
                  },
                )
                .toList()
          : body['parts'];
      final accumulated = objects(doc['parts']);
      for (final part in objects(incomingParts)) {
        final index = accumulated.indexWhere((p) => p['code'] == part['code']);
        if (index < 0) {
          accumulated.add(part);
        } else {
          accumulated[index] = part;
        }
      }
      doc['parts'] = accumulated;
      doc['status'] = 'incomplete';
      doc['partsValidated'] = false;
    } else if (type == 'parts_validate') {
      if (doc['status'] != 'incomplete' || partsPending(doc).isNotEmpty) {
        throw failure(422, 'PARTS_PENDING');
      }
      doc['partsValidated'] = !incompleteValidation;
      doc['status'] = incompleteValidation ? 'incomplete' : 'validated';
    } else {
      throw failure(422, 'UNSUPPORTED');
    }
    doc['version'] = (doc['version'] as int) + 1;
    documents[id] = doc;
    final receipt = {'cabinet': clone(doc)};
    receipts[body['operationId']] = receipt;
    if (lostCommand || loseOperation == body['operationId']) {
      loseOperation = null;
      lostCommand = false;
      throw failure(503, 'LOST_RESPONSE');
    }
    return {...clone(receipt), if (wireReceiptFlags) 'replayed': false};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late LegacyRemote remote;
  late LegacyCabinetRecovery recovery;
  late String other;
  late Json original;
  setUp(() async {
    remote = LegacyRemote();
    h = Harness();
    await h.open(remote: remote);
    final root = await h.directory.resolveSymbolicLinks();
    final dir = Directory('$root/cabinets/$pilotId/evidence');
    await dir.create(recursive: true);
    for (final suffix in ['source', 'upload', 'thumb']) {
      await File('${dir.path}/$photoId.$suffix.jpg').writeAsBytes(
        await File('test/cabinets/fixtures/evidence.jpg').readAsBytes(),
      );
    }
    final upload = '${dir.path}/$photoId.upload.jpg';
    final defs = fixtureCatalog().parts('A1', false);
    final parts = defs
        .map(
          (d) => <String, dynamic>{
            'code': d['code'],
            'present': true,
            if (d['serial'] == 'required') 'serial': 'TEST-001',
            'evidence': <Json>[],
          },
        )
        .toList();
    final server = <String, dynamic>{
      'cabinetId': pilotId,
      'uid': 'AQ26000068',
      'model': 'A1',
      'automated': false,
      'version': 1,
      'catalogVersion': fixtureCatalog().version,
      'status': 'draft',
      'partDefinitions': defs,
      'parts': <Json>[],
    };
    remote.documents[pilotId] = clone(server);
    final register = {
      'operationId': opId(0),
      'expectedVersion': 0,
      'type': 'register',
      'uid': 'AQ26000068',
    };
    remote.receipts[opId(0)] = {'cabinet': clone(server)};
    original = {
      'id': pilotId,
      'actor': h.controller.actor,
      'server': clone(server),
      'working': {
        ...clone(server),
        'status': 'validated',
        'partsValidated': true,
        'parts': parts,
      },
      'dirty': true,
      'photos': [
        {
          'id': photoId,
          'actor': h.controller.actor,
          'localPath': upload,
          'thumbnailPath': '${dir.path}/$photoId.thumb.jpg',
          'verified': false,
          'metadata': {
            'photoId': photoId,
            'context': 'registration',
            'clientSha256': await fileHash(File(upload)),
            'capturedAt': '2026-10-06T12:00:00.000Z',
            'latitude': 20,
            'longitude': -103,
            'accuracy': 5,
          },
        },
      ],
      'operations': [
        {
          'actor': h.controller.actor,
          'state': 'done',
          'body': register,
          'result': clone(remote.receipts[opId(0)]!),
        },
        for (var n = 1; n <= 3; n++)
          {
            'actor': h.controller.actor,
            'state': 'queued',
            'error': 'historical error retained',
            'body': {
              'operationId': opId(n),
              'expectedVersion': n,
              'capturedAt': '2026-10-06T12:00:00.000Z',
              'type': [
                'registration_close',
                'parts_save',
                'parts_validate',
              ][n - 1],
              if (n == 1)
                'evidence': [
                  {'photoId': photoId, 'confirmed': true},
                ],
              if (n == 2) 'parts': parts,
            },
          },
      ],
    };
    await h.store.save(original);
    other = await h.controller.scan('AQ26000017', 'A1', false);
    recovery = LegacyCabinetRecovery(
      h.controller,
      pilotId,
      cabinetAllowlist: {pilotId},
    );
  });
  tearDown(() async {
    if (!recovery.busy) {
      await recovery.close();
    }
    await h.close();
  });
  Future<void> execute() => recovery.execute(
    operationAllowlist: recovery.operationAllowlist,
    explicitlyConfirmed: true,
  );
  Future<void> oversizedPilot({
    bool all22 = false,
    String? firstPhotoId,
  }) async {
    await recovery.close();
    final record = clone(original);
    // Synthetic historical catalogue: 24 durable captures, not a claim about
    // the worker's unavailable catalogue. Existing captures are not rewritten.
    final working = object(record['working']);
    final defs = objects(working['partDefinitions']);
    final parts = objects(working['parts']);
    while (defs.length < 24) {
      final code = 'HISTORICAL-TEST-${defs.length}';
      defs.add({'code': code, 'serial': 'optional'});
      parts.add({'code': code, 'present': true, 'evidence': <Json>[]});
    }
    working['partDefinitions'] = defs;
    working['parts'] = parts;
    record['working'] = working;
    record['server'] = {...object(record['server']), 'partDefinitions': defs};
    remote.documents[pilotId]!['partDefinitions'] = defs;
    final photos = <Json>[];
    final root = await h.directory.resolveSymbolicLinks();
    final seed = await File(
      'test/cabinets/fixtures/legacy-12000x6752.jpg',
    ).readAsBytes();
    final sizes = [17310456, 15942453, 19773874, 20242426, 20256051];
    for (var i = 0; i < 5; i++) {
      final id = i == 0 && firstPhotoId != null
          ? firstPhotoId
          : 'b1000000-0000-4000-8000-${(i + 6).toString().padLeft(12, '0')}';
      final prefix = '$root/cabinets/$pilotId/evidence/$id';
      final source = File('$prefix.source.jpg');
      await source.writeAsBytes(seed);
      final handle = await source.open(mode: FileMode.append);
      await handle.truncate(all22 ? sizes[i] : seed.length);
      await handle.close();
      await source.copy('$prefix.upload.jpg');
      await File(
        'test/cabinets/fixtures/legacy-derived.jpg',
      ).copy('$prefix.thumb.jpg');
      photos.add({
        ...clone(objects(record['photos']).first),
        'id': id,
        'localPath': '$prefix.upload.jpg',
        'thumbnailPath': '$prefix.thumb.jpg',
        'metadata': {
          ...object(objects(record['photos']).first['metadata']),
          'photoId': id,
          'clientSha256': await fileHash(source),
        },
      });
    }
    record['photos'] = photos;
    final old = objects(record['operations']);
    record['operations'] = [
      old.first,
      for (var i = 0; i < 4; i++)
        {
          ...clone(
            old[i == 0
                ? 1
                : i == 3
                ? 3
                : 2],
          ),
          'state': i == 0 ? 'conflict' : 'queued',
          if (i == 0)
            'diagnostic': {
              'httpStatus': 413,
              'path': '/construction/cabinets/$pilotId/photos',
            },
          'body': {
            ...object(
              old[i == 0
                  ? 1
                  : i == 3
                  ? 3
                  : 2]['body'],
            ),
            'operationId': LegacyCabinetRecovery.pilotOperations[i],
            if (i == 1 || i == 2) 'parts': parts,
            'expectedVersion': i + 1,
            if (i == 0)
              'evidence': photos
                  .map((p) => {'photoId': p['id'], 'confirmed': true})
                  .toList(),
          },
        },
    ];
    await h.store.save(record);
    original = clone(record);
    if (all22) {
      for (final uid in legacyCabinetUids.where((u) => u != legacyPilotUid)) {
        await h.controller.scan(uid, 'A1', false);
      }
      for (var i = 30; i < 40; i++) {
        await h.controller.scan(syntheticUid(i), 'A1', false);
      }
    }
    recovery = LegacyCabinetRecovery(
      h.controller,
      pilotId,
      cabinetAllowlist: {pilotId},
      derivativeEncoder: (s, t, w, h, q) async {
        await File('test/cabinets/fixtures/legacy-derived.jpg').copy(t);
      },
    );
  }

  Future<void> resumeOversized() async {
    await recovery.close();
    recovery = LegacyCabinetRecovery(
      h.controller,
      pilotId,
      cabinetAllowlist: {pilotId},
      derivativeEncoder: (s, t, w, h, q) async {
        throw StateError('Existing immutable derivatives must be reused');
      },
    );
    await recovery.prepare(prepareDerivatives: true);
  }

  test(
    'oversized five exact-size JPEGs, four historical commands, 22 dossiers: isolated preparation and ordered recovery',
    () async {
      await oversizedPilot(all22: true);
      final others = h.store
          .all()
          .where((r) => r.id != pilotId)
          .map((r) => clone(r.json))
          .toList();
      expect(others.length, 21);
      expect(objects(h.store.read(pilotId)!.working['parts']).length, 24);
      await recovery.prepare(prepareDerivatives: true);
      expect(recovery.blockers, isEmpty);
      expect(recovery.derivatives.length, 5);
      expect(remote.uploads, isEmpty);
      expect(remote.calls, isEmpty);
      expect(h.store.read(pilotId)!.operations, original['operations']);
      for (final d in recovery.derivatives.values) {
        await d.verify();
        expect(d.manifest['bytes'], lessThan(6 * 1024 * 1024));
        expect(
          d.transport['metadata']['clientSha256'],
          isNot(d.photo['metadata']['clientSha256']),
        );
        expect(d.transport['id'], d.photo['id']);
      }
      await execute();
      expect(remote.documents[pilotId]!['status'], 'validated');
      expect(remote.documents[pilotId]!['version'], 5);
      expect(
        remote.calls.map((b) => b['operationId']),
        LegacyCabinetRecovery.pilotOperations,
      );
      expect(remote.uploads.values, everyElement(1));
      expect(remote.uploads.length, 5);
      expect(h.store.read(pilotId)!.working, original['working']);
      expect(
        h.store.read(pilotId)!.operations.map((o) => o['body']),
        objects(original['operations']).map((o) => o['body']),
      );
      expect(
        h.store.read(pilotId)!.operations[1]['diagnostic'],
        objects(original['operations'])[1]['diagnostic'],
      );
      expect(
        h.store.all().where((r) => r.id != pilotId).map((r) => r.json),
        others,
      );
      await recovery.backup!.verify();
    },
    timeout: const Timeout(Duration(minutes: 6)),
  );
  test(
    'checklist contractual normalization resumes from durable v3 without duplicate commands',
    () async {
      await oversizedPilot();
      final record = h.store.read(pilotId)!.json;
      final operations = objects(record['operations']);
      for (final op in operations) {
        final body = object(op['body']);
        if (body['type'] == 'parts_save') {
          final parts = objects(body['parts']);
          for (final part in parts) {
            part['observations'] = 'observación intacta';
            part['reason'] = '  razón sintética  ';
          }
          body['parts'] = parts;
          op['body'] = body;
        }
      }
      record['operations'] = operations;
      record['working'] = {
        ...object(record['working']),
        'parts': object(operations[3]['body'])['parts'],
      };
      await h.store.save(record);
      remote.normalizeChecklist = true;
      remote.wireReceiptFlags = true;
      await recovery.prepare(prepareDerivatives: true);
      expect(recovery.blockers, isEmpty);
      final originals = h.store
          .read(pilotId)!
          .operations
          .map((o) => clone(object(o['body'])))
          .toList();
      remote.loseOperation = LegacyCabinetRecovery.pilotOperations[1];
      await expectLater(execute(), throwsA(isA<DioException>()));
      expect(remote.documents[pilotId]!['version'], 3);
      expect(
        remote.receipts.containsKey(LegacyCabinetRecovery.pilotOperations[1]),
        isTrue,
      );
      expect(
        remote.receipts.containsKey(LegacyCabinetRecovery.pilotOperations[2]),
        isFalse,
      );
      expect(remote.uploads.values, everyElement(1));
      // A real changed value in a durable receipt must stop before any resend.
      final receiptKey = LegacyCabinetRecovery.pilotOperations[1];
      final goodReceipt = clone(remote.receipts[receiptKey]!);
      final badReceipt = clone(goodReceipt);
      (object(badReceipt['cabinet'])['parts'] as List).first['present'] = false;
      remote.receipts[receiptKey] = badReceipt;
      final callsBefore = remote.calls.length;
      await expectLater(
        resumeOversized(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'safe mismatch fields',
            contains('parts[0].present'),
          ),
        ),
      );
      expect(remote.calls.length, callsBefore);
      expect(recovery.canExecute, isFalse);
      remote.receipts[receiptKey] =
          goodReceipt; // restore synthetic remote fixture
      await resumeOversized();
      expect(recovery.blockers, isEmpty);
      await execute();
      expect(
        remote.calls.map((b) => b['operationId']).toList(),
        LegacyCabinetRecovery.pilotOperations,
      );
      expect(remote.documents[pilotId]!['version'], 5);
      expect(remote.documents[pilotId]!['status'], 'validated');
      expect(remote.uploads.values, everyElement(1));
      expect(
        h.store
            .read(pilotId)!
            .operations
            .map((o) => object(o['body']))
            .toList(),
        originals,
      );
      await recovery.backup!.verify();
    },
  );

  for (final loseSecond in [false, true]) {
    test(
      'RC13 A3 district9 producer15 from v3 with 22 dossiers lost=$loseSecond',
      () async {
        await oversizedPilot();
        final contract = object(
          jsonDecode(
            File(
              'test/cabinets/fixtures/rc13-a3-contract.json',
            ).readAsStringSync(),
          ),
        );
        final policy = object(contract['policy']);
        final defs = objects(contract['definitions']);
        final captures = defs
            .map(
              (d) => <String, dynamic>{
                'code': d['code'],
                'present': true,
                'evidence': <Json>[],
                if (d['serial'] == 'required')
                  'serial': '  SYNTHETIC-RC13-SERIAL  ',
                if (d['serial'] == 'required') 'serialException': null,
              },
            )
            .toList();
        final district = captures
            .where(
              (p) =>
                  object(object(policy['parts'])[p['code']])['side'] ==
                  'district',
            )
            .toList();
        final producer = captures
            .where(
              (p) =>
                  object(object(policy['parts'])[p['code']])['side'] ==
                  'producer',
            )
            .toList();
        expect(district.length, 9);
        expect(producer.length, 15);
        final record = clone(h.store.read(pilotId)!.json);
        final model = {
          'model': 'A3',
          'automated': false,
          'catalogVersion': contract['version'],
          'partDefinitions': defs,
          'partsReviewPolicyVersion': policy['version'],
          'partsReviewPolicy': policy,
        };
        record['working'] = {
          ...object(record['working']),
          ...model,
          'parts': captures,
        };
        record['server'] = {...object(record['server']), ...model};
        final ops = objects(record['operations']);
        for (var i = 2; i <= 3; i++) {
          ops[i]['body'] = {
            ...object(ops[i]['body']),
            'parts': i == 2 ? district : producer,
            'partsReviewPolicyVersion': policy['version'],
          };
        }
        record['operations'] = ops;
        await h.store.save(record);
        remote.documents[pilotId] = {...remote.documents[pilotId]!, ...model};
        remote.catalogOverride = {
          ...fixtureCatalog().json,
          'version': contract['version'],
          'partsReviewPolicy': policy,
        };
        await h.store.saveCatalog(
          CabinetCatalog(remote.catalogOverride!),
          current: false,
        );
        remote.normalizeChecklist = true;
        remote.wireReceiptFlags = true;
        await recovery.prepare(prepareDerivatives: true);
        expect(recovery.blockers, isEmpty);
        // Seed already accepted remote evidence/receipts, entirely in the fake.
        for (final d in recovery.derivatives.values) {
          await remote.upload(pilotId, clone(d.transport));
        }
        await remote.verify(
          pilotId,
          record['photos'].map<String>((p) => p['id'] as String).toList(),
        );
        await remote.command(pilotId, object(ops[1]['body']));
        await remote.command(pilotId, object(ops[2]['body']));
        for (final uid in legacyCabinetUids.where((u) => u != legacyPilotUid)) {
          await recovery.close();
          await h.controller.scan(uid, 'A1', false);
        }
        for (var i = 30; i < 40; i++) {
          await h.controller.scan(syntheticUid(i), 'A1', false);
        }
        final others = h.store
            .all()
            .where((r) => r.id != pilotId)
            .map((r) => clone(r.json))
            .toList();
        expect(h.store.all().length, 22);
        remote.calls.clear();
        remote.uploads.clear();
        remote.traces.clear();
        await resumeOversized();
        expect(recovery.blockers, isEmpty);
        expect(recovery.checklistPlan!.requiredCount, 24);
        expect(recovery.checklistPlan!.firstCount, 9);
        expect(recovery.checklistPlan!.secondCount, 15);
        expect(recovery.confirmedVersions.values.toSet(), {2, 3});
        expect(remote.traces.every((t) => t.startsWith('GET ')), isTrue);
        if (loseSecond) {
          remote.loseOperation = LegacyCabinetRecovery.pilotOperations[2];
          await expectLater(execute(), throwsA(isA<DioException>()));
          expect(remote.documents[pilotId]!['version'], 4);
          await resumeOversized();
        }
        await execute();
        expect(
          remote.calls.map((b) => b['operationId']).toList(),
          LegacyCabinetRecovery.pilotOperations.skip(2).toList(),
        );
        expect(remote.uploads, isEmpty);
        expect(remote.documents[pilotId]!['version'], 5);
        expect(remote.documents[pilotId]!['partsValidated'], true);
        expect(objects(remote.documents[pilotId]!['parts']).length, 24);
        expect(
          h.store
              .all()
              .where((r) => r.id != pilotId)
              .map((r) => r.json)
              .toList(),
          others,
        );
        expect(
          h.store.read(pilotId)!.operations.map((o) => o['body']).toList(),
          ops.map((o) => o['body']).toList(),
        );
        await recovery.backup!.verify();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }

  for (final lost in ['upload', 'command']) {
    test(
      'oversized lost $lost response resumes with identical IDs and no duplicated bytes/commands',
      () async {
        await oversizedPilot();
        await recovery.prepare(prepareDerivatives: true);
        remote.lostUpload = lost == 'upload';
        remote.lostCommand = lost == 'command';
        await expectLater(execute(), throwsA(isA<DioException>()));
        await resumeOversized();
        expect(recovery.blockers, isEmpty);
        await execute();
        expect(remote.documents[pilotId]!['version'], 5);
        expect(remote.calls.length, 4);
        expect(remote.uploads.values, everyElement(1));
        await recovery.backup!.verify();
      },
    );
  }
  for (final unavailable in [false, true]) {
    test(
      'storage confirmation ${unavailable ? '503' : 'pending'} after one of five: retry reads inventory without upload duplication',
      () async {
        await oversizedPilot();
        await recovery.prepare(prepareDerivatives: true);
        remote.verificationPending = !unavailable;
        remote.verifyUnavailable = unavailable;
        await expectLater(
          execute(),
          throwsA(anyOf(isA<StateError>(), isA<DioException>())),
        );
        expect(remote.photoRows.length, 1);
        expect(remote.uploads.length, 1);
        expect(remote.calls, isEmpty);
        expect(remote.documents[pilotId]!['version'], 1);
        expect(h.store.read(pilotId)!.operations, original['operations']);
        expect(recovery.completed, false);
        expect(recovery.remoteVerifiedPhotos, isNull);
        final oldPhotos = clone({'photos': h.store.read(pilotId)!.photos});
        await recovery.backup!.verify();
        if (!unavailable) {
          // A second explicit authorization while verification is still negative
          // must consult inventory and stop again, never resend the uploaded file.
          await expectLater(execute(), throwsStateError);
          expect(remote.uploads.length, 1);
          expect(remote.uploads.values, everyElement(1));
          expect(remote.calls, isEmpty);
        }
        remote.verificationPending = false;
        remote.verifyUnavailable = false;
        if (unavailable) await resumeOversized();
        expect(remote.calls, isEmpty);
        expect(remote.uploads.length, 1);
        expect(clone({'photos': h.store.read(pilotId)!.photos}), oldPhotos);
        await execute();
        expect(remote.uploads.length, 5);
        expect(remote.uploads.values, everyElement(1));
        expect(
          remote.calls.map((b) => b['operationId']),
          LegacyCabinetRecovery.pilotOperations,
        );
        expect(remote.documents[pilotId]!['version'], 5);
        await recovery.backup!.verify();
      },
    );
  }
  for (final scenario in ['confirmed', 'hash mismatch', 'storage failure']) {
    test(
      'RC12 production photoId uppercase, existing derivative: $scenario',
      () async {
        const first = '7b233347-8b2d-448f-8ebb-0f4fb41af98d';
        await oversizedPilot(firstPhotoId: first);
        remote.wireReceiptFlags = true;
        remote.documents[pilotId]!['cabinetId'] = pilotId.toUpperCase();
        await recovery.prepare(prepareDerivatives: true);
        final transport = recovery.derivatives[first]!.transport;
        final actualHash = object(transport['metadata'])['clientSha256'];
        expect(
          actualHash,
          isNot(
            object(
              h.store.read(pilotId)!.photos.first['metadata'],
            )['clientSha256'],
          ),
        );
        // Only the identifier is productive. Image bytes, actor and hashes are synthetic.
        remote.photoRows[first] = {
          'photo_id': first.toUpperCase(),
          'client_sha256': scenario == 'hash mismatch' ? 'f' * 64 : actualHash,
          'server_sha256': '0' * 64,
          'metadata': clone(object(transport['metadata'])),
          'actor_user_id': transport['actor'],
          'storage_verified': scenario != 'storage failure',
        };
        if (scenario == 'hash mismatch') {
          await expectLater(resumeOversized(), throwsStateError);
          expect(remote.uploads, isEmpty);
          expect(remote.calls, isEmpty);
          return;
        }
        await resumeOversized();
        expect(recovery.blockers, isEmpty);
        expect(recovery.remoteMatchedPhotos, 1);
        expect(remote.calls, isEmpty);
        expect(remote.uploads, isEmpty);
        remote.verificationPending = scenario == 'storage failure';
        if (scenario == 'storage failure') {
          await expectLater(execute(), throwsStateError);
          expect(remote.uploads, isEmpty);
          expect(remote.calls, isEmpty);
          expect(remote.documents[pilotId]!['version'], 1);
        } else {
          await execute();
          expect(remote.uploads.containsKey(first), false);
          expect(remote.uploads.length, 4);
          expect(remote.uploads.values, everyElement(1));
          expect(remote.documents[pilotId]!['status'], 'validated');
          expect(remote.documents[pilotId]!['version'], 5);
          expect(
            remote.calls.map((b) => b['operationId']),
            LegacyCabinetRecovery.pilotOperations,
          );
          expect(
            h.store.read(pilotId)!.operations.map((o) => o['body']),
            objects(original['operations']).map((o) => o['body']),
          );
        }
        await recovery.backup!.verify();
        for (final d in recovery.derivatives.values) {
          await d.verify();
        }
      },
    );
  }
  test('oversized changed remote progress blocks before any upload', () async {
    await oversizedPilot();
    await recovery.prepare(prepareDerivatives: true);
    remote.documents[pilotId]!['version'] = 2;
    await expectLater(execute(), throwsStateError);
    expect(remote.uploads, isEmpty);
    expect(remote.calls, isEmpty);
  });
  test(
    'oversized corrupt derivative blocks before transmission and preserves historical bytes',
    () async {
      await oversizedPilot();
      await recovery.prepare(prepareDerivatives: true);
      await File(
        recovery.derivatives.values.first.transport['localPath'],
      ).writeAsBytes([0, 1, 2]);
      await expectLater(execute(), throwsStateError);
      expect(remote.uploads, isEmpty);
      await recovery.backup!.verify();
    },
  );
  for (final invalid in ['payload', 'metadata']) {
    test(
      'oversized incompatible $invalid cannot authorize transmission',
      () async {
        await oversizedPilot();
        final record = clone(h.store.read(pilotId)!.json);
        if (invalid == 'payload') {
          final ops = objects(record['operations']);
          final body = object(ops[1]['body']);
          body['unsupported'] = true;
          ops[1]['body'] = body;
          record['operations'] = ops;
        } else {
          final photos = objects(record['photos']);
          final meta = object(photos.first['metadata']);
          meta['unsupported'] = true;
          photos.first['metadata'] = meta;
          record['photos'] = photos;
        }
        await h.store.save(record);
        await recovery.prepare(prepareDerivatives: true);
        expect(recovery.canExecute, false);
        expect(recovery.blockers, isNotEmpty);
        expect(remote.uploads, isEmpty);
        expect(remote.calls, isEmpty);
      },
    );
  }
  for (final invalid in ['session', 'closed']) {
    test('oversized $invalid stops before first transmission', () async {
      await oversizedPilot();
      await recovery.prepare(prepareDerivatives: true);
      if (invalid == 'session') {
        h.app.session = testSession(
          user: '22222222-2222-4222-8222-222222222222',
        );
      } else {
        await recovery.close();
      }
      await expectLater(execute(), throwsStateError);
      expect(remote.uploads, isEmpty);
      expect(remote.calls, isEmpty);
    });
  }
  for (final status in [409, 413, 422, 503]) {
    test(
      'oversized HTTP $status stops sequence retaining original conflict and payload',
      () async {
        await oversizedPilot();
        await recovery.prepare(prepareDerivatives: true);
        remote.beforeCommand = () async =>
            throw failure(status, 'TEST_REJECTION');
        await expectLater(execute(), throwsA(isA<DioException>()));
        expect(remote.documents[pilotId]!['version'], 1);
        expect(h.store.read(pilotId)!.operations, original['operations']);
        await recovery.backup!.verify();
      },
    );
  }
  test(
    'pilot draft/v1 to validated preserves identity payloads checklist originals and other dossier',
    () async {
      final otherBefore = clone(h.store.read(other)!.json);
      final working = clone(h.store.read(pilotId)!.working);
      await recovery.prepare();
      expect(recovery.blockers, isEmpty);
      expect(remote.calls, isEmpty);
      expect(remote.uploads, isEmpty);
      final manifest = await verifyBundle(
        File('${recovery.backupPath}/backup.ddr.jsonl'),
      );
      expect(manifest['complete'], true);
      expect(manifest['dossiers'], 1);
      await h.controller.synchronize(force: true);
      await h.controller.refresh();
      h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await h.controller.recoverPhotos();
      await h.controller.recoverPhotoGps();
      expect(remote.calls, isEmpty);
      expect(h.store.read(other)!.json, otherBefore);
      await execute();
      expect(remote.documents[pilotId]!['status'], 'validated');
      expect(remote.documents[pilotId]!['version'], 4);
      expect(remote.calls.map((b) => b['operationId']), [
        opId(1),
        opId(2),
        opId(3),
      ]);
      expect(remote.uploads[photoId], 1);
      expect(h.store.read(other)!.json, otherBefore);
      expect(h.store.read(pilotId)!.working, working);
      expect(
        h.store.read(pilotId)!.operations[1]['error'],
        'historical error retained',
      );
      expect(
        h.store.read(pilotId)!.operations.map((o) => o['body']).toList(),
        objects(original['operations']).map((o) => o['body']).toList(),
      );
      await recovery.backup!.verify();
    },
  );
  test(
    'accepted incomplete validation persists receipt and never claims validated',
    () async {
      await recovery.prepare();
      remote.incompleteValidation = true;
      await expectLater(execute(), throwsStateError);
      final record = h.store.read(pilotId)!;
      expect(record.server['status'], 'incomplete');
      expect(record.operations.last['state'], 'done');
      expect(record.operations.last['result'], remote.receipts[opId(3)]);
      expect(record.json['legacyRecoveryCompleted'], isNot(true));
      expect(recovery.completed, false);
      expect(record.working, original['working']);
    },
  );
  test(
    'HTTP409 stops without rewriting historical commands and audits status',
    () async {
      await recovery.prepare();
      remote.conflictId = pilotId;
      await expectLater(execute(), throwsA(isA<DioException>()));
      final record = h.store.read(pilotId)!;
      expect(remote.calls.length, 1);
      expect(
        record.operations.skip(1).map((o) => o['body']),
        objects(original['operations']).skip(1).map((o) => o['body']),
      );
      expect(record.operations[1]['error'], 'historical error retained');
      expect(
        objects(record.json['legacyRecoveryEvents']).last['httpStatus'],
        409,
      );
      expect(record.server['version'], 1);
      expect(recovery.completed, false);
    },
  );
  test(
    'automatic photo recovery does not reconcile historical orphan files or journals',
    () async {
      final before = {
        for (final key in h.store.media.journalBox.keys)
          '$key': h.store.media.journalBox.get(key),
      };
      final source = File(
        '${h.directory.path}/cabinets/$pilotId/evidence/$photoId.source.jpg',
      );
      final hash = await fileHash(source);
      await h.controller.recoverPhotos();
      expect({
        for (final key in h.store.media.journalBox.keys)
          '$key': h.store.media.journalBox.get(key),
      }, before);
      expect(await fileHash(source), hash);
      expect(h.store.read(pilotId)!.json, original);
    },
  );
  test(
    'backup preserves metadata and queue referenced by photo ID alone',
    () async {
      final metadata = jsonEncode({
        'photoId': photoId,
        'capturedAt': '2026-10-05T12:00:00Z',
      });
      await h.store.media.metadataBox.put(photoId, metadata);
      await recovery.prepare();
      final selected = jsonDecode(
        await File(
          '${recovery.backupPath}/raw/documents/media.json',
        ).readAsString(),
      );
      expect(selected[h.store.media.metadataBox.name][photoId], metadata);
      expect(h.store.media.metadataBox.get(photoId), metadata);
    },
  );
  test(
    'shared camera broker cannot reconcile while selective support holds snapshot',
    () async {
      await recovery.prepare();
      await expectLater(h.controller.camera.broker.recover(), throwsStateError);
      await recovery.close();
      final owner = Object();
      h.controller.camera.broker.holdForSnapshot(owner);
      h.controller.camera.broker.releaseSnapshot(owner);
    },
  );
  test(
    'selected bundle can be analyzed independently with exact document and media bytes',
    () async {
      final raw = h.store.box.get('cabinet:$pilotId');
      await recovery.prepare();
      final destination = Directory('${h.directory.path}/independent-copy');
      final manifest = await extractBundle(
        File('${recovery.backupPath}/backup.ddr.jsonl'),
        destination,
      );
      expect(
        await File('${destination.path}/documents/cabinet.json').readAsString(),
        raw,
      );
      expect(manifest['dossiers'], 1);
      expect(
        (manifest['files'] as List).where(
          (f) => f['path'].toString().endsWith('.source.jpg'),
        ),
        isNotEmpty,
      );
    },
  );
  test(
    'new stages inspect checklist photo references even without historical commands',
    () async {
      final value = clone(h.store.read(pilotId)!.json);
      final ops = objects(value['operations']);
      value['working']['registrationEvidence'] = object(
        ops[1]['body'],
      )['evidence'];
      value['operations'] = [ops.first];
      final policy = object(
        jsonDecode(
          File(
            'test/cabinets/fixtures/parts-review-policy.json',
          ).readAsStringSync(),
        ),
      );
      final definitions = cabinetReviewDefinitions(
        object(value['working']),
        policy,
      );
      value['working']['parts'] = definitions
          .map(
            (d) => <String, dynamic>{
              'code': d['code'],
              'present': true,
              if ((object(object(policy['parts'])[d['code']])['serial'] ??
                      d['serial']) ==
                  'required')
                'serial': 'TEST-001',
              'evidence': <Json>[],
            },
          )
          .toList();
      value['working']['parts'][0]['evidence'] = [
        {'photoId': 'b1000000-0000-4000-8000-000000000099', 'confirmed': true},
      ];
      await h.store.save(value);
      await expectLater(recovery.prepare(), throwsStateError);
      expect(recovery.canPrepareNewStages, false);
      expect(recovery.backup, isNull);
      expect(remote.calls, isEmpty);
      expect(remote.uploads, isEmpty);
    },
  );
  for (final uid in ['AQ26000068', 'AQ26000076']) {
    test('preparation drains refresh and preserves company for $uid', () async {
      final value = clone(h.store.read(pilotId)!.json);
      value['working']['uid'] = uid;
      value['operations'][0]['body']['uid'] = uid;
      value['server']['uid'] = uid;
      remote.documents[pilotId]!['uid'] = uid;
      remote.receipts[opId(0)]!['cabinet']['uid'] = uid;
      if (uid == 'AQ26000076') {
        value['working']['registrationCompany'] = {
          'id': 'c0000000-0000-4000-8000-000000000001',
          'name': 'Empresa 1',
        };
      }
      // Five durable photo descriptors with existing originals, 24 captured pieces.
      final firstPhoto = objects(value['photos']).first;
      final photos = objects(value['photos']);
      for (var n = 1; n < 5; n++) {
        final id =
            'b1000000-0000-4000-8000-${(n + 6).toString().padLeft(12, '0')}';
        final copy = clone(firstPhoto)..['id'] = id;
        copy['metadata']['photoId'] = id;
        for (final suffix in ['source', 'upload', 'thumb']) {
          final source = File(
            '${h.directory.path}/cabinets/$pilotId/evidence/$photoId.$suffix.jpg',
          );
          final path =
              '${h.directory.path}/cabinets/$pilotId/evidence/$id.$suffix.jpg';
          await source.copy(path);
          if (suffix == 'upload') copy['localPath'] = path;
          if (suffix == 'thumb') copy['thumbnailPath'] = path;
        }
        photos.add(copy);
      }
      value['photos'] = photos;
      final parts = objects(value['working']['parts']);
      while (parts.length < 24) {
        parts.add({
          'code': 'HISTORICAL-${parts.length}',
          'present': true,
          'evidence': <Json>[],
        });
      }
      value['working']['parts'] = parts;
      value['operations'][2]['body']['parts'] = parts;
      await h.store.save(value);
      h.controller.refreshing = true;
      final preparing = recovery.prepare();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(remote.traces, isEmpty);
      h.controller.refreshing = false;
      await preparing;
      expect(recovery.prepared, true);
      expect(recovery.backup, isNotNull);
      expect(recovery.remoteInventoryRead, true);
      expect(h.store.read(pilotId)!.photos.length, 5);
      expect(objects(h.store.read(pilotId)!.working['parts']).length, 24);
      expect(h.store.read(pilotId)!.working, value['working']);
      if (uid == 'AQ26000076') expect(recovery.canExecute, false);
      expect(remote.calls, isEmpty);
    });
  }
  test(
    'bounded controller wait reports component and permits clean retry',
    () async {
      h.controller.syncing = true;
      await expectLater(
        h.controller.beginLegacySupport(pilotId, waitTimeout: Duration.zero),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'code',
            contains('SUPPORT_CONTROLLER_BUSY'),
          ),
        ),
      );
      expect(h.controller.supportHeld, false);
      h.controller.syncing = false;
      final lease = await h.controller.beginLegacySupport(pilotId);
      await h.controller.endLegacySupport(lease);
    },
  );
  test('broker busy is identified and its owner is never released', () async {
    final started = Completer<void>(), finish = Completer<void>();
    h.controller.camera.broker.fault = (_) async {
      if (!started.isCompleted) started.complete();
      await finish.future;
    };
    // Hold the broker using its own snapshot owner, not an arbitrary unlock.
    final owner = Object();
    h.controller.camera.broker.holdForSnapshot(owner);
    await expectLater(
      h.controller.beginLegacySupport(pilotId),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'code',
          contains('SUPPORT_MEDIA_LOCK_OWNED'),
        ),
      ),
    );
    h.controller.camera.broker.releaseSnapshot(owner);
    finish.complete();
    h.controller.camera.broker.fault = null;
    expect(h.controller.supportHeld, false);
  });
  test(
    'actor mismatch blocks before remote queries independently of company',
    () async {
      final value = clone(h.store.read(pilotId)!.json)
        ..['actor'] = 'b3000000-0000-4000-8000-000000000001';
      await h.store.save(value);
      await expectLater(
        recovery.prepare(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'code',
            contains('SUPPORT_ACTOR_MISMATCH'),
          ),
        ),
      );
      expect(remote.traces, isEmpty);
      expect(recovery.remoteInventoryRead, false);
    },
  );
  test('session changes during wait do not acquire a lease', () async {
    h.controller.refreshing = true;
    final preparing = h.controller.beginLegacySupport(pilotId);
    h.app.session = testSession(user: '22222222-2222-4222-8222-222222222222');
    h.controller.refreshing = false;
    await expectLater(
      preparing,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'code',
          contains('SUPPORT_SESSION_CHANGED'),
        ),
      ),
    );
    expect(h.controller.supportHeld, false);
  });
  test(
    'HTTP in flight is bounded and finishes without cancellation before retry',
    () async {
      final entered = Completer<void>(), finish = Completer<void>();
      h.app.api.dio.httpClientAdapter = Adapter((_) async {
        entered.complete();
        await finish.future;
        return response(200, {});
      });
      final request = h.app.api.dio.get('/construction/cabinets/$pilotId');
      await entered.future;
      await expectLater(
        h.controller.beginLegacySupport(pilotId, waitTimeout: Duration.zero),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'code',
            contains('SUPPORT_HTTP_IN_FLIGHT'),
          ),
        ),
      );
      expect(h.app.api.cabinetRequestsInFlight, true);
      finish.complete();
      await request;
      final lease = await h.controller.beginLegacySupport(pilotId);
      await h.controller.endLegacySupport(lease);
    },
  );
  test(
    'pending support denies new sync refresh edits without cancelling current work',
    () async {
      final before = h.store.read(other)!.json;
      h.controller.syncing = true;
      final support = h.controller.beginLegacySupport(pilotId);
      await h.controller.refresh();
      await h.controller.synchronize(force: true);
      expect(remote.traces, isEmpty);
      expect(h.controller.syncing, true);
      h.controller.syncing = false;
      final lease = await support;
      expect(h.store.read(other)!.json, before);
      await h.controller.endLegacySupport(lease);
    },
  );
  test(
    'offline preparation reports query phase without inventing remote zero or backup',
    () async {
      final before = h.store.read(pilotId)!.json;
      remote.unavailable = true;
      await expectLater(recovery.prepare(), throwsA(isA<DioException>()));
      expect(recovery.preparationPhase, 'consulta remota iniciada');
      expect(recovery.remoteInventoryRead, false);
      expect(recovery.backup, isNull);
      expect(recovery.canExecute, false);
      expect(h.store.read(pilotId)!.json, before);
      expect(remote.calls, isEmpty);
    },
  );
  test('active broker work drains without arbitrary cancellation', () async {
    final entered = Completer<void>(), finish = Completer<void>();
    final broker = CameraCaptureBroker(
      picker: ImagePickerAdapter(),
      supportDirectory: () async => h.directory,
    );
    h.controller.dispose();
    h.controller = CabinetController(
      app: h.app,
      store: h.store,
      remote: remote,
      camera: PhotoCaptureService(
        local: h.store.media,
        broker: broker,
        supportDirectory: () async => h.directory,
        directoryName: 'cabinets',
      ),
    );
    broker.fault = (_) async {
      if (!entered.isCompleted) entered.complete();
      await finish.future;
      throw StateError('synthetic stop before camera');
    };
    final work = broker.capture(
      id: opId(90),
      module: 'cabinets',
      entityId: pilotId,
      actorId: h.controller.actor!,
      role: 'resident',
      requestedAt: DateTime.now(),
    );
    final expectation = expectLater(work, throwsStateError);
    await entered.future;
    expect(broker.busy, true);
    await expectLater(
      h.controller.beginLegacySupport(pilotId, waitTimeout: Duration.zero),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'code',
          contains('SUPPORT_MEDIA_BUSY'),
        ),
      ),
    );
    expect(broker.busy, true);
    finish.complete();
    await expectation;
    broker.fault = null;
    expect(broker.busy, false);
    final lease = await h.controller.beginLegacySupport(pilotId);
    await h.controller.endLegacySupport(lease);
  });

  for (final failureMode in ['none', 'network', 'exception']) {
    test(
      'support drains one command and preserves 22 records: $failureMode',
      () async {
        remote.allowOrdinaryOther = true;
        var n = 30;
        for (final uid in legacyCabinetUids.where((u) => u != 'AQ26000068')) {
          final value = clone(original);
          final id = opId(n++);
          value['id'] = id;
          value['working'] = {
            ...object(value['working']),
            'cabinetId': id,
            'uid': uid,
          };
          value['server'] = {
            ...object(value['server']),
            'cabinetId': id,
            'uid': uid,
          };
          await h.store.save(value);
        }
        for (var i = 0; i < 10; i++) {
          await h.controller.scan(syntheticUid(200 + i), 'A1', false);
        }
        expect(h.store.all(), hasLength(22));
        other = h.controller.records.firstWhere((r) => !legacyProtected(r)).id;
        final row = clone(h.store.read(other)!.json);
        final second = {
          'actor': h.controller.actor,
          'state': 'queued',
          'body': {
            'operationId': opId(80),
            'expectedVersion': 1,
            'type': 'identity_correct',
          },
        };
        row['operations'] = [...objects(row['operations']), second];
        await h.store.save(row);
        final untouched = {
          for (final r in h.store.all().where((r) => r.id != other))
            r.id: clone(r.json),
        };
        final entered = Completer<void>(), finish = Completer<void>();
        remote.beforeCommand = () async {
          entered.complete();
          await finish.future;
          if (failureMode == 'network') throw failure(503, 'SIMULATED_NETWORK');
          if (failureMode == 'exception') throw StateError('synthetic failure');
        };
        final syncing = h.controller.synchronize(force: true);
        await entered.future;
        final leaseFuture = h.controller.beginLegacySupport(pilotId);
        expect(h.controller.supportSyncDiagnostic, contains('comando HTTP'));
        expect(h.controller.supportSyncDiagnostic, contains('reserva=true'));
        await h.controller.synchronize(force: true);
        await h.controller.refresh();
        h.app.online = true;
        h.app.notifyListeners();
        h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        expect(h.controller.syncing, true);
        finish.complete();
        final lease = await leaseFuture;
        addTearDown(() async {
          if (h.controller.ownsLegacySupport(lease)) {
            await h.controller.endLegacySupport(lease);
          }
        });
        await syncing;
        expect(h.controller.syncing, false);
        expect(
          remote.traces.where((t) => t.startsWith('COMMAND')),
          hasLength(1),
        );
        expect(h.store.read(other)!.operations[1], second);
        expect({
          for (final r in h.store.all().where((r) => r.id != other))
            r.id: r.json,
        }, untouched);
        final first = h.store.read(other)!.operations.first;
        expect(first['state'], failureMode == 'none' ? 'done' : 'sending');
        await h.controller.endLegacySupport(lease);
        h.app.online = false;
        remote.beforeCommand = null;
      },
    );
  }

  test(
    'photo queue yields after current verified photo without starting command',
    () async {
      remote.allowOrdinaryOther = true;
      await h.controller.synchronize(force: true);
      final photos = [
        await h.photo(other, 'registration'),
        await h.photo(other, 'registration'),
      ];
      final row = clone(h.store.read(other)!.json);
      final pending = {
        'actor': h.controller.actor,
        'state': 'queued',
        'body': {
          'operationId': opId(90),
          'type': 'registration_close',
          'expectedVersion': 1,
          'evidence': photos
              .map((p) => {'photoId': p['id'], 'confirmed': true})
              .toList(),
        },
      };
      row['operations'] = [...objects(row['operations']), pending];
      await h.store.save(row);
      final entered = Completer<void>(), finish = Completer<void>();
      remote.beforeUpload = () async {
        entered.complete();
        await finish.future;
      };
      final sync = h.controller.synchronize(force: true);
      await entered.future;
      final support = h.controller.beginLegacySupport(pilotId);
      expect(
        h.controller.supportSyncDiagnostic,
        contains('carga fotográfica HTTP'),
      );
      finish.complete();
      final lease = await support;
      await sync;
      expect(remote.uploads.keys, [photos.first['id']]);
      expect(h.store.read(other)!.operations.last, pending);
      expect(h.store.read(other)!.photos.first['verified'], true);
      expect(h.store.read(other)!.photos.last['verified'], false);
      for (final p in photos) {
        expect(
          await fileHash(File(p['localPath'])),
          object(p['metadata'])['clientSha256'],
        );
      }
      expect(h.store.read(pilotId)!.json, original);
      await h.controller.endLegacySupport(lease);
    },
  );

  test(
    'slow command reports phase and timeout never releases active work',
    () async {
      remote.allowOrdinaryOther = true;
      final entered = Completer<void>(), finish = Completer<void>();
      remote.beforeCommand = () async {
        entered.complete();
        await finish.future;
      };
      final sync = h.controller.synchronize(force: true);
      await entered.future;
      await expectLater(
        h.controller.beginLegacySupport(pilotId, waitTimeout: Duration.zero),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'phase',
            contains('fase=comando HTTP'),
          ),
        ),
      );
      expect(h.controller.syncing, true);
      expect(h.controller.supportHeld, false);
      finish.complete();
      await sync;
      expect(h.controller.syncing, false);
      remote.beforeCommand = null;
      await recovery.prepare();
      expect(recovery.backupPath, isNotNull);
      expect(recovery.blockers, isEmpty);
      expect(remote.calls, hasLength(1));
    },
  );

  for (final receiptExists in [false, true]) {
    test(
      'historical conflict: five photos four commands receipt=$receiptExists',
      () async {
        final value = clone(original);
        final ops = objects(value['operations']);
        final close = ops[1];
        close['state'] = 'conflict';
        close['problem'] = {
          'code': 'CAUSAL_PHOTO_MISSING',
          'detail': 'PRIVATE_SENTINEL',
        };
        close['diagnostic'] = {'httpStatus': 409};
        final save2 = clone(ops[2]);
        final stages = [close, ops[2], save2, ops[3]];
        const ids = [
          '37ad7f83-cfb9-4c88-a65b-cbe677034351',
          'e021bff6-edd1-452a-a4ac-a2772adb019b',
          '33718abb-9fb0-44ea-ba9b-609b10222e64',
          '3b078e96-2ea5-4405-b516-bf8fc5b04e89',
        ];
        for (var i = 0; i < stages.length; i++) {
          stages[i]['body'] = {
            ...object(stages[i]['body']),
            'operationId': ids[i],
            'expectedVersion': i + 1,
          };
        }
        final photos = objects(value['photos']);
        for (var i = 1; i < 5; i++) {
          final photo = clone(photos.first);
          final id = opId(100 + i);
          final dir = File(photos.first['localPath']).parent;
          for (final suffix in ['source', 'upload', 'thumb']) {
            await File(
              '${dir.path}/$photoId.$suffix.jpg',
            ).copy('${dir.path}/$id.$suffix.jpg');
          }
          photo['localPath'] = '${dir.path}/$id.upload.jpg';
          photo['thumbnailPath'] = '${dir.path}/$id.thumb.jpg';
          photo['id'] = id;
          photo['metadata'] = {...object(photo['metadata']), 'photoId': id};
          photos.add(photo);
        }
        close['body'] = {
          ...object(close['body']),
          'evidence': photos
              .map((p) => {'photoId': p['id'], 'confirmed': true})
              .toList(),
        };
        value['photos'] = photos;
        value['operations'] = [ops.first, ...stages];
        await h.store.save(value);
        final before = h.store.box.get('cabinet:$pilotId');
        final photoHash = await fileHash(File(photos.first['localPath']));
        if (receiptExists) {
          remote.receipts[ids.first] = {
            'cabinet': {
              ...remote.documents[pilotId]!,
              'status': 'registered',
              'version': 2,
            },
          };
        }
        await recovery.prepare();
        expect(recovery.prepared, true);
        expect(recovery.canExecute, false);
        expect(recovery.sequence, hasLength(4));
        expect(recovery.operationDiagnostics, hasLength(4));
        final d = recovery.operationDiagnostics.first;
        expect(d.code, 'CAUSAL_PHOTO_MISSING');
        expect(d.http, '409');
        expect(
          d.receipt,
          receiptExists
              ? 'recibo válido pero discrepante con draft/v1'
              : 'inexistente: 404 OPERATION_NOT_FOUND',
        );
        expect(d.photoSummary, contains('5 referencias; 5 descriptores'));
        expect(d.summary, isNot(contains('PRIVATE_SENTINEL')));
        expect(h.store.box.get('cabinet:$pilotId'), before);
        expect(await fileHash(File(photos.first['localPath'])), photoHash);
        expect(remote.calls, isEmpty);
        expect(remote.uploads, isEmpty);
        await recovery.backup!.verify();
      },
    );
  }

  test(
    '413 upload precedes command and preserves original operation and bytes',
    () async {
      remote.allowOrdinaryOther = true;
      await h.controller.synchronize(force: true);
      final photo = await h.photo(other, 'registration');
      final value = clone(h.store.read(other)!.json);
      final body = <String, dynamic>{
        'operationId': opId(150),
        'expectedVersion': 1,
        'type': 'registration_close',
        'capturedAt': '2026-10-06T12:00:00.000Z',
        'evidence': [
          {'photoId': photo['id'], 'confirmed': true},
        ],
      };
      value['operations'] = [
        ...objects(value['operations']),
        {'actor': h.controller.actor, 'state': 'queued', 'body': body},
      ];
      await h.store.save(value);
      final hash = await fileHash(File(photo['localPath']));
      remote.beforeUpload = () async {
        final request = RequestOptions(
          path: '/construction/cabinets/$other/photos',
          method: 'POST',
        );
        throw DioException(
          requestOptions: request,
          response: Response(
            requestOptions: request,
            statusCode: 413,
            data: {
              'type': 'https://rvs.example/problems/payload-too-large',
              'status': 413,
            },
          ),
        );
      };
      await h.controller.synchronize(force: true);
      final saved = h.store.read(other)!.operations.last;
      expect(saved['state'], 'conflict');
      expect(object(saved['diagnostic'])['httpStatus'], 413);
      expect(saved['body'], body);
      expect(
        remote.calls.where((o) => o['type'] == 'registration_close'),
        isEmpty,
      );
      expect(remote.receipts.containsKey(opId(150)), false);
      expect(await fileHash(File(photo['localPath'])), hash);
      expect(h.store.read(pilotId)!.json, original);
    },
  );

  test(
    'offline metrics: five sizes, 22 dossiers, conflict and prior backup unchanged',
    () async {
      final value = clone(original);
      final ops = objects(value['operations']);
      ops[1]['state'] = 'conflict';
      final secondSave = clone(ops[2]);
      secondSave['body'] = {
        ...object(secondSave['body']),
        'operationId': opId(151),
        'expectedVersion': 3,
      };
      ops[3]['body'] = {...object(ops[3]['body']), 'expectedVersion': 4};
      value['operations'] = [ops[0], ops[1], ops[2], secondSave, ops[3]];
      final photos = objects(value['photos']);
      final dir = File(photos.first['localPath']).parent;
      for (var i = 0; i < 4; i++) {
        final id = opId(160 + i);
        final source = await File(
          '${dir.path}/$photoId.source.jpg',
        ).copy('${dir.path}/$id.source.jpg');
        final size = [8388607, 8388608, 8388609, 1024][i];
        final handle = await source.open(mode: FileMode.append);
        await handle.truncate(size);
        await handle.close();
        final upload = i == 3
            ? source
            : await source.copy('${dir.path}/$id.upload.jpg');
        photos.add({
          ...clone(photos.first),
          'id': id,
          'localPath': upload.path,
          'metadata': {
            ...object(photos.first['metadata']),
            'photoId': id,
            'clientSha256': await fileHash(upload),
          },
        });
      }
      value['photos'] = photos;
      await h.store.save(value);
      for (var i = 0; i < 20; i++) {
        await h.controller.scan(syntheticUid(400 + i), 'A1', false);
      }
      final before = {
        for (final r in h.store.all()) r.id: h.store.box.get('cabinet:${r.id}'),
      };
      final backup = File(
        '${h.directory.path}/cabinet_support_backups/preserved/backup.ddr.jsonl',
      );
      await backup.parent.create(recursive: true);
      await backup.writeAsString('synthetic prior backup sentinel');
      final backupHash = await fileHash(backup);
      final hashes = {
        for (final p in photos)
          p['localPath']: await fileHash(File(p['localPath'])),
      };
      remote.unavailable = true;
      await recovery.prepare(measureOnly: true);
      expect(recovery.photoDiagnostics, hasLength(5));
      expect(recovery.photoMetricsSummary, contains('8388607 bytes'));
      expect(recovery.photoMetricsSummary, contains('EXACTAMENTE'));
      expect(recovery.photoMetricsSummary, contains('SUPERADO'));
      expect(recovery.photoMetricsSummary, contains('comparten archivo'));
      expect(recovery.photoMetricsSummary, isNot(contains(h.directory.path)));
      expect(recovery.photoMetricsSummary, isNot(contains(photoId)));
      expect(recovery.canExecute, false);
      expect(recovery.canPrepareNewStages, false);
      expect(remote.traces, isEmpty);
      expect(remote.uploads, isEmpty);
      expect(remote.calls, isEmpty);
      expect({
        for (final r in h.store.all()) r.id: h.store.box.get('cabinet:${r.id}'),
      }, before);
      expect(await fileHash(backup), backupHash);
      for (final p in photos) {
        expect(await fileHash(File(p['localPath'])), hashes[p['localPath']]);
      }
    },
  );

  test('verified remote photo is not uploaded again', () async {
    final photo = h.store.read(pilotId)!.photos.first;
    remote.photoRows[photoId] = {
      'photo_id': photoId,
      'storage_verified': true,
      'server_sha256': '0' * 64,
      'client_sha256': object(photo['metadata'])['clientSha256'],
      'metadata': clone(object(photo['metadata'])),
      'actor_user_id': photo['actor'],
    };
    await recovery.prepare();
    expect(recovery.remoteVerifiedPhotos, isNull);
    expect(recovery.remoteMatchedPhotos, 1);
    await execute();
    expect(remote.uploads, isEmpty);
  });
  test(
    'lost command response is recovered by original receipt without replay',
    () async {
      await recovery.prepare();
      remote.lostCommand = true;
      await expectLater(execute(), throwsA(isA<DioException>()));
      expect(remote.calls.length, 1);
      await execute();
      expect(remote.calls.length, 3);
      expect(remote.calls.where((b) => b['operationId'] == opId(1)).length, 1);
    },
  );
  test(
    'lost photo upload response verifies existing bytes before any resend',
    () async {
      await recovery.prepare();
      remote.lostUpload = true;
      await expectLater(execute(), throwsA(isA<DioException>()));
      await execute();
      expect(remote.uploads[photoId], 1);
      expect(recovery.completed, true);
    },
  );
  test('no commands does not invent historical validation', () async {
    final v = clone(h.store.read(pilotId)!.json);
    v['operations'] = [objects(v['operations']).first];
    await h.store.save(v);
    await recovery.prepare();
    expect(recovery.canExecute, false);
    expect(recovery.backup, isNotNull);
    expect(remote.calls, isEmpty);
    await expectLater(execute(), throwsStateError);
  });
  test('missing original blocks before sending any operation', () async {
    await File(
      '${h.directory.path}/cabinets/$pilotId/evidence/$photoId.source.jpg',
    ).delete();
    await expectLater(recovery.prepare(), throwsStateError);
    expect(remote.calls, isEmpty);
    expect(recovery.canExecute, false);
  });
  test('payload/version conflict never rewritten', () async {
    final v = clone(h.store.read(pilotId)!.json);
    objects(v['operations'])[1]['body']['expectedVersion'] = 20;
    await h.store.save(v);
    await recovery.prepare();
    expect(recovery.canExecute, false);
    expect(remote.calls, isEmpty);
  });
  test('session change stops before network writes', () async {
    await recovery.prepare();
    h.app.session = testSession(user: '22222222-2222-4222-8222-222222222222');
    await expectLater(execute(), throwsStateError);
    expect(remote.calls, isEmpty);
    expect(remote.uploads, isEmpty);
  });
  test('server version drift stops without overwriting local', () async {
    await recovery.prepare();
    remote.documents[pilotId]!['version'] = 2;
    await expectLater(execute(), throwsStateError);
    expect(remote.calls, isEmpty);
  });
  test('generic receipt 404 cannot authorize resend', () async {
    remote.genericReceipt404 = true;
    await expectLater(recovery.prepare(), throwsA(isA<DioException>()));
    expect(remote.calls, isEmpty);
  });
  test(
    'unauthorized user and wrong cabinet allowlist cannot prepare',
    () async {
      h.setRole(ConstructionRole.contractor);
      await expectLater(recovery.prepare(), throwsStateError);
      h.setRole(ConstructionRole.resident);
      final wrong = LegacyCabinetRecovery(
        h.controller,
        pilotId,
        cabinetAllowlist: {other},
      );
      await expectLater(wrong.prepare(), throwsStateError);
      expect(remote.traces, isEmpty);
    },
  );
  test('explicit operation allowlist and consent are mandatory', () async {
    await recovery.prepare();
    await expectLater(
      recovery.execute(
        operationAllowlist: {opId(1)},
        explicitlyConfirmed: true,
      ),
      throwsStateError,
    );
    await expectLater(
      recovery.execute(
        operationAllowlist: recovery.operationAllowlist,
        explicitlyConfirmed: false,
      ),
      throwsStateError,
    );
    expect(remote.calls, isEmpty);
  });
  test('original record mutation invalidates prepared plan', () async {
    await recovery.prepare();
    final v = clone(h.store.read(pilotId)!.json);
    v['dirty'] = false;
    await h.store.save(v);
    await expectLater(execute(), throwsStateError);
    expect(remote.calls, isEmpty);
  });
  test(
    'persistent support hold survives controller restart; automatic paths remain inert',
    () async {
      await recovery.prepare();
      await recovery.close();
      await h.store.box.put('legacy_support_hold_v1', 'true');
      h.controller.dispose();
      h.controller = CabinetController(
        app: h.app,
        store: h.store,
        remote: remote,
      );
      await h.controller.start();
      await h.controller.synchronize(force: true);
      expect(remote.calls, isEmpty);
      expect(h.controller.supportHeld, true);
    },
  );
  test(
    'missing durable commands require explicit fresh review, new IDs and real date',
    () async {
      final value = clone(h.store.read(pilotId)!.json);
      final originalOps = objects(value['operations']);
      value['working']['registrationEvidence'] = object(
        originalOps[1]['body'],
      )['evidence'];
      final policy = object(
        jsonDecode(
          File(
            'test/cabinets/fixtures/parts-review-policy.json',
          ).readAsStringSync(),
        ),
      );
      final definitions = cabinetReviewDefinitions(
        object(value['working']),
        policy,
      );
      value['working']['parts'] = definitions
          .map(
            (d) => <String, dynamic>{
              'code': d['code'],
              'present': true,
              if ((object(object(policy['parts'])[d['code']])['serial'] ??
                      d['serial']) ==
                  'required')
                'serial': 'TEST-001',
              'evidence': <Json>[],
            },
          )
          .toList();
      value['operations'] = [originalOps.first];
      await h.store.save(value);
      await recovery.prepare();
      expect(recovery.canExecute, false);
      expect(recovery.canPrepareNewStages, true);
      final historicalBackup = recovery.backupPath;
      await expectLater(
        recovery.prepareNewStages(reviewedOriginalChecklistAndEvidence: false),
        throwsStateError,
      );
      final before = DateTime.now().toUtc();
      await recovery.prepareNewStages(
        reviewedOriginalChecklistAndEvidence: true,
      );
      expect(recovery.canExecute, true);
      expect(remote.calls, isEmpty);
      expect(recovery.backupPath, isNot(historicalBackup));
      for (final op in recovery.sequence) {
        final body = object(op['body']);
        expect([
          opId(0),
          opId(1),
          opId(2),
          opId(3),
        ], isNot(contains(body['operationId'])));
        expect(DateTime.parse(body['capturedAt']).isBefore(before), false);
      }
      await execute();
      expect(remote.documents[pilotId]!['status'], 'validated');
      expect(remote.calls.any((b) => b['type'] == 'register'), false);
      expect(h.store.read(pilotId)!.working, value['working']);
      expect(await File('$historicalBackup/backup.ddr.jsonl').exists(), true);
    },
  );
  test(
    'text Validado without complete checklist cannot authorize new commands',
    () async {
      final v = clone(h.store.read(pilotId)!.json);
      v['operations'] = [objects(v['operations']).first];
      v['working']['parts'] = <Json>[];
      await h.store.save(v);
      await recovery.prepare();
      expect(recovery.canPrepareNewStages, false);
      expect(remote.calls, isEmpty);
    },
  );
  test(
    'remote photo client hash or metadata conflict stops preparation',
    () async {
      final photo = h.store.read(pilotId)!.photos.first;
      remote.photoRows[photoId] = {
        'photo_id': photoId,
        'client_sha256': 'wrong',
        'server_sha256': 'normalized',
        'metadata': photo['metadata'],
        'actor_user_id': photo['actor'],
      };
      await recovery.prepare();
      expect(recovery.canExecute, false);
      expect(remote.uploads, isEmpty);
    },
  );
  test(
    '22 cached dossiers: only the pilot changes during controlled recovery',
    () async {
      for (var n = 0; n < 20; n++) {
        await h.controller.scan(syntheticUid(200 + n), 'A1', false);
      }
      expect(h.store.all().length, 22);
      final before = {
        for (final r in h.store.all().where((r) => r.id != pilotId))
          r.id: clone(r.json),
      };
      await recovery.prepare();
      h.app.online = true;
      h.app.notifyListeners();
      await h.controller.refresh();
      await h.controller.synchronize(force: true);
      h.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await execute();
      expect({
        for (final r in h.store.all().where((r) => r.id != pilotId))
          r.id: r.json,
      }, before);
      expect(
        remote.traces
            .where((t) => t.startsWith('COMMAND'))
            .every((t) => t.contains(pilotId)),
        true,
      );
    },
  );
  test(
    'normal sync protects pilot before support and never duplicates recovered photos afterwards',
    () async {
      remote.allowOrdinaryOther = true;
      final originalBefore = clone(h.store.read(pilotId)!.json);
      await h.controller.synchronize(force: true);
      expect(h.store.read(pilotId)!.json, originalBefore);
      expect(remote.documents[other], isNotNull);
      await recovery.prepare();
      await execute();
      await recovery.close();
      final calls = remote.calls.length, uploads = remote.uploads[photoId];
      await h.controller.synchronize(force: true);
      expect(remote.calls.length, calls);
      expect(remote.uploads[photoId], uploads);
      expect(h.store.read(pilotId)!.json['legacyRecoveryCompleted'], true);
    },
  );
}
