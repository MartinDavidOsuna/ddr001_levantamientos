import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_media_store.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_media_sync.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync_api.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync_store.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'harness.dart';
import 'sync_test.dart' show FakeHydroRemote;

class Docs extends FakeHydroRemote {
  @override
  Future<HydroJson> capabilities(HydrostaticSyncIdentity s) async {
    final c = await super.capabilities(s);
    c['features']['photoUpload'] = true;
    return c;
  }
}

class Media implements HydrostaticMediaRemote {
  final rows = <String, HydroJson>{};
  int uploads = 0;
  bool lose = false;
  void Function()? after;
  @override
  Future<HydroJson> status(
    String t,
    String e,
    HydrostaticSyncIdentity s,
  ) async => rows[e] ?? {'verified': false};
  @override
  Future<HydroJson> upload(
    HydrostaticEvidence e,
    File f,
    String mime,
    HydrostaticSyncIdentity s,
    void Function(int, int) progress,
  ) async {
    uploads++;
    progress(e.byteLength, e.byteLength);
    rows[e.id] = {
      'testId': e.testId,
      'evidenceId': e.id,
      'sha256': e.sha256,
      'byteLength': e.byteLength,
      'uploadState': 'STORED',
      'integrityState': 'VERIFIED',
      'verified': true,
    };
    after?.call();
    if (lose) throw StateError('lost response');
    return rows[e.id]!;
  }
}

