import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'harness.dart';

class LookupRemote extends FakeCabinetRemote {
  int lookups = 0;
  int? error;
  @override
  Future<Json> get(String path, [Json? query]) async {
    if (path != '/resolve') return super.get(path, query);
    lookups++;
    if (error != null) throw failure(error!, 'LOOKUP_FAILED');
    return {
      'cabinet': {
        'cabinetId': '11111111-1111-4111-8111-111111111111',
        'uid': query!['uid'],
        'model': 'A1',
        'status': 'validated',
      },
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late LookupRemote remote;
  setUp(() async {
    h = Harness();
    remote = LookupRemote();
    await h.open(remote: remote);
  });
  tearDown(() => h.close());
  test(
    'local first and repeated QR preserve pending captures without network',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      final before = h.store.read(id)!.json;
      expect(
        await h.controller.findForInstallation(
          'https://id.aquafim.com/ddr001/AQ26000017',
        ),
        id,
      );
      expect(await h.controller.findForInstallation('AQ26-00001-7'), id);
      expect(remote.lookups, 0);
      expect(h.store.read(id)!.json, before);
    },
  );
  test(
    'API resolution persists dossier and subsequent lookup is local',
    () async {
      h.app.online = true;
      final id = await h.controller.findForInstallation('AQ26000017');
      expect(id, isNotNull);
      expect(h.store.read(id!)!.server['status'], 'validated');
      h.app.online = false;
      expect(await h.controller.findForInstallation('AQ26000017'), id);
      expect(remote.lookups, 1);
    },
  );
  test(
    'only a confirmed 404 is absence; offline and server errors do not create drafts',
    () async {
      await expectLater(
        h.controller.findForInstallation('AQ26000017'),
        throwsStateError,
      );
      h.app.online = true;
      remote.error = 503;
      await expectLater(
        h.controller.findForInstallation('AQ26000017'),
        throwsA(anything),
      );
      remote.error = 404;
      expect(await h.controller.findForInstallation('AQ26000017'), isNull);
      expect(h.controller.records, isEmpty);
    },
  );
  test('invalid check digit never queries API', () async {
    h.app.online = true;
    await expectLater(
      h.controller.findForInstallation('AQ26000018'),
      throwsFormatException,
    );
    expect(remote.lookups, 0);
  });
}
