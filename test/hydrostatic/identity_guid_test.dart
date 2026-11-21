import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'harness.dart';

// Synthetic SQL uniqueidentifier values; neither is UUID v4.
const legacyUser = '12345678-1234-1234-1234-123456789abc';
const legacySession = '12345678-1234-11ef-8123-123456789abc';
const installation = '12345678-1234-4123-8123-123456789abc';

HydrostaticActorSnapshot actor({
  String user = legacyUser,
  String session = legacySession,
  String deviceInstallation = installation,
}) => HydrostaticActorSnapshot(
  userId: user,
  name: 'SYNTHETIC RESIDENT',
  sessionId: session,
  deviceInstallationId: deviceInstallation,
);

void main() {
  test(
    'historical server GUIDs preserve user and session without replacement',
    () {
      final a = actor();
      expect(a.userId, legacyUser);
      expect(a.sessionId, legacySession);
      expect(a.deviceInstallationId, installation);
      expect(actor(user: installation).sessionId, legacySession);
      expect(actor(session: installation).userId, legacyUser);
      expect(
        HydrostaticActorSnapshot.fromJson(a.toJson()).toJson(),
        a.toJson(),
      );
    },
  );

  test('new UUID v4 identity remains valid', () {
    expect(
      actor(user: installation, session: installation).userId,
      installation,
    );
    expect(hydroUuid(installation), installation);
  });

  test('local installation still requires UUID v4', () {
    expect(
      () => actor(deviceInstallation: legacySession),
      throwsA(isA<HydrostaticException>()),
    );
  });

  for (final invalid in [
    '',
    'not-a-guid',
    '12345678-1234-1234-1234-123456789abz',
    '00000000-0000-0000-0000-000000000000',
    legacyUser.toUpperCase(),
    ' $legacyUser',
  ]) {
    test(
      'invalid/noncanonical server identity rejected: ${invalid.length}',
      () {
        expect(
          () => actor(user: invalid),
          throwsA(isA<HydrostaticException>()),
        );
        expect(
          () => actor(session: invalid),
          throwsA(isA<HydrostaticException>()),
        );
      },
    );
  }

  test('test, operation and capture IDs still require v4', () async {
    final h = Harness();
    await h.open();
    try {
      h.access = HydrostaticAccess(
        actor: actor(),
        authorized: true,
        fieldSession: true,
      );
      await expectLater(
        h.repo.prepare(
          operationId: legacyUser,
          testId: uuid(),
          cabinet: h.cabinet,
        ),
        throwsA(isA<HydrostaticException>()),
      );
      await expectLater(
        h.repo.prepare(
          operationId: uuid(),
          testId: legacyUser,
          cabinet: h.cabinet,
        ),
        throwsA(isA<HydrostaticException>()),
      );
      expect(
        () => HydrostaticCaptureIntent(
          id: legacyUser,
          testId: uuid(),
          actorId: legacyUser,
          role: HydrostaticEvidenceRole.initialSetup,
          requestedAt: h.clock.utc,
        ),
        throwsA(isA<HydrostaticException>()),
      );
      expect(h.store.all(), isEmpty);
    } finally {
      await h.close();
    }
  });

  test(
    'historical actor survives preparation, photos, result, video and Hive reopen',
    () async {
      final h = Harness();
      await h.open();
      try {
        h.access = HydrostaticAccess(
          actor: actor(),
          authorized: true,
          fieldSession: true,
        );
        final intent = HydrostaticCaptureIntent(
          id: uuid(),
          testId: uuid(),
          actorId: legacyUser,
          role: HydrostaticEvidenceRole.initialSetup,
          requestedAt: h.clock.utc,
        );
        expect(intent.actorId, legacyUser);
        final id = await h.passed();
        await h.repo.declareVideoSent(id, uuid());
        final before = h.repo.get(id)!.toJson();
        final journal = Map.of(h.store.journal.toMap());
        final metadata = Map.of(h.store.metadata.toMap());
        final evidence = h.repo.get(id)!.evidence;
        for (final e in evidence) {
          expect(e.actorId, legacyUser);
          expect(await h.files.verify(e), isTrue);
        }
        await h.reopen();
        expect(h.repo.get(id)!.toJson(), before);
        expect(h.store.journal.toMap(), journal);
        expect(h.store.metadata.toMap(), metadata);
        expect(h.repo.forUser().single.actor.userId, legacyUser);
        for (final e in h.repo.get(id)!.evidence) {
          expect(await h.files.verify(e), isTrue);
        }
        expect(h.network.calls, 0);
      } finally {
        await h.close();
      }
    },
  );
}