void main() {
  late Harness h;
  late HydrostaticSync sync;
  late HydrostaticSyncStore docs;
  late HydrostaticMediaStore store;
  late Media remote;
  late HydrostaticMediaSync media;
  bool online = true;
  setUp(() async {
    h = Harness();
    await h.open();
    online = true;
    docs = await HydrostaticSyncStore.open(Directory('${h.root.path}/outbox'));
    store = await HydrostaticMediaStore.open(Directory('${h.root.path}/media'));
    sync = HydrostaticSync(
      repository: h.repo,
      store: docs,
      remote: Docs(),
      identity: () => h.access.authorized
          ? HydrostaticSyncIdentity(
              h.access.actor.userId,
              h.access.actor.sessionId,
              h.access.actor.deviceInstallationId,
            )
          : null,
      verifySession: () async {},
      online: () => online,
      enabled: true,
    );
    remote = Media();
    media = HydrostaticMediaSync(
      documents: sync,
      store: store,
      remote: remote,
      support: h.root,
      now: () => h.clock.utc,
    );
    sync.media = media;
  });
  tearDown(() async {
    sync.dispose();
    await store.close();
    await docs.close();
    await h.close();
  });
  Future<String> prep({int count = 1}) async {
    final id = await h.prepare();
    for (var i = 0; i < count; i++) {
      final e = await h.evidence(
        id,
        HydrostaticEvidenceRole.initialSetup,
        text: '\u00ff\u00d8\u00ff synthetic $i',
      );
      await h.repo.addEvidence(id, uuid(), e);
    }
    return id;
  }

  test(
    'durable ACK preserves original and replay does not retransfer',
    () async {
      final id = await prep();
      await sync.run();
      final e = h.repo.get(id)!.evidence.single;
      expect(store.read(e.id)!['state'], 'VERIFIED');
      expect(remote.uploads, 1);
      await sync.run();
      expect(remote.uploads, 1);
      expect(await File('${h.root.path}/${e.originalPath}').exists(), true);
    },
  );
  test('lost response recovers via status after store reopen', () async {
    final id = await prep();
    remote.lose = true;
    await sync.run();
    final e = h.repo.get(id)!.evidence.single;
    expect(store.read(e.id)!['state'], 'ERROR');
    await store.close();
    store = await HydrostaticMediaStore.open(Directory('${h.root.path}/media'));
    media = HydrostaticMediaSync(
      documents: sync,
      store: store,
      remote: remote,
      support: h.root,
    );
    sync.media = media;
    await sync.run(manual: true);
    expect(store.read(e.id)!['state'], 'VERIFIED');
    expect(remote.uploads, 1);
  });
  test(
    'missing file does not prevent another photo transfer and is preserved in queue',
    () async {
      final id = await prep(count: 2);
      final photos = h.repo.get(id)!.evidence;
      await File('${h.root.path}/${photos.first.originalPath}').delete();
      await sync.run();
      expect(store.read(photos.first.id)!['error'], 'PHOTO_MISSING');
      expect(store.read(photos.last.id)!['state'], 'VERIFIED');
    },
  );
  test('corrupt original is never sent; retry observes backoff', () async {
    final id = await prep();
    final e = h.repo.get(id)!.evidence.single;
    await File('${h.root.path}/${e.originalPath}').writeAsString('bad');
    await sync.run();
    final before = store.read(e.id)!['attempts'];
    await sync.run();
    expect(store.read(e.id)!['attempts'], before);
    expect(remote.uploads, 0);
  });
  test(
    'offline document and conflicted document do not transfer media',
    () async {
      final id = await prep();
      online = false;
      await sync.run();
      expect(remote.uploads, 0);
      online = true;
      final row = docs.read(id)!;
      row['active']['state'] = 'CONFLICT';
      await docs.save(id, row, 'test');
      await sync.run();
      expect(remote.uploads, 0);
    },
  );
  test(
    'session changes during transfer cannot acknowledge under another identity',
    () async {
      final id = await prep();
      final snapshot = h.repo.get(id)!;
      remote.after = () {
        h.access = HydrostaticAccess(
          actor: h.access.actor,
          authorized: false,
          fieldSession: true,
        );
      };
      await sync.run();
      final e = snapshot.evidence.single;
      expect(store.read(e.id)!['state'], 'ERROR');
      expect(media.view(snapshot, e), null);
    },
  );
  test('concurrent kicks serialize uploads', () async {
    await prep(count: 2);
    await Future.wait([sync.run(), sync.run()]);
    expect(remote.uploads, 2);
  });
  for (final boundary in ['after:sending', 'after:verified']) {
    test('durable recovery after injected $boundary failure', () async {
      final id = await prep();
      bool once = true;
      store.fault = (at) async {
        if (once && at == boundary) {
          once = false;
          throw StateError('synthetic interruption');
        }
      };
      await sync.run();
      store.fault = null;
      await sync.run(manual: true);
      final e = h.repo.get(id)!.evidence.single;
      expect(store.read(e.id)!['state'], 'VERIFIED');
      expect(remote.uploads, 1);
      expect(await File('${h.root.path}/${e.originalPath}').exists(), true);
    });
  }
  test(
    'progress and summary distinguish transfer from document and hydraulic status',
    () async {
      final id = await prep();
      final t = h.repo.get(id)!;
      final labels = <String>[];
      final fractions = <double>[];
      media.onChanged = () {
        labels.add(media.label(t));
        fractions.addAll(media.progress.values);
      };
      await sync.run();
      expect(labels, contains('Fotografías enviándose'));
      expect(fractions, contains(1.0));
      expect(
        media.label(t),
        'Fotografías verificadas · expediente pendiente de historial',
      );
      expect(h.repo.get(id)!.state, HydrostaticTestState.preparation);
    },
  );
  test(
    'corrupt sidecar is preserved and does not stop other evidence',
    () async {
      final id = await prep(count: 2);
      final t = h.repo.get(id)!;
      await store.box.put(t.evidence.first.id, 'synthetic corrupt sidecar');
      await store.box.flush();
      await sync.run();
      expect(store.box.get(t.evidence.first.id), 'synthetic corrupt sidecar');
      expect(media.view(t, t.evidence.first)?['error'], 'MEDIA_OUTBOX_CORRUPT');
      expect(store.read(t.evidence.last.id)!['state'], 'VERIFIED');
    },
  );
}
