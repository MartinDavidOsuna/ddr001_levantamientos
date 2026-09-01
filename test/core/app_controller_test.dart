import 'dart:io';
import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/core/network/api_client.dart';
import 'package:ddr001_levantamientos/core/persistence/construction_operation_journal.dart';
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
      role: ConstructionRole.contractor,
    );
    app.session = const FieldSession(
      sessionId: 'session',
      userId: 'u',
      accessToken: 'token',
      refreshToken: 'refresh',
      installationId: 'installation',
      name: 'Contratista',
      email: 'a@b.mx',
      phone: '1234567890',
    );
    app.online = false;
  });
  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });
  test('C01 new offline survey persists create then initial open', () async {
    final survey = await app.createSurvey('Losa E2E');
    expect(survey.localState, LocalSurveyState.createdLocal);
    expect(app.queue.map((item) => (item.operation, item.step)), [
      (QueueOperation.createSurvey, null),
      (QueueOperation.openStep, 1),
    ]);
    expect(
      app.queue.where(
        (item) => item.operation == QueueOperation.openStep && item.step == 1,
      ),
      hasLength(1),
    );
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
  test('local-only delete writes tombstone before purging evidence', () async {
    final survey = await app.createSurvey('Delete durable');
    final file = File('${root.path}/delete.jpg')..writeAsStringSync('evidence');
    final photo = ConstructionPhoto(
      id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      surveyId: survey.id,
      localPath: file.path,
      thumbnailPath: file.path,
      sha256: 'a' * 64,
      capturedAt: DateTime.utc(2026, 8, 30),
      stepNumber: 1,
      syncState: PhotoSyncState.localOnly,
    );
    app.photos = [photo];
    app.surveys = [
      survey.copyWith(
        steps: [
          survey.steps.first.copyWith(photoIds: [photo.id]),
          ...survey.steps.skip(1),
        ],
      ),
    ];
    await local.savePhoto(photo);
    await local.saveSurvey(app.surveys.single);

    await app.deletePhoto(survey.id, 1, photo.id);

    final tombstone = local.journal.find('delete-${photo.id}')!;
    expect(tombstone.state.name, 'committed');
    expect(file.existsSync(), isFalse);
    expect(local.photos(), isEmpty);
    expect(app.survey(survey.id).steps.first.photoIds, isEmpty);
  });
  test(
    'remote-possible delete preserves bytes until server confirmation',
    () async {
      final survey = await app.createSurvey('Delete pending remote');
      app.queue = [];
      await local.queueBox.clear();
      final file = File('${root.path}/delete-remote.jpg')
        ..writeAsStringSync('evidence');
      final photo = ConstructionPhoto(
        id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        surveyId: survey.id,
        localPath: file.path,
        thumbnailPath: file.path,
        sha256: 'a' * 64,
        capturedAt: DateTime.utc(2026, 8, 30),
        stepNumber: 1,
        syncState: PhotoSyncState.confirmed,
      );
      app.photos = [photo];
      app.surveys = [
        survey.copyWith(
          steps: [
            survey.steps.first.copyWith(photoIds: [photo.id]),
            ...survey.steps.skip(1),
          ],
        ),
      ];
      await local.savePhoto(photo);

      await app.deletePhoto(survey.id, 1, photo.id);

      expect(file.existsSync(), isTrue);
      expect(app.photos.single.syncState, PhotoSyncState.deleted);
      expect(app.queue.single.operation, QueueOperation.deletePhoto);
      expect(
        local.journal.find('delete-${photo.id}')!.state,
        ConstructionJournalState.queued,
      );
    },
  );
  for (final boundary in const [
    ConstructionJournalState.prepared,
    ConstructionJournalState.queued,
    ConstructionJournalState.failedNeedsReview,
  ]) {
    test('bootstrap repairs remote delete boundary ${boundary.name}', () async {
      final survey = await app.createSurvey('Delete boundary');
      app.queue = [];
      await local.queueBox.clear();
      final file = File('${root.path}/delete-${boundary.name}.jpg')
        ..writeAsStringSync('evidence');
      final photo = ConstructionPhoto(
        id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        surveyId: survey.id,
        localPath: file.path,
        thumbnailPath: file.path,
        sha256: 'a' * 64,
        capturedAt: DateTime.utc(2026, 8, 30),
        stepNumber: 1,
        syncState: PhotoSyncState.confirmed,
      );
      final linked = survey.copyWith(
        steps: [
          survey.steps.first.copyWith(photoIds: [photo.id]),
          ...survey.steps.skip(1),
        ],
      );
      app.surveys = [linked];
      app.photos = [photo];
      await local.saveSurvey(linked);
      await local.savePhoto(photo);
      await local.journal.save(
        ConstructionJournalEntry(
          id: 'delete-${photo.id}',
          operation: ConstructionJournalOperation.deletePhoto,
          state: boundary,
          surveyId: survey.id,
          photoId: photo.id,
          step: 1,
          uploadPath: file.path,
          thumbnailPath: file.path,
          sha256: photo.sha256,
          fileSize: file.lengthSync(),
          remotePossible: true,
          createdAt: DateTime.utc(2026, 8, 30),
        ),
      );

      await app.recoverLocalState(recoverCamera: false);

      expect(app.photos.single.syncState, PhotoSyncState.deleted);
      expect(app.survey(survey.id).steps.first.photoIds, isEmpty);
      expect(file.existsSync(), isTrue);
      expect(app.queue, hasLength(1));
      expect(app.queue.single.operation, QueueOperation.deletePhoto);
      expect(local.journal.find('delete-${photo.id}')!.state, boundary);
    });
  }
  test(
    'bootstrap recovery resets uploading and recreates upload queue',
    () async {
      final survey = await app.createSurvey('Killed upload');
      app.queue = [];
      await local.queueBox.clear();
      final file = File('${root.path}/uploading.jpg')
        ..writeAsStringSync('bytes');
      final photo = ConstructionPhoto(
        id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        surveyId: survey.id,
        localPath: file.path,
        thumbnailPath: file.path,
        sha256: 'a' * 64,
        capturedAt: DateTime.utc(2026, 8, 30),
        stepNumber: 1,
        location: GeoPoint(
          latitude: 20,
          longitude: -100,
          accuracy: 5,
          capturedAt: DateTime.utc(2026, 8, 30),
        ),
        syncState: PhotoSyncState.uploading,
      );
      app.photos = [photo];
      await local.savePhoto(photo);

      await app.recoverLocalState(recoverCamera: false);

      expect(app.photos.single.syncState, PhotoSyncState.retryRequired);
      expect(app.queue.single.operation, QueueOperation.uploadPhoto);
      expect(app.survey(survey.id).steps.first.photoIds, contains(photo.id));
    },
  );

  test(
    'bootstrap recovery resets verifying and recreates verify queue',
    () async {
      final survey = await app.createSurvey('Killed verify');
      app.queue = [];
      await local.queueBox.clear();
      final file = File('${root.path}/verifying.jpg')
        ..writeAsStringSync('bytes');
      final photo = ConstructionPhoto(
        id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        surveyId: survey.id,
        localPath: file.path,
        thumbnailPath: file.path,
        sha256: 'a' * 64,
        capturedAt: DateTime.utc(2026, 8, 30),
        stepNumber: 1,
        syncState: PhotoSyncState.verifying,
      );
      app.photos = [photo];
      await local.savePhoto(photo);

      await app.recoverLocalState(recoverCamera: false);

      expect(app.photos.single.syncState, PhotoSyncState.uploadedUnverified);
      expect(app.queue.single.operation, QueueOperation.verifyPhotos);
    },
  );

  test(
    'missing local evidence is reported without deleting metadata',
    () async {
      final survey = await app.createSurvey('Missing evidence');
      app.queue = [];
      await local.queueBox.clear();
      final photo = ConstructionPhoto(
        id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        surveyId: survey.id,
        localPath: '${root.path}/missing.jpg',
        thumbnailPath: '${root.path}/missing-thumb.jpg',
        sha256: 'a' * 64,
        capturedAt: DateTime.utc(2026, 8, 30),
        stepNumber: 1,
        syncState: PhotoSyncState.queued,
      );
      app.photos = [photo];
      await local.savePhoto(photo);

      await app.recoverLocalState(recoverCamera: false);

      expect(app.photos.single.syncState, PhotoSyncState.missingLocal);
      expect(local.photos(), hasLength(1));
      expect(app.surveys, hasLength(1));
    },
  );
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
      app.photos = [
        ...app.photos,
        photo(
          'pending-additional',
          PhotoPurpose.additional,
        ).copyWith(locationState: PhotoLocationState.pending),
      ];
      expect(
        app.canFinalize(survey.id, 6),
        isFalse,
        reason: 'additional evidence is also required to be georeferenced',
      );
      app.photos = app.photos
          .where((item) => item.id != 'pending-additional')
          .toList();
      await app.finalizeStep(survey.id, 6);
      await expectLater(app.deletePhoto(survey.id, 6, 'w'), throwsStateError);
    },
  );

  test(
    'C09 finalizing a stage durably queues the next remote stage opening',
    () async {
      final survey = await app.createSurvey('Next stage causal order');
      app.queue = [];
      await local.queueBox.clear();
      final evidenceFile = File('${root.path}/next-stage.jpg')
        ..writeAsStringSync('x');
      final photo = ConstructionPhoto(
        id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        surveyId: survey.id,
        localPath: evidenceFile.path,
        thumbnailPath: evidenceFile.path,
        sha256: List.filled(64, 'a').join(),
        capturedAt: DateTime.utc(2026),
        stepNumber: 1,
        location: GeoPoint(
          latitude: 20,
          longitude: -100,
          accuracy: 5,
          capturedAt: DateTime.utc(2026),
        ),
        syncState: PhotoSyncState.confirmed,
      );
      app.photos = [photo];
      app.surveys = [
        survey.copyWith(
          steps: [
            survey.steps.first.copyWith(photoIds: [photo.id]),
            ...survey.steps.skip(1),
          ],
        ),
      ];

      await app.finalizeStep(survey.id, 1);

      expect(
        app.queue.map((item) => (item.operation, item.step)),
        containsAll(<(QueueOperation, int?)>[
          (QueueOperation.openStep, 1),
          (QueueOperation.completeStep, 1),
          (QueueOperation.openStep, 2),
        ]),
      );
    },
  );

  test('bootstrap repairs a legacy missing next-stage open command', () async {
    final survey = await app.createSurvey('Legacy next stage');
    app.queue = [];
    await local.queueBox.clear();
    final steps = [...survey.steps];
    steps[0] = steps[0].copyWith(state: StepState.completedLocal);
    steps[1] = steps[1].copyWith(state: StepState.open);
    final legacy = survey.copyWith(steps: steps, currentStep: 1);
    app.surveys = [legacy];
    await local.saveSurvey(legacy);

    await app.recoverLocalState(recoverCamera: false);

    expect(
      app.queue.map((item) => (item.operation, item.step)),
      contains((QueueOperation.openStep, 2)),
    );
  });

  test(
    'finalization blocks pending location and allows confirmed location',
    () async {
      final survey = await app.createSurvey('Location gate');
      final evidenceFile = File('${root.path}/location-gate.jpg')
        ..writeAsStringSync('x');
      ConstructionPhoto evidence(PhotoLocationState state) => ConstructionPhoto(
        id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        surveyId: survey.id,
        localPath: evidenceFile.path,
        thumbnailPath: evidenceFile.path,
        sha256: List.filled(64, 'a').join(),
        capturedAt: DateTime.now().toUtc(),
        stepNumber: 1,
        location: state == PhotoLocationState.confirmed
            ? GeoPoint(
                latitude: 20,
                longitude: -100,
                accuracy: 5,
                capturedAt: DateTime.now().toUtc(),
              )
            : null,
        locationState: state,
        syncState: PhotoSyncState.localOnly,
      );
      app.photos = [evidence(PhotoLocationState.pending)];
      expect(app.canAttemptFinalize(survey.id, 1), isTrue);
      expect(app.canFinalize(survey.id, 1), isFalse);
      await expectLater(app.finalizeStep(survey.id, 1), throwsStateError);
      app.photos = [evidence(PhotoLocationState.confirmed)];
      expect(app.canFinalize(survey.id, 1), isTrue);
    },
  );
}
