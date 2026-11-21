import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_approval_policy.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_repository.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_store.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';

String uuid() => const Uuid().v4();

class FakeHydroClock implements HydrostaticClock {
  DateTime utc = DateTime.utc(2026, 10, 27, 10);
  String runId = 'run-1';
  int ticks = 1000;
  @override
  HydrostaticClockReading now() => HydrostaticClockReading(utc, runId, ticks);
  void advance(int milliseconds) {
    utc = utc.add(Duration(milliseconds: milliseconds));
    ticks += milliseconds;
  }

  void reboot() {
    runId = uuid();
    ticks = 0;
  }
}

class DenyHydroNetwork extends HttpOverrides {
  int calls = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    calls++;
    throw StateError('HTTP prohibited in hydrostatic fixture');
  }
}

class Harness {
  final network = DenyHydroNetwork();
  HttpOverrides? previousNetwork;
  late Directory root;
  late HydrostaticStore store;
  late HydrostaticRepository repo;
  late LocalHydrostaticEvidenceFiles files;
  final clock = FakeHydroClock();
  late HydrostaticAccess access;
  final cabinet = HydrostaticCabinetSnapshot(
    uid: 'AQ26000017',
    model: 'A1',
    automated: false,
  );
  HydrostaticDevelopmentPolicy policy = const HydrostaticDevelopmentPolicy(
    environment: 'test',
    enabled: true,
    syntheticData: true,
  );
  // Synthetic test procedure only; not a production default.
  HydrostaticApprovalPolicy approvalPolicy = const HydrostaticApprovalPolicy(
    version: 'synthetic-test-only',
    maximumFinalDelay: Duration(minutes: 10),
  );
  bool capturing = false;
  Future<void> open() async {
    previousNetwork = HttpOverrides.current;
    HttpOverrides.global = network;
    root = await Directory.systemTemp.createTemp('hydrostatic-synthetic-');
    access = HydrostaticAccess(
      actor: HydrostaticActorSnapshot(
        userId: uuid(),
        name: 'SYNTHETIC OPERATOR',
        sessionId: uuid(),
        deviceInstallationId: uuid(),
      ),
      authorized: true,
      fieldSession: true,
    );
    await reopen(first: true);
  }

  Future<void> reopen({bool first = false}) async {
    if (!first) await store.close();
    store = await HydrostaticStore.open(Directory('${root.path}/db'));
    files = LocalHydrostaticEvidenceFiles(root);
    repo = HydrostaticRepository(
      store: store,
      clock: clock,
      access: () => access,
      files: files,
      development: policy,
      isCapturing: (_) => capturing,
      approvalPolicy: approvalPolicy,
    );
  }

  HydrostaticLocation location({DateTime? at, double accuracy = 5}) =>
      HydrostaticLocation(
        latitude: 20,
        longitude: -100,
        accuracy: accuracy,
        fixAt: at ?? clock.utc,
        acquiredAt: at ?? clock.utc,
        source: 'synthetic',
      );
  Future<String> prepare() async {
    final id = uuid();
    await repo.prepare(operationId: uuid(), testId: id, cabinet: cabinet);
    return id;
  }

  Future<HydrostaticEvidence> evidence(
    String id,
    HydrostaticEvidenceRole role, {
    String? text,
    DateTime? at,
    HydrostaticLocation? gps,
    HydrostaticEvidenceState state = HydrostaticEvidenceState.ready,
    HydrostaticIntegrity integrity = HydrostaticIntegrity.verified,
  }) async {
    final photoId = uuid();
    final relative = 'hydrostatic/$id/evidence/$photoId.original.jpg';
    final file = File('${root.path}/$relative');
    await file.parent.create(recursive: true);
    // Synthetic byte fixture: persistence tests hash files; camera decoding is outside M2.
    final bytes = (text ?? photoId).codeUnits;
    await file.writeAsBytes(bytes, flush: true);
    return HydrostaticEvidence(
      id: photoId,
      testId: id,
      captureIntentId: uuid(),
      actorId: access.actor.userId,
      role: role,
      originalPath: relative,
      sha256: sha256.convert(bytes).toString(),
      byteLength: bytes.length,
      capturedAt: at ?? clock.utc,
      timeSource: HydrostaticCaptureTimeSource.cameraMetadata,
      location: gps,
      state: state,
      integrity: integrity,
    );
  }

  Future<void> add(
    String id,
    HydrostaticEvidenceRole role, {
    HydrostaticLocation? gps,
  }) async => repo.addEvidence(id, uuid(), await evidence(id, role, gps: gps));
  Future<String> starting() async {
    final id = await prepare();
    await add(id, HydrostaticEvidenceRole.initialSetup);
    await repo.requestStart(id, uuid());
    return id;
  }

  Future<String> active() async {
    final id = await starting();
    await repo.start(id, uuid(), location());
    return id;
  }

  Future<String> ended({bool yes = true}) async {
    final id = await active();
    clock.advance(10000);
    if (!yes) {
      await add(id, HydrostaticEvidenceRole.manometer5Bar, gps: location());
    }
    clock.advance(1000);
    await repo.finish(id, uuid());
    await repo.answerLeaks(id, uuid(), yes);
    return id;
  }

  Future<String> passed() async {
    final id = await ended(yes: false);
    clock.advance(1000);
    await add(id, HydrostaticEvidenceRole.final4Bar);
    await repo.closePass(id, uuid());
    return id;
  }

  Future<void> close() async {
    await store.close();
    await root.delete(recursive: true);
    HttpOverrides.global = previousNetwork;
    hydroRequire(
      network.calls == 0,
      'HTTP_FORBIDDEN',
      'Unexpected HTTP call in test.',
    );
  }
}
