import 'dart:io';

import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/core/media/photo_capture_service.dart';
import 'package:ddr001_levantamientos/core/network/api_client.dart';
import 'package:ddr001_levantamientos/core/persistence/local_store.dart';
import 'package:ddr001_levantamientos/core/persistence/uuid_hive_migration.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/core/services/app_controller.dart';
import 'package:ddr001_levantamientos/data/remote/construction_api.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

const surveyId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const photoId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

class MemorySessions implements SessionStore {
  FieldSession? value = const FieldSession(
    sessionId: '10000000-0000-4000-8000-000000000001',
    userId: '10000000-0000-4000-8000-000000000002',
    accessToken: 'access',
    refreshToken: 'refresh',
    installationId: '10000000-0000-4000-8000-000000000003',
    name: 'E2E',
    email: 'e2e@example.com',
    phone: '1234567890',
  );

  @override
  Future<void> clear() async => value = null;
  @override
  Future<String> installationId() async =>
      '10000000-0000-4000-8000-000000000003';
  @override
  Future<FieldSession?> read() async => value;
  @override
  Future<void> save(FieldSession value) async => this.value = value;
}

class AmbiguousUploadRemote implements ConstructionRemote {
  bool serverHasPhoto = false;
  int uploadCalls = 0;
  int verifyCalls = 0;

  @override
  Future<void> upload(ConstructionPhoto photo) async {
    uploadCalls++;
    serverHasPhoto = true; // Commit happened on the server.
    throw DioException(
      requestOptions: RequestOptions(path: '/photos'),
      type: DioExceptionType.receiveTimeout,
      message: 'Response was lost after server commit',
    );
  }

  @override
  Future<Map<String, dynamic>> detail(String id) async => {
    'steps': const [],
    'corrections': const [],
    'photos': serverHasPhoto
        ? [
            {
              'photo_id': photoId,
              'surveyId': surveyId,
              'integrity_status': 'not_verified',
            },
          ]
        : const [],
  };

  @override
  Future<Map<String, dynamic>> verify(List<String> ids) async {
    verifyCalls++;
    return {
      'items': [
        for (final id in ids) {'photoId': id, 'status': 'confirmed'},
      ],
    };
  }

  @override
  Future<ConstructionProfile> profile() async => const ConstructionProfile(
    userId: '10000000-0000-4000-8000-000000000002',
    displayName: 'E2E',
    email: 'e2e@example.com',
    phone: '1234567890',
    role: ConstructionRole.contractor,
  );

  @override
  Future<Map<String, dynamic>> createSurvey(BaseSurvey survey) async =>
      const {};
  @override
  Future<void> openStep(String survey, int step) async {}
  @override
  Future<void> commentStep(String survey, int step, String? comment) async {}
  @override
  Future<void> completeStep(String survey, int step) async {}
  @override
  Future<void> deletePhoto(String surveyId, String photoId) async {}
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'timeout after server photo commit never strands media as uploadedUnverified',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'ambiguous-upload-e2e-',
      );
      addTearDown(() async {
        await Hive.close();
        await root.delete(recursive: true);
      });
      Hive.init(root.path);
      final local = await LocalStore.open();
      final sessions = MemorySessions();
      final remote = AmbiguousUploadRemote();
      final config = AppConfig.fromEnvironment(
        environment: 'test',
        baseUrl: 'http://127.0.0.1:3003/api/v1',
      );
      final app = AppController(
        config: config,
        local: local,
        sessions: sessions,
        api: ApiClient(config: config, sessions: sessions, dio: Dio()),
        packageInfo: PackageInfo(
          appName: 'DDR001',
          packageName: 'com.aquafim.ddr001levantamientos',
          version: '1.0.0',
          buildNumber: '1',
        ),
        remote: remote,
      );
      app.session = await sessions.read();
      app.profile = await remote.profile();
      app.online = true;

      final file = File('${root.path}/photo.jpg')..writeAsBytesSync([1, 2, 3]);
      final survey = BaseSurvey(
        id: surveyId,
        displayIdentifier: 'E2E ambiguous upload',
        contractorName: 'E2E',
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
          ),
        ),
      );
      final photo = ConstructionPhoto(
        id: photoId,
        surveyId: surveyId,
        localPath: file.path,
        thumbnailPath: file.path,
        sha256: await sha256File(file),
        capturedAt: DateTime.utc(2026, 8, 30),
        stepNumber: 1,
        location: GeoPoint(
          latitude: 29.0,
          longitude: -110.0,
          accuracy: 5,
          capturedAt: DateTime.utc(2026, 8, 30),
        ),
        syncState: PhotoSyncState.queued,
      );
      final queued = SyncQueueItem(
        id: canonicalQueueItemId(
          SyncQueueItem(
            id: '',
            surveyId: surveyId,
            operation: QueueOperation.uploadPhoto,
            photoId: photoId,
            step: 1,
            createdAt: DateTime.utc(2026, 8, 30),
          ),
        ),
        surveyId: surveyId,
        operation: QueueOperation.uploadPhoto,
        photoId: photoId,
        step: 1,
        createdAt: DateTime.utc(2026, 8, 30),
      );

      app.surveys = [survey];
      app.photos = [photo];
      app.queue = [queued];
      await local.saveSurvey(survey);
      await local.savePhoto(photo);
      await local.saveQueue(queued);

      await app.synchronize();
      expect(remote.uploadCalls, 1);
      expect(remote.serverHasPhoto, isTrue);
      expect(
        app.queue,
        isNotEmpty,
        reason: 'timeout must preserve durable work',
      );

      app.online =
          true; // Simulate connectivity returning after process/network loss.
      await app.synchronize();

      final current = app.photos.single;
      final verifyStillDurable = app.queue.any(
        (item) =>
            item.operation == QueueOperation.verifyPhotos &&
            item.photoId == photoId,
      );
      expect(
        current.syncState == PhotoSyncState.confirmed || verifyStillDurable,
        isTrue,
        reason:
            'Reconciliation must never remove the ambiguous upload without '
            'either confirming integrity or persisting verifyPhotos.',
      );
    },
  );
}
