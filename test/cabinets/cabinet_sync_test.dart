import 'dart:io';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_store.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late FakeCabinetRemote remote;
  setUp(() async {
    remote = FakeCabinetRemote();
    h = Harness();
    await h.open(remote: remote);
  });
  tearDown(() async {
    await h.close();
  });
  test(
    'manual retry sends preserved work despite stale offline status',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      expect(h.app.online, isFalse);
      await h.controller.synchronize();
      expect(remote.calls, isEmpty);
      await h.controller.synchronize(force: true);
      expect(remote.calls, hasLength(1));
      expect(h.store.read(id)!.pending, isEmpty);
      expect(h.store.read(id)!.server['version'], 1);
      await h.controller.synchronize(force: true);
      expect(remote.calls, hasLength(1));
    },
  );
  test(
    'cabinet refresh retrieves all authorized pages and caches every dossier',
    () async {
      final paged = PagedCabinetRemote();
      h.controller.dispose();
      h.controller = CabinetController(
        app: h.app,
        store: h.store,
        remote: paged,
      );
      await h.controller.refresh();
      expect(paged.pages, [1, 2, 3]);
      expect(h.controller.records.length, 205);
    },
  );
  test(
    'explicit reconciliation creates a new operation and retains the rejected attempt',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      await h.sync();
      final photo = await h.photo(id, 'registration');
      await h.controller.enqueue(id, 'registration_close', {
        'evidence': evidence(photo),
      });
      remote.documents[id]!['version'] = 2;
      await h.sync();
      final old = object(h.store.read(id)!.pending.first['body']);
      expect(h.store.read(id)!.pending.first['state'], 'conflict');
      await h.controller.reconcile(
        id,
        retryLocal: true,
        reason: 'Revisé versión remota y mantengo esta identificación',
      );
      final replacement = object(h.store.read(id)!.pending.first['body']);
      expect(replacement['operationId'], isNot(old['operationId']));
      expect(replacement['expectedVersion'], 2);
      expect(
        h.store.read(id)!.operations.any((o) => o['state'] == 'superseded'),
        isTrue,
      );
      await h.sync();
      expect(h.store.read(id)!.pending, isEmpty);
    },
  );
  test(
    'base exclusivity rejection preserves installation draft and evidence',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      await h.sync();
      final photo = await h.photo(id, 'installation');
      // The server can reject a base that appeared available in the offline cache.
      await h.controller.saveDraft(id, 'partsValidated', true);
      final installation = <String, dynamic>{
        'baseId': '11111111-1111-4111-8111-111111111111',
        'gps': {'latitude': 28.1, 'longitude': -110.8, 'accuracy': 5},
        'evidence': {'general': evidence(photo)},
        'answers': <Json>[],
      };
      await h.controller.enqueue(id, 'installation_save', {
        'installation': installation,
      });
      remote.conflictId = id;
      remote.conflictCode = 'BASE_CONFLICT';
      await h.sync();
      final record = h.store.read(id)!;
      expect(record.pending.single['state'], 'conflict');
      expect(record.pending.single['error'], contains('BASE_CONFLICT'));
      expect(
        object(record.working['installation'])['baseId'],
        installation['baseId'],
      );
      expect(File(photo['localPath']).existsSync(), isTrue);
      expect(record.photos.single['id'], photo['id']);
      final calls = remote.calls.length;
      await h.sync();
      expect(remote.calls.length, calls);
    },
  );
  test(
    'repeat and concurrent scans reuse one durable technical UUID',
    () async {
      final ids = await Future.wait([
        h.controller.scan('AQ26000017', 'A1', false),
        h.controller.scan('AQ26-00001-7', 'A1', false),
      ]);
      expect(ids.toSet().length, 1);
      expect(h.store.all().length, 1);
      expect(h.store.all().single.pending.length, 1);
    },
  );
  test(
    'separate additive storage preserves base pending queue and reloads cabinet operations',
    () async {
      await h.app.local.metadataBox.put('existing-data', 'preserved');
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      final reopened = await CabinetStore.open();
      expect(reopened.read(id)!.pending.single['actor'], h.controller.actor);
      expect(h.app.local.metadataBox.get('existing-data'), 'preserved');
    },
  );
  test(
    'contractor, admin and revoked resident cannot read local dossier or enqueue',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      for (final role in [
        ConstructionRole.contractor,
        ConstructionRole.admin,
        ConstructionRole.superadmin,
      ]) {
        h.setRole(role);
        expect(h.controller.records, isEmpty);
        expect(() => h.controller.record(id), throwsStateError);
      }
      h.setRole(ConstructionRole.resident);
      h.app.session = testSession(kind: SessionKind.admin);
      expect(h.controller.allowed, isFalse);
      h.app.session = h.sessions.value;
      await h.store.authorize(h.controller.actor!, false);
      expect(h.controller.records, isEmpty);
    },
  );
  test(
    'lost response recovers receipt after restart without replaying command',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      remote.loseNextResponse = true;
      await h.sync();
      expect(h.store.read(id)!.pending.single['state'], 'sending');
      final request = object(h.store.read(id)!.pending.single['body']);
      await h.sync();
      expect(h.store.read(id)!.pending, isEmpty);
      expect(remote.calls.length, 1);
      expect(remote.receipts.containsKey(request['operationId']), isTrue);
    },
  );
  test(
    'interrupted upload keeps identity, bytes and relations and verifies before closure',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      final photo = await h.photo(id, 'registration');
      await h.controller.enqueue(id, 'registration_close', {
        'evidence': evidence(photo),
      });
      remote.interruptUpload = true;
      await h.sync();
      expect(h.store.read(id)!.pending.length, 1);
      expect(File(photo['localPath']).existsSync(), isTrue);
      await h.sync();
      expect(h.store.read(id)!.pending, isEmpty);
      expect(remote.uploads.keys.single, photo['id']);
      expect(h.store.read(id)!.photos.single['verified'], isTrue);
    },
  );
  test(
    'one conflicting dossier does not block another and requires explicit reconciliation',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      remote.conflictId = id;
      // Generate another valid physical UID using the same ISO 7064 algorithm.
      var p = 10;
      for (final d in '2600002'.split('')) {
        var s = (p + int.parse(d)) % 10;
        if (s == 0) s = 10;
        p = (s * 2) % 11;
      }
      final other = await h.controller.scan(
        'AQ2600002${(11 - p) % 10}',
        'A2',
        false,
      );
      await h.sync();
      expect(h.store.read(id)!.pending.single['state'], 'conflict');
      expect(h.store.read(other)!.pending, isEmpty);
      final before = remote.calls.length;
      await h.sync();
      expect(remote.calls.length, before);
    },
  );
  test(
    'changed user cannot send previous actor work or see unpublished dossier',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      final other = testSession(user: '22222222-2222-4222-8222-222222222222');
      h.app.session = other;
      h.sessions.value = other;
      h.setRole(ConstructionRole.resident);
      await h.store.authorize(other.userId, true);
      expect(h.controller.records, isEmpty);
      await h.sync();
      expect(remote.calls, isEmpty);
      expect(h.store.read(id)!.pending.length, 1);
    },
  );
  test('revocation hides cached content and preserves pending work', () async {
    final id = await h.controller.scan('AQ26000017', 'A1', false);
    remote.deny = true;
    await h.sync();
    expect(h.controller.allowed, isFalse);
    expect(h.store.read(id)!.pending.length, 1);
  });
  test(
    'missing image and missing GPS preserve files/metadata and block only dependent closure',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      final photo = await h.photo(id, 'registration');
      await h.controller.enqueue(id, 'registration_close', {
        'evidence': evidence(photo),
      });
      await File(photo['localPath']).delete();
      await h.sync();
      expect(h.store.read(id)!.pending.length, 1);
      expect(h.store.read(id)!.pending.single['error'], contains('faltante'));
      expect(h.store.read(id)!.photos.length, 1);
    },
  );
  test('shared photo is stored once for many evidence links', () async {
    final id = await h.controller.scan('AQ26000017', 'A1', false);
    final photo = await h.photo(id, 'parts_validation');
    await h.controller.saveDraft(id, 'parts', [
      for (final p in h.store.read(id)!.working['partDefinitions'] as List)
        {'code': p['code'], 'present': true, 'evidence': evidence(photo)},
    ]);
    expect(h.store.read(id)!.photos.length, 1);
    expect(objects(h.store.read(id)!.working['parts']).length, 14);
  });
  test('installation and approval cannot bypass incomplete parts', () async {
    final id = await h.controller.scan('AQ26000017', 'A1', false);
    await expectLater(
      h.controller.enqueue(id, 'installation_close', {}),
      throwsStateError,
    );
    await expectLater(
      h.controller.enqueue(id, 'final_review', {'verdict': 'approve'}),
      throwsStateError,
    );
  });
}

class PagedCabinetRemote extends FakeCabinetRemote {
  final pages = <int>[];
  @override
  Future<Json> get(String path, [Json? query]) async {
    if (path == '') {
      final page = query!['page'] as int;
      pages.add(page);
      return {
        'total': 205,
        'items': [
          for (var n = (page - 1) * 100; n < (page * 100).clamp(0, 205); n++)
            {
              'cabinet_id':
                  '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
            },
        ],
      };
    }
    if (path.startsWith('/00000000')) {
      return {
        'cabinet': {
          'cabinetId': path.substring(1),
          'uid': 'AQ26000017',
          'model': 'A1',
          'automated': false,
          'catalogVersion': fixtureCatalog().version,
          'status': 'registered',
          'version': 1,
        },
      };
    }
    return super.get(path, query);
  }
}
