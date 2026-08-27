import 'dart:io';
import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/core/network/api_client.dart';
import 'package:ddr001_levantamientos/core/persistence/local_store.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/core/services/app_controller.dart';
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
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ddr001-test-');
    Hive.init(root.path);
    final local = await LocalStore.open(), sessions = MemorySessions();
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
}
