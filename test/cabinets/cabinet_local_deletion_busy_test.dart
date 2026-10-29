import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_controller.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_store.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'harness.dart';
import 'cabinet_preservation_test.dart' show FixturePicker, FailingLocation;

class BusyRemote extends FakeCabinetRemote {
  Completer<Uint8List>? photo;
  Completer<Json>? sending;
  String? sendingId;
  @override
  Future<Uint8List> content(
    String id,
    String photoId, {
    bool thumbnail = true,
  }) => photo!.future;
  @override
  Future<Json> command(String id, Json body) async {
    if (id == sendingId) await sending!.future;
    return super.command(id, body);
  }
}

class GatedStore extends CabinetStore {
  GatedStore(super.box, super.media);
  Completer<void>? gate;
  @override
  Future<void> save(Json value) async {
    await gate?.future;
    await super.save(value);
  }
}

class BrokenRecovery extends CabinetController {
  BrokenRecovery(Harness h, BusyRemote r)
    : super(app: h.app, store: h.store, remote: r, camera: h.controller.camera);
  @override
  Future<void> recoverPhotoGps() async =>
      throw StateError('synthetic GPS recovery failure');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late BusyRemote remote;
  setUp(() async {
    h = Harness();
    remote = BusyRemote();
    await h.open(
      remote: remote,
      locations: FailingLocation(),
      picker: FixturePicker(),
    );
  });
  tearDown(() => h.close());
  Future<String> registered(String uid) async {
    final id = await h.controller.scan(uid, 'A1', false);
    await h.sync();
    return id;
  }

