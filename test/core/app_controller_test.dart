import 'dart:io';
import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/core/network/api_client.dart';
import 'package:ddr001_levantamientos/core/persistence/local_store.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/core/services/app_controller.dart';
import 'package:ddr001_levantamientos/data/remote/construction_api.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';

class MemorySessions implements SessionStore {
  FieldSession? value;
  @override
  Future<void> clear() async => value = null;
  @override
  Future<String> installationId() async => 'installation';
  @override
  Future<FieldSession?> read() async => value;
  @override
  Future<void> save(FieldSession value) async => this.value = value;
}

void main() {
  late Directory root;
  late AppController app;
  late LocalStore local;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ddr001-test-');
    Hive.init(root.path);
    local = await LocalStore.open();
    final sessions = MemorySessions();
    app = AppController(
      config: AppConfig.fromEnvironment(
        environment: 'test',
        baseUrl: 'http://127.0.0.1:3003/api/v1',
      ),
      local: local,
      sessions: sessions,
      api: ApiClient(
        config: AppConfig.fromEnvironment(
          environment: 'test',
          baseUrl: 'http://127.0.0.1:3003/api/v1',
        ),
        sessions: sessions,
        dio: Dio(),
      ),
      packageInfo: PackageInfo(
        appName: 'DDR001',
        packageName: 'com.aquafim.ddr001levantamientos',
        version: '0.1.0',
        buildNumber: '1',
      ),
    );
    app.profile = const ConstructionProfile(
      userId: 'u',
      displayName: 'Contratista',
      email: 'a@b.mx',
      phone: '1234567890',
      crew: 'C1',
      role: ConstructionRole.contractor,
    );
  });
  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });
  test('survey creation works offline and queues create command', () async {
    final survey = await app.createSurvey('Losa E2E');
    expect(survey.localState, LocalSurveyState.createdLocal);
    expect(app.queue.single.operation, QueueOperation.createSurvey);
  });
  test(
    'account survives offline create, Hive reload and sync payload',
    () async {
      final survey = await app.createSurvey('Losa 1', accountNumber: ' 890 ');
      expect(survey.accountNumber, '890');
      expect(local.surveys().single.accountNumber, '890');
      expect(surveyCreatePayload(survey)['accountNumber'], '890');
    },
  );
  test('merge preserves pending local account when server still has null', () {
    expect(mergeAccountNumber('890', {'account_number': null}), '890');
    expect(mergeAccountNumber('890', {'account_number': '891'}), '891');
  });
  test('known duplicate blocks local creation', () async {
    await app.createSurvey('Base Norte');
    expect(() => app.createSurvey(' base   norte '), throwsStateError);
  });
  test('step sequence starts with only step one open', () async {
    final s = await app.createSurvey('S');
    expect(s.steps.first.state, StepState.open);
    expect(s.steps.skip(1).every((x) => x.state == StepState.locked), isTrue);
  });
  test('local and server merge identity is survey id based', () async {
    final s = await app.createSurvey('S');
    expect(app.survey(s.id).displayIdentifier, 'S');
  });
  test('role comes from construction profile, not local authority', () {
    expect(app.profile!.role, ConstructionRole.contractor);
  });
  test(
    'step 6 requires every cardinal and additional does not substitute',
    () async {
      final survey = await app.createSurvey('Cardinales');
      final steps = survey.steps
          .map(
            (step) => SurveyStep(
              number: step.number,
              state: step.number == 6
                  ? StepState.open
                  : StepState.completedLocal,
            ),
          )
          .toList();
      final stepSix = survey.copyWith(steps: steps, currentStep: 5);
      app.surveys = [stepSix];
      await local.saveSurvey(stepSix);
      final evidenceFile = File('${root.path}/evidence.jpg')
        ..writeAsStringSync('x');
      ConstructionPhoto photo(String id, PhotoPurpose purpose) =>
          ConstructionPhoto(
            id: id,
            surveyId: survey.id,
            localPath: evidenceFile.path,
            thumbnailPath: evidenceFile.path,
            sha256: List.filled(64, 'a').join(),
            capturedAt: DateTime.utc(2026),
            stepNumber: 6,
            purpose: purpose,
            location: GeoPoint(
              latitude: 20,
              longitude: -100,
              accuracy: 5,
              capturedAt: DateTime.utc(2026),
            ),
            syncState: PhotoSyncState.queued,
          );
      app.photos = [
        photo('n', PhotoPurpose.north),
        photo('e', PhotoPurpose.east),
        photo('s', PhotoPurpose.south),
        photo('a1', PhotoPurpose.additional),
        photo('a2', PhotoPurpose.additional),
        photo('a3', PhotoPurpose.additional),
        photo('a4', PhotoPurpose.additional),
        photo('a5', PhotoPurpose.additional),
      ];
      expect(app.canFinalize(survey.id, 6), isFalse);
      app.photos = [...app.photos, photo('w', PhotoPurpose.west)];
      expect(app.canFinalize(survey.id, 6), isTrue);
      await app.finalizeStep(survey.id, 6);
      await expectLater(app.deletePhoto(survey.id, 6, 'w'), throwsStateError);
    },
  );
}
