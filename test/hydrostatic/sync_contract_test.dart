import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_bootstrap.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync_api.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync_store.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_approval_policy.dart';
import 'harness.dart';
import 'sync_test.dart' show FakeHydroRemote;

void main() {
  test(
    'production synchronization needs both explicit flags and a valid transport',
    () {
      final config = AppConfig(
        environment: 'production',
        apiBaseUrl: Uri.parse('https://api.example.invalid/api/v1'),
      );
      expect(hydrostaticSyncEnabled(config, requested: true), false);
      expect(
        hydrostaticSyncEnabled(
          config,
          requested: false,
          productionRequested: true,
        ),
        false,
      );
      expect(
        hydrostaticSyncEnabled(
          config,
          requested: true,
          productionRequested: true,
        ),
        true,
      );
      expect(
        hydrostaticSyncEnabled(
          AppConfig(environment: 'development', apiBaseUrl: config.apiBaseUrl),
          requested: true,
          productionRequested: true,
        ),
        false,
      );
      expect(
        hydrostaticSyncEnabled(
          AppConfig(
            environment: 'production',
            apiBaseUrl: Uri.parse('http://localhost:3002/api/v1'),
          ),
          requested: true,
          productionRequested: true,
        ),
        false,
      );
      expect(
        hydrostaticSyncEnabled(
          AppConfig(
            environment: 'production',
            apiBaseUrl: Uri.parse(AppConfig.productionHttpApiBaseUrl),
          ),
          requested: true,
          productionRequested: true,
        ),
        true,
      );
    },
  );

  test('sync gate requires explicit TEST and rejects production host', () {
    for (final env in ['production', 'development', 'test']) {
      final config = AppConfig(
        environment: env,
        apiBaseUrl: Uri.parse('http://localhost:3003/api/v1'),
      );
      expect(hydrostaticSyncEnabled(config, requested: true), env == 'test');
      expect(hydrostaticSyncEnabled(config, requested: false), false);
    }
    expect(
      hydrostaticSyncEnabled(
        AppConfig(
          environment: 'test',
          apiBaseUrl: Uri.parse('http://cifra.aquafim.com:3002/api/v1'),
        ),
        requested: true,
      ),
      false,
    );
  });

  test(
    'complete synthetic checkpoints preserve HAPI-2 fields and causal chain',
    () async {
      final h = Harness()..approvalPolicy = HydrostaticApprovalPolicy.approved;
      await h.open();
      final outbox = await HydrostaticSyncStore.open(
        Directory('${h.root.path}/sync'),
      );
      final remote = FakeHydroRemote();
      final sync = HydrostaticSync(
        repository: h.repo,
        store: outbox,
        remote: remote,
        identity: () => HydrostaticSyncIdentity(
          h.access.actor.userId,
          h.access.actor.sessionId,
          h.access.actor.deviceInstallationId,
        ),
        verifySession: () async {},
        online: () => true,
        enabled: true,
        now: () => h.clock.utc,
      );
      try {
        Future<String> start() async {
          final id = uuid();
          await h.repo.prepare(
            operationId: uuid(),
            testId: id,
            cabinet: HydrostaticCabinetSnapshot(
              uid: 'AQ26980015',
              model: 'A1',
              automated: false,
              cabinetId: uuid(),
              knownStatus: 'validated',
              sourceVersion: 1,
            ),
          );
          await sync.run();
          await h.add(id, HydrostaticEvidenceRole.initialSetup);
          await h.repo.requestStart(id, uuid());
          await h.repo.start(id, uuid(), h.location());
          await sync.run();
          return id;
        }

        final pass = await start();
        h.clock.advance(1000);
        await h.add(
          pass,
          HydrostaticEvidenceRole.manometer5Bar,
          gps: h.location(),
        );
        h.clock.advance(1000);
        await h.repo.finish(pass, uuid());
        await h.repo.answerLeaks(pass, uuid(), false);
        await sync.run();
        h.clock.advance(1000);
        await h.add(pass, HydrostaticEvidenceRole.final4Bar);
        await h.repo.closePass(pass, uuid());
        await sync.run();
        await h.repo.declareVideoSent(pass, uuid());
        await sync.run();
        final leak = await start();
        h.clock.advance(1000);
        await h.repo.finish(leak, uuid());
        await h.repo.answerLeaks(leak, uuid(), true);
        await h.repo.saveLeaks(leak, uuid(), [
          HydrostaticLeak(id: uuid(), jointCode: 'J01', pressureMilliBar: 1250),
          HydrostaticLeak(
            id: uuid(),
            jointCode: 'J11',
            pressureMilliBar: 4500,
            description: 'SYNTHETIC JOINT',
          ),
        ]);
        await h.add(leak, HydrostaticEvidenceRole.leakEvidence);
        await h.repo.closeLeak(leak, uuid());
        await sync.run();
        final discard = await start();
        h.clock.advance(1000);
        await h.repo.finish(discard, uuid());
        await sync.run();
        h.clock.advance(1800001);
        await h.repo.discardExpired(discard, uuid());
        await sync.run();
        final review = await start();
        h.clock.advance(1000);
        await h.repo.finish(review, uuid());
        h.clock.utc = h.clock.utc.subtract(const Duration(hours: 1));
        await h.repo.reviewClock(review, uuid());
        await sync.run();
        expect(remote.heads, hasLength(4));
        expect(remote.requests, hasLength(15));
        for (final c in remote.requests) {
          final p = jsonDecode(c['payloadJson']);
          expect(p['historyManifest'], isNotEmpty);
          expect(p['document']['actor'], h.access.actor.toJson());
          expect(p['document']['syncState'], 'LOCAL_ONLY');
          expect(c['payloadSha256'], hydroSyncHash(c['payloadJson']));
        }
        final export = Platform.environment['HYDROSTATIC_CONTRACT_FIXTURE'];
        if (export != null) {
          await File(
            export,
          ).writeAsString(jsonEncode(remote.requests), flush: true);
        }
      } finally {
        sync.dispose();
        await outbox.close();
        await h.close();
      }
    },
  );
}