  test('other cabinet photo load does not block local deletion', () async {
    final target = await registered('AQ26000017'),
        other = await registered('AQ26000025');
    remote.photo = Completer();
    final load = h.controller.photoBytes(other, {
      'id': 'cached-photo',
      'remote': true,
    });
    try {
      await h.controller.deleteLocalRegistration(target, 'AQ26000017');
      expect(h.store.read(target), null);
      expect(h.store.read(other), isNotNull);
    } finally {
      remote.photo!.complete(Uint8List.fromList([1, 2, 3]));
      await load;
    }
  });
  test('own photo operation blocks then releases after completion', () async {
    final id = await registered('AQ26000017');
    remote.photo = Completer();
    final load = h.controller.photoBytes(id, {
      'id': 'cached-photo',
      'remote': true,
    });
    await expectLater(
      h.controller.deleteLocalRegistration(id, 'AQ26000017'),
      throwsStateError,
    );
    remote.photo!.complete(Uint8List.fromList([1]));
    await load;
    await h.controller.deleteLocalRegistration(id, 'AQ26000017');
    expect(h.store.read(id), null);
  });
  test('own photo exception releases lock without losing dossier', () async {
    final id = await registered('AQ26000017');
    remote.photo = Completer();
    final load = h.controller.photoBytes(id, {
      'id': 'cached-photo',
      'remote': true,
    });
    final check = expectLater(load, throwsStateError);
    remote.photo!.completeError(StateError('synthetic transport'));
    await check;
    expect(h.store.read(id), isNotNull);
    await h.controller.deleteLocalRegistration(id, 'AQ26000017');
  });
  test('active write blocks and completed metadata write releases', () async {
    final id = await registered('AQ26000017');
    final old = h.controller;
    final store = GatedStore(h.store.box, h.store.media);
    h.store = store;
    h.controller = CabinetController(
      app: h.app,
      store: store,
      remote: remote,
      camera: old.camera,
    );
    old.dispose();
    // pull performs an ordinary durable metadata update; no unsent user edit.
    store.gate = Completer();
    final pull = h.controller.pull(id);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await expectLater(
      h.controller.deleteLocalRegistration(id, 'AQ26000017'),
      throwsStateError,
    );
    store.gate!.complete();
    await pull;
    store.gate = null;
    await h.controller.deleteLocalRegistration(id, 'AQ26000017');
    expect(h.store.read(id), null);
  });
  test(
    'write failure releases activity; subsequent recovery can remove cache',
    () async {
      final id = await registered('AQ26000017');
      final old = h.controller;
      final store = GatedStore(h.store.box, h.store.media);
      h.store = store;
      h.controller = CabinetController(
        app: h.app,
        store: store,
        remote: remote,
        camera: old.camera,
      );
      old.dispose();
      store.gate = Completer();
      final pull = h.controller.pull(id);
      final check = expectLater(pull, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      store.gate!.completeError(StateError('synthetic disk failure'));
      await check;
      store.gate = null;
      await h.controller.deleteLocalRegistration(id, 'AQ26000017');
      expect(h.store.read(id), null);
    },
  );
  test('another cabinet sending does not block clean dossier', () async {
    final target = await registered('AQ26000017');
    final other = await h.controller.scan('AQ26000025', 'A1', false);
    remote.sendingId = other;
    remote.sending = Completer();
    final sending = h.controller.synchronize(force: true);
    while (!h.controller.syncing) {
      await Future<void>.delayed(Duration.zero);
    }
    await h.controller.deleteLocalRegistration(target, 'AQ26000017');
    expect(h.store.read(target), null);
    expect(h.store.read(other)!.pending, isNotEmpty);
    remote.sending!.complete({});
    await sending;
    expect(h.store.read(other)!.pending, isEmpty);
  });
  test('unsent registration drafts and photos are preserved', () async {
    final id = await h.controller.scan('AQ26000017', 'A1', false);
    final before = clone(h.store.read(id)!.json);
    await expectLater(
      h.controller.deleteLocalRegistration(id, 'AQ26000017'),
      throwsStateError,
    );
    expect(h.store.read(id)!.json, before);
    await h.sync();
    final p = await h.photo(id, 'registration');
    await expectLater(
      h.controller.deleteLocalRegistration(id, 'AQ26000017'),
      throwsStateError,
    );
    expect(await File(p['localPath']).exists(), true);
  });
  test(
    'draft without queue and remote absence still preserves user edits',
    () async {
      final id = await registered('AQ26000017');
      await h.controller.saveDraft(id, 'model', 'A3');
      final r = clone(h.store.read(id)!.json);
      r['deletion'] = {
        'actor': h.controller.actor,
        'code': 'CABINET_NOT_FOUND',
      };
      await h.store.save(r);
      await expectLater(
        h.controller.deleteLocalRegistration(id, 'AQ26000017'),
        throwsStateError,
      );
      expect(h.store.read(id)!.working['model'], 'A3');
    },
  );
  test(
    'capture recovery exception never leaves global capturing latched',
    () async {
      final id = await registered('AQ26000017');
      final old = h.controller;
      h.controller = BrokenRecovery(h, remote);
      old.dispose();
      await expectLater(
        h.controller.capture(id, 'registration'),
        throwsStateError,
      );
      expect(h.controller.capturing, false);
      expect(h.store.read(id), isNotNull);
    },
  );
  test(
    'Hive reopen preserves unsent work and releases transient locks',
    () async {
      final clean = await registered('AQ26000017');
      final pending = await h.controller.scan('AQ26000025', 'A1', false);
      final camera = h.controller.camera;
      h.controller.dispose();
      await h.store.box.close();
      h.store = CabinetStore(
        await Hive.openBox<String>('cabinets_documents_v1'),
        h.store.media,
      );
      h.controller = CabinetController(
        app: h.app,
        store: h.store,
        remote: remote,
        camera: camera,
      );
      await expectLater(
        h.controller.deleteLocalRegistration(pending, 'AQ26000025'),
        throwsStateError,
      );
      await h.controller.deleteLocalRegistration(clean, 'AQ26000017');
      expect(h.store.read(pending)!.pending, isNotEmpty);
      expect(h.store.read(clean), null);
    },
  );
}
