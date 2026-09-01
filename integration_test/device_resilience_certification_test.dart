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
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

const stage = String.fromEnvironment('CERT_STAGE', defaultValue: 'seed');
const surveyId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const photoId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

class DeviceRemote implements ConstructionRemote {
  final events = <String>[];

  @override
  Future<Map<String, dynamic>> detail(String surveyId) async => const {
    'steps': [],
    'photos': [],
    'corrections': [],
  };

  @override
  Future<void> openStep(String survey, int step) async {
    if (survey.endsWith('000000000000')) {
      throw DioException(
        requestOptions: RequestOptions(path: '/open'),
        response: Response(
          requestOptions: RequestOptions(path: '/open'),
          statusCode: 409,
          data: {'code': 'STRUCTURAL_CONFLICT'},
        ),
        type: DioExceptionType.badResponse,
      );
    }
    events.add(survey);
  }

  @override
  Future<ConstructionProfile> profile() async => const ConstructionProfile(
    userId: '10000000-0000-4000-8000-000000000002',
    displayName: 'Certification',
    email: 'certification@example.com',
    phone: '1234567890',
    role: ConstructionRole.contractor,
  );

  @override
  Future<Map<String, dynamic>> createSurvey(BaseSurvey survey) async =>
      const {};
  @override
  Future<void> commentStep(String survey, int step, String? comment) async {}
  @override
  Future<void> completeStep(String survey, int step) async {}
  @override
  Future<void> upload(ConstructionPhoto photo) async {}
  @override
  Future<void> deletePhoto(String surveyId, String photoId) async {}
  @override
  Future<Map<String, dynamic>> verify(List<String> ids) async => const {};
  @override
  Future<List<Map<String, dynamic>>> list({
    bool resident = false,
    String? search,
    String? status,
  }) async => const [];
  @override
  Future<void> residentUpdate(String id, Map<String, dynamic> values) async {}
  @override
  Future<void> residentAction(
    String id,
    String action, [
    Map<String, dynamic>? body,
  ]) async {}
  @override
  Future<void> correctCanonicalLocation(
    String id,
    GeoPoint point,
    String reason,
  ) async {}
  @override
  Future<void> correctionComment(
    String surveyId,
    String correctionId,
    String? comment,
  ) async {}
  @override
  Future<void> completeCorrection(String surveyId, String correctionId) async {}
  @override
  Future<FieldSession> fieldLogin({
    required String name,
    required String email,
    required String phone,
    required String crew,
  }) => throw UnsupportedError('not used');
  @override
  Future<void> logout(FieldSession session) async {}
  @override
  Future<void> revokeExisting(String takeoverToken) async {}
}

BaseSurvey survey(String id) => BaseSurvey(
  id: id,
  displayIdentifier: 'Physical certification $id',
  contractorName: 'Certification',
  createdAt: DateTime.utc(2026, 8, 30),
  updatedAt: DateTime.utc(2026, 8, 30),
  status: SurveyStatus.inProgress,
  localState: LocalSurveyState.active,
  syncState: SyncState.pending,
  currentStep: 1,
  steps: List.generate(
    6,
    (index) => SurveyStep(
      number: index + 1,
      state: index == 0 ? StepState.open : StepState.locked,
      photoIds: id == surveyId && index == 0 ? const [photoId] : const [],
    ),
  ),
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('physical device zero-loss stage $stage', (tester) async {
    await Hive.initFlutter();
    final local = await LocalStore.open();
    final sessions = SecureSessionStore();

    if (stage == 'seed') {
      await local.surveysBox.clear();
      await local.photosBox.clear();
      await local.queueBox.clear();
      await local.journalBox.clear();
      final root = Directory(
        '${(await getApplicationSupportDirectory()).path}/certification',
      )..createSync(recursive: true);
      final evidence = File('${root.path}/$photoId.upload.jpg')
        ..writeAsBytesSync(List<int>.generate(4096, (index) => index & 0xff));
      final photo = ConstructionPhoto(
        id: photoId,
        surveyId: surveyId,
        localPath: evidence.path,
        thumbnailPath: evidence.path,
        sha256: 'a' * 64,
        capturedAt: DateTime.utc(2026, 8, 30),
        stepNumber: 1,
        location: GeoPoint(
          latitude: 29,
          longitude: -110,
          accuracy: 5,
          capturedAt: DateTime.utc(2026, 8, 30),
        ),
        syncState: PhotoSyncState.uploading,
      );
      final queued = SyncQueueItem(
        id: '$surveyId-uploadPhoto-$photoId',
        surveyId: surveyId,
        operation: QueueOperation.uploadPhoto,
        photoId: photoId,
        step: 1,
        attempts: 5,
        createdAt: DateTime.utc(2026, 8, 30),
        nextAttemptAt: DateTime.utc(2030),
      );
      await local.saveSurvey(survey(surveyId));
      await local.savePhoto(photo);
      await local.saveQueue(queued);
      await sessions.save(
        const FieldSession(
          sessionId: '10000000-0000-4000-8000-000000000001',
          userId: '10000000-0000-4000-8000-000000000002',
          accessToken: 'device-certification-access',
          refreshToken: 'device-certification-refresh',
          installationId: '10000000-0000-4000-8000-000000000003',
          name: 'Certification',
          email: 'certification@example.com',
          phone: '1234567890',
        ),
      );
      expect(local.surveys(), hasLength(1));
      expect(local.photos(), hasLength(1));
      expect(evidence.existsSync(), isTrue);
      return;
    }

    final config = AppConfig.fromEnvironment(
      environment: 'test',
      baseUrl: 'http://127.0.0.1:3003/api/v1',
    );
    final remote = DeviceRemote();
    final app = AppController(
      config: config,
      local: local,
      sessions: sessions,
      api: ApiClient(config: config, sessions: sessions, dio: Dio()),
      packageInfo: await PackageInfo.fromPlatform(),
      remote: remote,
    );
    app.surveys = local.surveys();
    app.photos = local.photos();
    app.queue = local.queue();
    app.session = await sessions.read();

    if (stage == 'recover') {
      await app.recoverLocalState(recoverCamera: false);
      expect(app.session, isNotNull);
      expect(app.surveys.single.id, surveyId);
      expect(app.photos.single.syncState, PhotoSyncState.retryRequired);
      expect(File(app.photos.single.localPath).existsSync(), isTrue);
      expect(app.queue.single.nextAttemptAt, DateTime.utc(2030));
      return;
    }

    if (stage == 'bulk') {
      app.surveys = [];
      app.photos = [];
      app.queue = [];
      for (var index = 0; index < 20; index++) {
        final id =
            '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
        final item = SyncQueueItem(
          id: '$id-openStep-1',
          surveyId: id,
          operation: QueueOperation.openStep,
          step: 1,
          createdAt: DateTime.utc(2026, 8, 30).add(Duration(seconds: index)),
        );
        app.surveys.add(survey(id));
        app.queue.add(item);
      }
      app.online = true;
      await app.synchronize();
      expect(remote.events, hasLength(19));
      expect(app.queue, hasLength(1));
      expect(app.queue.single.requiresReview, isTrue);
      return;
    }

    fail('Unknown CERT_STAGE=$stage');
  });
}
