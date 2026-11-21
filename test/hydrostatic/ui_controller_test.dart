import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_access_adapter.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'ui_harness.dart';
import 'harness.dart';

class MemorySessions implements SessionStore {
  FieldSession? value;
  @override
  Future<FieldSession?> read() async => value;
  @override
  Future<void> save(FieldSession v) async => value = v;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<String> installationId() async => value!.installationId;
}

void main() {
  late UiHarness h;
  setUp(() async {
    h = UiHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  for (final raw in [
    'AQ26000017',
    'AQ26-00001-7',
    'https://id.aquafim.com/ddr001/AQ26000017',
  ]) {
    test(
      'local identification $raw creates durable preparation only',
      () async {
        final id = await h.controller.identify(raw);
        final t = h.controller.document(id);
        expect(t.state, HydrostaticTestState.preparation);
        expect(t.startedAt, isNull);
        expect(t.attemptNumber, isNull);
        expect(h.controller.provisional(id), 1);
        expect(h.repo.sequences.last(t.cabinet.uid), 0);
        expect(h.controller.started, isEmpty);
        expect(h.controller.preparations.length, 1);
        h.controller.dispose();
        await h.reopen();
        h.makeController();
        await h.controller.initialize();
        expect(h.controller.document(id).id, id);
        expect(await h.controller.identify(raw), id);
      },
    );
  }
  for (final raw in [
    'bad',
    'https://evil.example/ddr001/AQ26000017',
    'AQ26-00000-0',
    'AQ26-00001-8',
  ]) {
    test('invalid identity $raw never writes', () async {
      await expectLater(h.controller.identify(raw), throwsFormatException);
      expect(h.store.all(), isEmpty);
    });
  }
  test('repeated QR and double preparation share one write', () async {
    final ids = await Future.wait([
      h.controller.identify('AQ26000017'),
      h.controller.identify('AQ26000017'),
    ]);
    expect(ids.first, ids.last);
    expect(h.store.all().length, 1);
    expect(h.repo.journal.entries.length, 1);
  });
  for (final model in ['A1', 'A2', 'A3', 'A4']) {
    test('local snapshot $model automated', () async {
      h.records = [h.record(model: model, automated: true)];
      final id = await h.controller.identify('AQ26000017');
      expect(h.controller.document(id).cabinet.model, model);
      expect(h.controller.document(id).cabinet.automated, isTrue);
    });
  }
  for (final status in ['registered', 'incomplete', 'validated']) {
    test('eligible status $status', () async {
      h.records = [h.record(status: status)];
      expect(await h.controller.identify('AQ26000017'), isNotEmpty);
    });
  }
  for (final status in [
    'draft',
    'installed',
    'deliverable',
    'deleted',
    'unknown',
  ]) {
    test('reject status $status', () async {
      h.records = [h.record(status: status)];
      await expectLater(
        h.controller.identify('AQ26000017'),
        throwsA(isA<HydrostaticException>()),
      );
      expect(h.store.all(), isEmpty);
    });
  }
  test('missing cabinet never creates it', () async {
    h.records = [];
    await expectLater(
      h.controller.identify('AQ26000017'),
      throwsA(isA<HydrostaticException>()),
    );
    expect(h.records, isEmpty);
    expect(h.store.all(), isEmpty);
  });
  test('archived, deletion and duplicate dossiers rejected', () async {
    for (final records in [
      [h.record(archived: true)],
      [h.record(deleted: true)],
      [h.record(), h.record()],
    ]) {
      h.records = records;
      await expectLater(
        h.controller.identify('AQ26000017'),
        throwsA(isA<HydrostaticException>()),
      );
    }
    expect(h.store.all(), isEmpty);
  });
  test(
    'foreign unsynced cabinet hidden; server shared cabinet readable without mutation',
    () async {
      h.records = [h.record(shared: false, actor: uuid())];
      expect(await h.lookup.findLocal('AQ26000017', h.access), isNull);
      h.records = [h.record(actor: uuid())];
      final before = h.records.single.json.toString();
      await h.controller.identify('AQ26000017');
      expect(h.records.single.json.toString(), before);
    },
  );
  test('changed cabinet preserves original snapshot and warns', () async {
    final id = await h.controller.identify('AQ26000017');
    h.records = [h.record(id: h.records.single.id, model: 'A3')];
    expect(await h.controller.preparationWarning(id), contains('cambió'));
    expect(h.controller.document(id).cabinet.model, 'A1');
    final fresh = await h.controller.identify('AQ26000017');
    expect(fresh, isNot(id));
    expect(h.controller.document(id).cabinet.model, 'A1');
    expect(h.controller.document(fresh).cabinet.model, 'A3');
  });
  test('changed user cannot read or edit original preparation', () async {
    final id = await h.controller.identify('AQ26000017');
    h.access = HydrostaticAccess(
      actor: HydrostaticActorSnapshot(
        userId: uuid(),
        name: 'OTHER',
        sessionId: uuid(),
        deviceInstallationId: uuid(),
      ),
      authorized: true,
      fieldSession: true,
    );
    h.changes.notifyListeners();
    expect(h.controller.documents, isEmpty);
    expect(
      () => h.controller.document(id),
      throwsA(isA<HydrostaticException>()),
    );
    expect(h.store.all().length, 1);
  });
  test('revoked session prevents route reads and preparation', () async {
    h.access = HydrostaticAccess(
      actor: h.access.actor,
      authorized: false,
      fieldSession: true,
    );
    expect(h.controller.allowed, isFalse);
    expect(h.controller.documents, isEmpty);
    await expectLater(
      h.controller.identify('AQ26000017'),
      throwsA(isA<HydrostaticException>()),
    );
  });
  test(
    'session changed in async verification creates no preparation',
    () async {
      h.verify = () async {
        h.access = HydrostaticAccess(
          actor: h.access.actor,
          authorized: false,
          fieldSession: true,
        );
      };
      await expectLater(
        h.controller.identify('AQ26000017'),
        throwsA(isA<HydrostaticException>()),
      );
      expect(h.store.all(), isEmpty);
    },
  );
  test('queued prepare cannot be attributed to later user', () async {
    final gate = Completer<void>();
    final wait = h.store.serial(() => gate.future);
    final prepare = h.repo.prepare(
      operationId: uuid(),
      testId: uuid(),
      cabinet: h.cabinet,
    );
    final assertion = expectLater(
      prepare,
      throwsA(isA<HydrostaticException>()),
    );
    h.access = HydrostaticAccess(
      actor: HydrostaticActorSnapshot(
        userId: uuid(),
        name: 'OTHER',
        sessionId: uuid(),
        deviceInstallationId: uuid(),
      ),
      authorized: true,
      fieldSession: true,
    );
    gate.complete();
    await wait;
    await assertion;
    expect(h.store.all(), isEmpty);
  });
  test('history started only; provisional number not reserved', () async {
    final passed = await h.passed();
    await h.controller.initialize();
    final prepared = await h.controller.identify('AQ26000017');
    expect(h.controller.history('AQ26000017').map((t) => t.id), [passed]);
    expect(h.controller.provisional(prepared), 2);
    expect(h.repo.sequences.last('AQ26000017'), 1);
  });
  test(
    'delete visibility enforces production, active and foreign protection',
    () async {
      final id = await h.controller.identify('AQ26000017');
      expect(h.controller.canDelete(id), isTrue);
      h.policy = const HydrostaticDevelopmentPolicy();
      h.controller.dispose();
      await h.reopen();
      h.makeController();
      await h.controller.initialize();
      expect(h.controller.canDelete(id), isFalse);
      await expectLater(
        h.controller.delete(id, id),
        throwsA(isA<HydrostaticException>()),
      );
    },
  );
  for (final role in ConstructionRole.values) {
    test('access adapter actual role ${role.name}', () async {
      final actor = h.access.actor;
      final sessions = MemorySessions()
        ..value = FieldSession(
          sessionId: actor.sessionId,
          userId: actor.userId,
          installationId: actor.deviceInstallationId,
          name: actor.name,
          accessToken: 'synthetic',
          refreshToken: 'synthetic',
          email: '',
          phone: '',
        );
      final changed = ChangeNotifier();
      final adapter = HydrostaticAccessAdapter(
        session: () => sessions.value,
        profile: () => ConstructionProfile(
          userId: actor.userId,
          displayName: actor.name,
          email: '',
          phone: '',
          role: role,
        ),
        cabinetAuthorized: () => true,
        sessions: sessions,
        changes: [changed],
      );
      expect(adapter.allowed, role == ConstructionRole.resident);
      if (adapter.allowed) {
        await adapter.verify();
        expect(
          adapter.current().actor.toJson().keys,
          isNot(contains('accessToken')),
        );
      }
      adapter.dispose();
      changed.dispose();
    });
  }
  test(
    'secure session mismatch denies access even if in-memory field session remains',
    () async {
      final a = h.access.actor;
      final session = FieldSession(
        sessionId: a.sessionId,
        userId: a.userId,
        installationId: a.deviceInstallationId,
        name: a.name,
        accessToken: 'synthetic',
        refreshToken: 'synthetic',
        email: '',
        phone: '',
      );
      final adapter = HydrostaticAccessAdapter(
        session: () => session,
        profile: () => ConstructionProfile(
          userId: a.userId,
          displayName: a.name,
          email: '',
          phone: '',
          role: ConstructionRole.resident,
        ),
        cabinetAuthorized: () => true,
        sessions: MemorySessions(),
        changes: [],
      );
      await expectLater(adapter.verify(), throwsA(isA<HydrostaticException>()));
      expect(adapter.allowed, isFalse);
      adapter.dispose();
    },
  );
  test(
    'preparation interrupted after commit recovers same UUID on retry',
    () async {
      var fail = true;
      h.store.fault = (boundary) async {
        if (fail && boundary == 'after:ready') {
          fail = false;
          throw StateError('synthetic disk interruption');
        }
      };
      await expectLater(h.controller.identify('AQ26000017'), throwsStateError);
      final committed = h.repo.journal.entries.single['testId'];
      final id = await h.controller.identify('AQ26000017');
      expect(id, committed);
      expect(h.store.all().length, 1);
      expect(h.repo.sequences.last('AQ26000017'), 0);
    },
  );
  test(
    'cabinet modified while secure session verifies is rejected before saving',
    () async {
      var verifications = 0;
      h.verify = () async {
        verifications++;
        if (verifications == 2) {
          h.records = [h.record(model: 'A3')];
        }
      };
      await expectLater(
        h.controller.identify('AQ26000017'),
        throwsA(isA<HydrostaticException>()),
      );
      expect(h.store.all(), isEmpty);
    },
  );
  for (final scenario in ['null', 'admin', 'profile-mismatch', 'revoked']) {
    test('session adapter rejects $scenario', () async {
      final a = h.access.actor;
      final sessions = MemorySessions()
        ..value = FieldSession(
          sessionId: a.sessionId,
          userId: a.userId,
          installationId: a.deviceInstallationId,
          name: a.name,
          accessToken: 'synthetic',
          refreshToken: 'synthetic',
          email: '',
          phone: '',
          kind: scenario == 'admin' ? SessionKind.admin : SessionKind.field,
        );
      final adapter = HydrostaticAccessAdapter(
        session: () => scenario == 'null' ? null : sessions.value,
        profile: () => ConstructionProfile(
          userId: scenario == 'profile-mismatch' ? uuid() : a.userId,
          displayName: a.name,
          email: '',
          phone: '',
          role: ConstructionRole.resident,
        ),
        cabinetAuthorized: () => scenario != 'revoked',
        sessions: sessions,
        changes: [],
      );
      expect(adapter.allowed, isFalse);
      await expectLater(adapter.verify(), throwsA(isA<HydrostaticException>()));
      adapter.dispose();
    });
  }
}
