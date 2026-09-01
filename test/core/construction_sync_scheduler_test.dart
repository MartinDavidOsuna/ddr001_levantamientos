import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/core/network/api_client.dart';
import 'package:ddr001_levantamientos/core/persistence/construction_operation_journal.dart';
import 'package:ddr001_levantamientos/core/persistence/local_store.dart';
import 'package:ddr001_levantamientos/core/persistence/uuid_hive_migration.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/core/services/app_controller.dart';
import 'package:ddr001_levantamientos/core/services/construction_sync_scheduler.dart';
import 'package:ddr001_levantamientos/data/remote/construction_api.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';

const surveyA = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
const surveyB = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const photoA = 'CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC';
const correctionA = 'DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD';
final epoch = DateTime.utc(2026);

SyncQueueItem job(
  QueueOperation operation, {
  String survey = surveyA,
  int? step,
  String? photo,
  String? correction,
  int offset = 0,
  int attempts = 0,
  DateTime? nextAttemptAt,
}) {
  final draft = SyncQueueItem(
    id: '',
    surveyId: survey,
    operation: operation,
    createdAt: epoch.add(Duration(seconds: offset)),
    step: step,
    photoId: photo,
    correctionId: correction,
    attempts: attempts,
    nextAttemptAt: nextAttemptAt,
  );
  return SyncQueueItem(
    id: canonicalQueueItemId(draft),
    surveyId: survey,
    operation: operation,
    createdAt: draft.createdAt,
    step: step,
    photoId: photo,
    correctionId: correction,
    attempts: attempts,
    nextAttemptAt: nextAttemptAt,
  );
}

ConstructionPhoto evidence({
  String survey = surveyA,
  String id = photoA,
  int? step = 1,
  String? correction,
  PhotoSyncState state = PhotoSyncState.confirmed,
}) {
  final path = '/tmp/$id.jpg';
  File(path).writeAsBytesSync([1, 2, 3]);
  return ConstructionPhoto(
    id: id,
    surveyId: survey,
    localPath: path,
    thumbnailPath: path,
    sha256: sha256.convert(const [1, 2, 3]).toString(),
    capturedAt: epoch,
    stepNumber: step,
    correctionId: correction,
    location: GeoPoint(
      latitude: 20,
      longitude: -100,
      accuracy: 5,
      capturedAt: epoch,
    ),
    syncState: state,
  );
}

FieldSession fieldSession(String userId) => FieldSession(
  sessionId: 'session-$userId',
  userId: userId,
  accessToken: 'token',
  refreshToken: 'refresh',
  installationId: 'installation',
  name: userId,
  email: '$userId@example.com',
  phone: '1234567890',
);

BaseSurvey baseSurvey(String id) => BaseSurvey(
  id: id,
  displayIdentifier: id == surveyA ? 'A' : 'B',
  contractorName: 'Contractor',
  contractorUserId: 'user',
  createdAt: epoch,
  updatedAt: epoch,
  status: SurveyStatus.inProgress,
  localState: LocalSurveyState.active,
  syncState: SyncState.pending,
  currentStep: 2,
  steps: List.generate(
    6,
    (index) => SurveyStep(
      number: index + 1,
      state: index < 2 ? StepState.completedLocal : StepState.locked,
    ),
  ),
);

BaseSurvey affectedSurvey(String id) => BaseSurvey(
  id: id,
  displayIdentifier: 'Affected',
  contractorName: 'Contractor',
  contractorUserId: 'user',
  createdAt: epoch,
  updatedAt: epoch,
  status: SurveyStatus.created,
  localState: LocalSurveyState.createdLocal,
  syncState: SyncState.pending,
  currentStep: 0,
  steps: List.generate(
    6,
    (index) => SurveyStep(
      number: index + 1,
      state: index == 0 ? StepState.open : StepState.locked,
    ),
  ),
);

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

class FakeRemote implements ConstructionRemote {
  final events = <String>[];
  final steps = <String, Map<int, String>>{};
  final serverPhotos = <String, Map<String, dynamic>>{};
  final failOpen = <String>{};
  final dependencyOpen = <String>{};
  final structuralOpen = <String>{};
  final reviewActions = <String>[];
  Completer<void>? reviewGate;
  Object? reviewFailure;
  Object? authFailure;
  Object? profileFailure;
  Object? logoutFailure;
  Object? openFailure;
  Object? deleteFailure;
  Object? listFailure;
  bool requireOpenStepForUpload = false;
  String verifyStatus = 'confirmed';
  String profileCrew = '';
  ConstructionRole profileRole = ConstructionRole.contractor;
  List<Map<String, dynamic>> serverRows = [];
  Map<String, dynamic>? detailResponse;
  Object? photoContentFailure;
  final photoContentCalls = <(String, String, bool)>[];
  int listCalls = 0;
  int fieldLoginAttempts = 0;
  (String, String, String, String)? lastFieldIdentity;
  SessionKind? logoutKind;
  String? revokedTakeoverToken;

  @override
  Future<Map<String, dynamic>> detail(String surveyId) async =>
      detailResponse ??
      {
        'steps': [
          for (final entry
              in steps[surveyId.toLowerCase()]?.entries ??
                  const Iterable<MapEntry<int, String>>.empty())
            {'step_number': entry.key, 'status': entry.value},
        ],
        'photos': serverPhotos.values
            .where((photo) => photo['surveyId'] == surveyId.toLowerCase())
            .toList(),
        'corrections': const [],
      };

  @override
  Future<Uint8List> photoContent(
    String surveyId,
    String photoId, {
    required bool original,
  }) async {
    photoContentCalls.add((surveyId, photoId, original));
    if (photoContentFailure case final failure?) throw failure;
    return Uint8List.fromList(const [1, 2, 3]);
  }

  @override
  Future<void> openStep(String survey, int step) async {
    final id = survey.toLowerCase();
    events.add('$id:open:$step');
    if (dependencyOpen.contains(id)) {
      throw DioException(
        requestOptions: RequestOptions(path: '/open'),
        response: Response(
          requestOptions: RequestOptions(path: '/open'),
          statusCode: 409,
          data: {'code': 'STEP_SEQUENCE'},
        ),
        type: DioExceptionType.badResponse,
      );
    }
    if (structuralOpen.contains(id)) {
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
    if (failOpen.contains(id)) throw StateError('survey failure');
    if (openFailure case final failure?) throw failure;
    steps.putIfAbsent(id, () => {})[step] = 'open';
  }

  @override
  Future<void> completeStep(String survey, int step) async {
    final id = survey.toLowerCase();
    events.add('$id:complete:$step');
    steps.putIfAbsent(id, () => {})[step] = 'completed';
  }

  @override
  Future<void> commentStep(String survey, int step, String? comment) async {
    events.add('${survey.toLowerCase()}:comment:$step');
  }

  @override
  Future<void> upload(ConstructionPhoto photo) async {
    final survey = photo.surveyId.toLowerCase();
    if (requireOpenStepForUpload &&
        steps[survey]?[photo.stepNumber] != 'open') {
      throw DioException(
        requestOptions: RequestOptions(path: '/photos'),
        response: Response(
          requestOptions: RequestOptions(path: '/photos'),
          statusCode: 404,
          data: const {
            'code': 'NOT_FOUND',
            'detail': 'Evidence context not found.',
          },
        ),
        type: DioExceptionType.badResponse,
      );
    }
    events.add('${photo.surveyId.toLowerCase()}:upload:${photo.stepNumber}');
    serverPhotos[photo.id.toLowerCase()] = {
      'photo_id': photo.id.toLowerCase(),
      'surveyId': photo.surveyId.toLowerCase(),
      'integrity_status': 'not_verified',
    };
  }

  @override
  Future<Map<String, dynamic>> verify(List<String> ids) async {
    if (verifyStatus != 'confirmed') {
      events.add('verify:$verifyStatus');
      return {
        'items': [
          for (final id in ids) {'photoId': id, 'status': verifyStatus},
        ],
      };
    }
    for (final id in ids) {
      serverPhotos[id.toLowerCase()]?['integrity_status'] = 'confirmed';
    }
    events.add('verify');
    return {
      'items': [
        for (final id in ids) {'photoId': id, 'status': 'confirmed'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> createSurvey(BaseSurvey survey) async {
    events.add('${survey.id.toLowerCase()}:create');
    return {};
  }

  @override
  Future<void> completeCorrection(String surveyId, String correctionId) async {
    events.add('${surveyId.toLowerCase()}:correction:complete');
  }

  @override
  Future<void> correctionComment(
    String surveyId,
    String correctionId,
    String? comment,
  ) async {
    events.add('${surveyId.toLowerCase()}:correction:comment');
  }

  @override
  Future<void> deletePhoto(String surveyId, String photoId) async {
    events.add('${surveyId.toLowerCase()}:delete:${photoId.toLowerCase()}');
    if (deleteFailure case final failure?) throw failure;
  }

  @override
  Future<ConstructionProfile> profile() async {
    if (profileFailure case final failure?) throw failure;
    return ConstructionProfile(
      userId: 'user',
      displayName: 'Usuario',
      email: 'a@b.mx',
      phone: '1234567890',
      crew: profileCrew,
      role: profileRole,
    );
  }

  @override
  Future<FieldSession> fieldLogin({
    required String name,
    required String email,
    required String phone,
    required String crew,
  }) async {
    fieldLoginAttempts++;
    lastFieldIdentity = (name, email, phone, crew);
    if (authFailure case final failure?) throw failure;
    return FieldSession(
      sessionId: '00000000-0000-4000-8000-000000000001',
      userId: '00000000-0000-4000-8000-000000000002',
      accessToken: 'field-access',
      refreshToken: 'field-refresh',
      installationId: '00000000-0000-4000-8000-000000000003',
      name: name,
      email: email,
      phone: phone,
      crew: crew,
    );
  }

  @override
  Future<void> logout(FieldSession session) async {
    if (logoutFailure case final failure?) throw failure;
    logoutKind = session.kind;
  }

  @override
  Future<void> revokeExisting(String takeoverToken) async {
    revokedTakeoverToken = takeoverToken;
  }

  @override
  Future<List<Map<String, dynamic>>> list({
    bool resident = false,
    String? search,
    String? status,
  }) async {
    listCalls++;
    if (listFailure case final failure?) throw failure;
    return serverRows;
  }

  @override
  Future<void> residentAction(
    String id,
    String action, [
    Map<String, dynamic>? body,
  ]) async {
    reviewActions.add('$action:$id:${body ?? const {}}');
    if (reviewFailure case final failure?) throw failure;
    await reviewGate?.future;
  }

  @override
  Future<void> residentUpdate(String id, Map<String, dynamic> values) async {}
  @override
  Future<void> correctCanonicalLocation(
    String id,
    GeoPoint point,
    String reason,
  ) async {}
}

void main() {
  const scheduler = ConstructionSyncScheduler();

  test('causal readiness does not use enum ordinal or createdAt alone', () {
    final queue = [
      job(QueueOperation.openStep, step: 2, offset: 0),
      job(QueueOperation.completeStep, step: 1, offset: 10),
    ];
    expect(
      scheduler
          .readyRound(queue, [evidence()], DateTime.now())
          .single
          .operation,
      QueueOperation.completeStep,
    );
  });

  test('create, open, comment, upload, verify and complete form a DAG', () {
    final queue = [
      job(QueueOperation.completeStep, step: 1),
      job(QueueOperation.verifyPhotos, step: 1, photo: photoA),
      job(QueueOperation.uploadPhoto, step: 1, photo: photoA),
      job(QueueOperation.updateComment, step: 1),
      job(QueueOperation.openStep, step: 1),
      job(QueueOperation.createSurvey),
    ];
    expect(
      scheduler
          .readyRound(queue, [evidence(state: PhotoSyncState.queued)], epoch)
          .single
          .operation,
      QueueOperation.createSurvey,
    );
    final afterCreate = queue
        .where((item) => item.operation != QueueOperation.createSurvey)
        .toList();
    expect(
      scheduler.readiness(queue[2], afterCreate, [], epoch).dependency,
      'openStep:1',
    );
    expect(
      scheduler.readiness(queue[1], afterCreate, [], epoch).dependency,
      'openStep:1',
    );
    expect(scheduler.readiness(queue[0], queue, [], epoch).isReady, isFalse);
  });

  test('C02 create and open causally block initial evidence', () {
    final create = job(QueueOperation.createSurvey);
    final open = job(QueueOperation.openStep, step: 1, offset: 1);
    final upload = job(
      QueueOperation.uploadPhoto,
      step: 1,
      photo: photoA,
      offset: 2,
    );
    final queue = [create, open, upload];

    expect(scheduler.readyRound(queue, [evidence()], epoch), [create]);
    final afterCreate = [open, upload];
    expect(scheduler.readyRound(afterCreate, [evidence()], epoch), [open]);
    expect(
      scheduler.readiness(upload, afterCreate, [evidence()], epoch).dependency,
      'openStep:1',
    );
  });

  test('step 6 cardinal media and corrections use the same media barrier', () {
    final correctionComplete = job(
      QueueOperation.completeCorrection,
      correction: correctionA,
    );
    final correctionUpload = job(
      QueueOperation.uploadPhoto,
      photo: photoA,
      correction: correctionA,
    );
    expect(
      scheduler
          .readiness(
            correctionComplete,
            [correctionComplete, correctionUpload],
            [
              evidence(
                step: null,
                correction: correctionA,
                state: PhotoSyncState.queued,
              ),
            ],
            epoch,
          )
          .isReady,
      isFalse,
    );
    final stepSixComplete = job(QueueOperation.completeStep, step: 6);
    final stepSixVerify = job(
      QueueOperation.verifyPhotos,
      step: 6,
      photo: photoA,
    );
    expect(
      scheduler
          .readiness(
            stepSixComplete,
            [stepSixComplete, stepSixVerify],
            [],
            epoch,
          )
          .isReady,
      isFalse,
    );
  });

  test('steps 1 through 6 offline replay in server causal order', () {
    final queue = <SyncQueueItem>[
      for (var step = 1; step <= 6; step++) ...[
        job(QueueOperation.openStep, step: step, offset: step * 2),
        job(QueueOperation.completeStep, step: step, offset: step * 2 + 1),
      ],
    ];
    final photos = [
      for (var step = 1; step <= 6; step++)
        evidence(
          id: '00000000-0000-4000-8000-${step.toString().padLeft(12, '0')}',
          step: step,
        ),
    ];
    final sequence = <String>[];
    while (queue.isNotEmpty) {
      final ready = scheduler.readyRound(queue, photos, DateTime.now());
      expect(ready, hasLength(1));
      final item = ready.single;
      sequence.add('${item.operation.name}:${item.step}');
      queue.removeWhere((candidate) => candidate.id == item.id);
    }
    expect(sequence, [
      for (var step = 1; step <= 6; step++) ...[
        'openStep:$step',
        'completeStep:$step',
      ],
    ]);
  });

  group('controller causal replay', () {
    late Directory root;
    late LocalStore local;
    late AppController app;
    late FakeRemote remote;
    late MemorySessions sessions;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('causal-sync-');
      Hive.init(root.path);
      local = await LocalStore.open();
      sessions = MemorySessions();
      remote = FakeRemote();
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
          packageName: 'test',
          version: '1',
          buildNumber: '1',
        ),
        remote: remote,
      );
      app.session = const FieldSession(
        sessionId: 'session',
        userId: 'user',
        accessToken: 'token',
        refreshToken: 'refresh',
        installationId: 'installation',
        name: 'Contractor',
        email: 'a@b.mx',
        phone: '1234567890',
      );
    });

    tearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });

    test('Field login follows resident profile from server', () async {
      app.session = null;
      remote.profileRole = ConstructionRole.resident;
      final error = await app.login(
        name: '  María   Residente  ',
        email: ' RESIDENT@Example.COM ',
        phone: '1234567890',
        crew: ' cuadrilla   norte ',
      );
      expect(error, isNull);
      expect(app.session?.kind, SessionKind.field);
      expect(app.session?.crew, 'CUADRILLA NORTE');
      expect(app.profile?.role, ConstructionRole.resident);
      expect(app.profile?.role.isReviewer, isTrue);
      expect(remote.fieldLoginAttempts, 1);
      expect(remote.lastFieldIdentity, (
        'María Residente',
        'resident@example.com',
        '1234567890',
        'CUADRILLA NORTE',
      ));
    });

    test('profile crew becomes the persisted Field session crew', () async {
      app.session = null;
      remote.profileCrew = 'CUADRILLA DEL SERVIDOR';

      final error = await app.login(
        name: 'Usuario',
        email: 'usuario@example.com',
        phone: '1234567890',
        crew: 'cuadrilla capturada',
      );

      expect(error, isNull);
      expect(app.profile?.crew, 'CUADRILLA DEL SERVIDOR');
      expect(app.session?.crew, 'CUADRILLA DEL SERVIDOR');
      expect(sessions.value?.crew, 'CUADRILLA DEL SERVIDOR');
    });

    test('another identity conflict never offers device takeover', () async {
      app.session = null;
      remote.authFailure = DioException(
        requestOptions: RequestOptions(path: '/field-sessions/start'),
        response: Response<Map<String, dynamic>>(
          requestOptions: RequestOptions(path: '/field-sessions/start'),
          statusCode: 409,
          data: const {'code': 'IDENTITY_CONFLICT'},
        ),
        type: DioExceptionType.badResponse,
      );

      final error = await app.login(
        name: 'Usuario',
        email: 'usuario@example.com',
        phone: '1234567890',
        crew: 'CUADRILLA A',
      );

      expect(error, contains('conflicto'));
      expect(error, isNot(contains('otro dispositivo')));
      expect(app.pendingTakeoverToken, isNull);
      expect(remote.fieldLoginAttempts, 1);
    });

    test(
      'same-installation recovery requires an explicit takeover token',
      () async {
        app.session = null;
        remote.authFailure = DioException(
          requestOptions: RequestOptions(path: '/field-sessions/start'),
          response: Response<Map<String, dynamic>>(
            requestOptions: RequestOptions(path: '/field-sessions/start'),
            statusCode: 409,
            data: const {
              'code': 'SESSION_ALREADY_ACTIVE',
              'takeoverToken': 'same-installation-recovery',
            },
          ),
          type: DioExceptionType.badResponse,
        );

        final error = await app.login(
          name: 'Usuario',
          email: 'usuario@example.com',
          phone: '1234567890',
          crew: 'CUADRILLA A',
        );

        expect(error, contains('Esta instalación'));
        expect(app.pendingTakeoverToken, 'same-installation-recovery');
        expect(await app.revokeExistingSession(), isNull);
        expect(remote.revokedTakeoverToken, 'same-installation-recovery');
        expect(app.pendingTakeoverToken, isNull);
      },
    );

    test('logout dispatches using the persisted internal domain', () async {
      app.session = const FieldSession(
        sessionId: '00000000-0000-4000-8000-000000000011',
        userId: '00000000-0000-4000-8000-000000000012',
        accessToken: 'admin-access',
        refreshToken: 'admin-refresh',
        installationId: '00000000-0000-4000-8000-000000000013',
        name: '',
        email: 'admin@example.com',
        phone: '',
        kind: SessionKind.admin,
      );
      expect(await app.logout(), isNull);
      expect(remote.logoutKind, SessionKind.admin);
      expect(app.session, isNull);
    });

    test(
      'failed logout keeps the current session available for retry',
      () async {
        remote.logoutFailure = StateError('offline');
        final current = app.session;

        final error = await app.logout();

        expect(error, contains('Intenta de nuevo'));
        expect(app.session, same(current));
      },
    );

    test(
      'refresh reconciles without clearing pending survey, queue or photos',
      () async {
        final localSurvey = baseSurvey(
          surveyA,
        ).copyWith(accountNumber: '890', syncState: SyncState.requiresReview);
        final pending = job(QueueOperation.openStep, step: 3);
        final photo = evidence(state: PhotoSyncState.queued);
        app.surveys = [localSurvey];
        app.queue = [pending];
        app.photos = [photo];
        await local.saveSurvey(localSurvey);
        await local.saveQueue(pending);
        await local.savePhoto(photo);
        remote.serverRows = [
          {
            'survey_id': surveyA,
            'display_identifier': 'A remota',
            'account_number': null,
            'contractor_name': 'Servidor',
            'status': 'created',
            'current_step': 1,
          },
        ];

        await app.refreshServer();

        expect(remote.listCalls, 1);
        expect(app.surveys, hasLength(1));
        expect(app.survey(surveyA).accountNumber, '890');
        expect(app.survey(surveyA).status, SurveyStatus.inProgress);
        expect(app.survey(surveyA).currentStep, 2);
        expect(app.survey(surveyA).syncState, SyncState.requiresReview);
        expect(app.queue.single.id, pending.id);
        expect(app.photos.single.id, photo.id);
        expect(local.queue().single.id, pending.id);
        expect(local.photos().single.id, photo.id.toLowerCase());
      },
    );

    test('partial and failed refreshes never remove local surveys', () async {
      final localSurvey = baseSurvey(surveyA);
      app.surveys = [localSurvey];
      await local.saveSurvey(localSurvey);
      remote.serverRows = [
        {
          'survey_id': surveyB,
          'display_identifier': 'Sólo remota',
          'account_number': null,
          'contractor_name': 'Servidor',
          'status': 'in_progress',
          'current_step': 1,
        },
      ];

      await app.refreshServer();
      expect(
        app.surveys.map((survey) => survey.id.toLowerCase()),
        containsAll([surveyA.toLowerCase(), surveyB]),
      );

      final snapshot = app.surveys.map((survey) => survey.id).toList();
      remote.listFailure = DioException.connectionTimeout(
        requestOptions: RequestOptions(path: '/construction/base-surveys'),
        timeout: const Duration(seconds: 10),
      );
      await app.refreshServer();
      expect(app.surveys.map((survey) => survey.id), snapshot);
      expect(app.apiReachable, isFalse);

      remote.listFailure = DioException.badResponse(
        statusCode: 500,
        requestOptions: RequestOptions(path: '/construction/base-surveys'),
        response: Response<void>(
          requestOptions: RequestOptions(path: '/construction/base-surveys'),
          statusCode: 500,
        ),
      );
      await app.refreshServer();
      expect(app.surveys.map((survey) => survey.id), snapshot);
    });

    test(
      'manual retry probes server even when connectivity state is stale',
      () async {
        app.surveys = [baseSurvey(surveyA)];
        app.queue = [
          job(
            QueueOperation.openStep,
            step: 1,
            attempts: 6,
            nextAttemptAt: DateTime.now().add(const Duration(hours: 1)),
          ),
        ];
        app.online = false;

        await app.synchronize(force: true);

        expect(app.online, isTrue);
        expect(app.queue, isEmpty);
        expect(remote.events, contains('${surveyA.toLowerCase()}:open:1'));
      },
    );

    test('C03 reconciliation persists missing initial open', () async {
      final survey = affectedSurvey(surveyA);
      final photo = evidence(state: PhotoSyncState.queued);
      app.surveys = [survey];
      app.photos = [photo];
      app.queue = [job(QueueOperation.uploadPhoto, step: 1, photo: photo.id)];
      await local.saveSurvey(survey);
      await local.savePhoto(photo);
      await local.saveQueue(app.queue.single);
      remote.requireOpenStepForUpload = true;
      remote.openFailure = DioException(
        requestOptions: RequestOptions(path: '/open'),
        type: DioExceptionType.sendTimeout,
      );

      await app.synchronize();

      expect(
        app.queue.where(
          (item) => item.operation == QueueOperation.openStep && item.step == 1,
        ),
        hasLength(1),
      );
      expect(
        app.queue.where((item) => item.operation == QueueOperation.uploadPhoto),
        hasLength(1),
      );
      expect(
        local.queue().where(
          (item) => item.operation == QueueOperation.openStep && item.step == 1,
        ),
        hasLength(1),
      );
    });

    test('C04 repaired replay opens before upload and verify', () async {
      final survey = affectedSurvey(surveyA);
      final photo = evidence(state: PhotoSyncState.queued);
      app.surveys = [survey];
      app.photos = [photo];
      app.queue = [job(QueueOperation.uploadPhoto, step: 1, photo: photo.id)];
      await local.saveSurvey(survey);
      await local.savePhoto(photo);
      await local.saveQueue(app.queue.single);
      remote.requireOpenStepForUpload = true;

      await app.synchronize();

      expect(remote.events, [
        '${surveyA.toLowerCase()}:open:1',
        '${surveyA.toLowerCase()}:upload:1',
        'verify',
      ]);
      expect(app.photos.single.syncState, PhotoSyncState.confirmed);
      expect(app.queue, isEmpty);
    });

    test('C05 process restart durably reconstructs missing open', () async {
      final survey = affectedSurvey(surveyA);
      final photo = evidence(state: PhotoSyncState.queued);
      await local.saveSurvey(survey);
      await local.savePhoto(photo);
      await local.saveQueue(
        job(QueueOperation.uploadPhoto, step: 1, photo: photo.id),
      );
      await Hive.close();

      Hive.init(root.path);
      local = await LocalStore.open();
      final sessions = MemorySessions();
      final restarted = AppController(
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
          packageName: 'test',
          version: '1',
          buildNumber: '1',
        ),
        remote: remote,
      );
      restarted.session = const FieldSession(
        sessionId: 'session',
        userId: 'user',
        accessToken: 'token',
        refreshToken: 'refresh',
        installationId: 'installation',
        name: 'Contractor',
        email: 'a@b.mx',
        phone: '1234567890',
      );
      restarted.surveys = local.surveys();
      restarted.photos = local.photos();
      restarted.queue = local.queue();
      remote.openFailure = DioException(
        requestOptions: RequestOptions(path: '/open'),
        type: DioExceptionType.sendTimeout,
      );

      await restarted.recoverLocalState(recoverCamera: false);
      await restarted.synchronize();

      expect(
        local.queue().where(
          (item) => item.operation == QueueOperation.openStep && item.step == 1,
        ),
        hasLength(1),
      );
      expect(local.photos().single.id, photoA.toLowerCase());
    });

    test('C06 existing initial open is never duplicated', () async {
      final survey = affectedSurvey(surveyA);
      final photo = evidence(state: PhotoSyncState.queued);
      app.surveys = [survey];
      app.photos = [photo];
      app.queue = [
        job(QueueOperation.openStep, step: 1),
        job(QueueOperation.uploadPhoto, step: 1, photo: photo.id),
      ];
      for (final item in app.queue) {
        await local.saveQueue(item);
      }
      remote.openFailure = DioException(
        requestOptions: RequestOptions(path: '/open'),
        type: DioExceptionType.sendTimeout,
      );

      await app.synchronize();

      expect(
        app.queue.where(
          (item) => item.operation == QueueOperation.openStep && item.step == 1,
        ),
        hasLength(1),
      );
    });

    test('C07 server step suppresses unnecessary open repair', () async {
      final survey = affectedSurvey(surveyA);
      final photo = evidence(state: PhotoSyncState.queued);
      app.surveys = [survey];
      app.photos = [photo];
      app.queue = [job(QueueOperation.uploadPhoto, step: 1, photo: photo.id)];
      remote.steps[surveyA.toLowerCase()] = {1: 'open'};
      remote.requireOpenStepForUpload = true;

      await app.synchronize();

      expect(remote.events, ['${surveyA.toLowerCase()}:upload:1', 'verify']);
      expect(app.queue, isEmpty);
    });

    test('C08 locked local step is not opened automatically', () async {
      final locked = affectedSurvey(surveyA).copyWith(
        steps: List.generate(
          6,
          (index) => SurveyStep(number: index + 1, state: StepState.locked),
        ),
      );
      final photo = evidence(state: PhotoSyncState.queued);
      app.surveys = [locked];
      app.photos = [photo];
      app.queue = [job(QueueOperation.uploadPhoto, step: 1, photo: photo.id)];
      remote.requireOpenStepForUpload = true;

      await app.synchronize();

      expect(
        app.queue.where((item) => item.operation == QueueOperation.openStep),
        isEmpty,
      );
      expect(
        app.queue.where((item) => item.operation == QueueOperation.uploadPhoto),
        hasLength(1),
      );
    });

    test('C10 recovery never discards or rewrites pending evidence', () async {
      final survey = affectedSurvey(surveyA);
      final photo = evidence(state: PhotoSyncState.queued);
      final originalBytes = File(photo.localPath).readAsBytesSync();
      app.surveys = [survey];
      app.photos = [photo];
      app.queue = [job(QueueOperation.uploadPhoto, step: 1, photo: photo.id)];
      await local.saveSurvey(survey);
      await local.savePhoto(photo);
      await local.saveQueue(app.queue.single);
      remote.openFailure = DioException(
        requestOptions: RequestOptions(path: '/open'),
        type: DioExceptionType.sendTimeout,
      );

      await app.synchronize();

      expect(app.surveys.single.id.toLowerCase(), surveyA.toLowerCase());
      expect(app.surveys.single.syncState, isNot(SyncState.synchronized));
      expect(app.photos.single.id.toLowerCase(), photoA.toLowerCase());
      expect(app.photos.single.localPath, photo.localPath);
      expect(File(photo.localPath).readAsBytesSync(), originalBytes);
      expect(
        app.queue.where((item) => item.operation == QueueOperation.uploadPhoto),
        hasLength(1),
      );
    });

    test('legacy step 1 to 2 replay drains pending count', () async {
      app.surveys = [baseSurvey(surveyA)];
      app.photos = [
        evidence(),
        evidence(
          id: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
          step: 2,
          state: PhotoSyncState.queued,
        ),
      ];
      remote.steps[surveyA.toLowerCase()] = {1: 'open'};
      app.queue = [
        job(QueueOperation.openStep, step: 2),
        job(
          QueueOperation.uploadPhoto,
          step: 2,
          photo: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        ),
        job(QueueOperation.completeStep, step: 1),
        job(QueueOperation.updateComment, step: 2),
        job(QueueOperation.completeStep, step: 2),
      ];
      for (final item in app.queue) {
        await local.saveQueue(item);
      }

      await app.synchronize();

      expect(app.queue, isEmpty);
      expect(local.queue(), isEmpty);
      expect(
        remote.events.where((event) => event.startsWith(surveyA.toLowerCase())),
        [
          '${surveyA.toLowerCase()}:complete:1',
          '${surveyA.toLowerCase()}:open:2',
          '${surveyA.toLowerCase()}:comment:2',
          '${surveyA.toLowerCase()}:upload:2',
          '${surveyA.toLowerCase()}:complete:2',
        ],
      );
      expect(remote.events, contains('verify'));
    });

    test('failure in survey A does not block ready survey B', () async {
      app.surveys = [baseSurvey(surveyA), baseSurvey(surveyB)];
      app.queue = [
        job(QueueOperation.openStep, step: 1),
        job(QueueOperation.openStep, survey: surveyB, step: 1),
      ];
      remote.failOpen.add(surveyA.toLowerCase());
      await app.synchronize();
      expect(
        app.queue.any(
          (item) => item.surveyId.toLowerCase() == surveyA.toLowerCase(),
        ),
        isTrue,
      );
      expect(
        app.queue.any(
          (item) => item.surveyId.toLowerCase() == surveyB.toLowerCase(),
        ),
        isFalse,
      );
    });

    test('409 STEP_SEQUENCE stays queued and retryable', () async {
      app.surveys = [baseSurvey(surveyA)];
      app.queue = [job(QueueOperation.openStep, step: 1, attempts: 4)];
      remote.dependencyOpen.add(surveyA.toLowerCase());
      await app.synchronize();
      expect(app.queue.single.attempts, 5);
      expect(app.queue.single.nextAttemptAt, isNotNull);
    });

    test('timeout before commit preserves queue and local survey', () async {
      app.surveys = [baseSurvey(surveyA)];
      app.queue = [job(QueueOperation.openStep, step: 1)];
      remote.openFailure = DioException(
        requestOptions: RequestOptions(path: '/open'),
        type: DioExceptionType.sendTimeout,
      );

      await app.synchronize();

      expect(app.surveys, hasLength(1));
      expect(app.queue.single.attempts, 1);
      expect(app.queue.single.nextAttemptAt, isNotNull);
    });

    test('HTTP 500 backs off without blocking or deleting work', () async {
      app.surveys = [baseSurvey(surveyA)];
      app.queue = [job(QueueOperation.openStep, step: 1)];
      remote.openFailure = DioException(
        requestOptions: RequestOptions(path: '/open'),
        response: Response(
          requestOptions: RequestOptions(path: '/open'),
          statusCode: 500,
        ),
        type: DioExceptionType.badResponse,
      );

      await app.synchronize();

      expect(app.online, isTrue);
      expect(app.surveys, hasLength(1));
      expect(app.queue.single.nextAttemptAt, isNotNull);
    });

    test(
      'same-size upload mutation is quarantined without sending bytes',
      () async {
        final photo = evidence(state: PhotoSyncState.queued);
        File(photo.localPath).writeAsBytesSync(const [3, 2, 1]);
        app.surveys = [baseSurvey(surveyA)];
        app.photos = [photo];
        app.queue = [job(QueueOperation.uploadPhoto, step: 1, photo: photo.id)];

        await app.synchronize();

        expect(app.photos.single.syncState, PhotoSyncState.permanentFailure);
        expect(app.queue.single.requiresReview, isTrue);
        expect(app.queue.single.lastErrorCode, 'LOCAL_CORRUPTION');
        expect(
          remote.events,
          isNot(contains('${surveyA.toLowerCase()}:upload:1')),
        );
        expect(File(photo.localPath).readAsBytesSync(), const [3, 2, 1]);
      },
    );

    test(
      '404 on ambiguous delete completes tombstone and purges bytes',
      () async {
        final photo = evidence(state: PhotoSyncState.deleted);
        app.surveys = [baseSurvey(surveyA)];
        app.photos = [photo];
        app.queue = [job(QueueOperation.deletePhoto, step: 1, photo: photo.id)];
        await local.savePhoto(photo);
        await local.saveQueue(app.queue.single);
        await local.journal.save(
          ConstructionJournalEntry(
            id: 'delete-${photo.id.toLowerCase()}',
            operation: ConstructionJournalOperation.deletePhoto,
            state: ConstructionJournalState.queued,
            surveyId: surveyA.toLowerCase(),
            photoId: photo.id.toLowerCase(),
            step: 1,
            uploadPath: photo.localPath,
            thumbnailPath: photo.thumbnailPath,
            sha256: photo.sha256,
            fileSize: File(photo.localPath).lengthSync(),
            remotePossible: true,
            createdAt: epoch,
          ),
        );
        remote.deleteFailure = DioException(
          requestOptions: RequestOptions(path: '/photo'),
          response: Response(
            requestOptions: RequestOptions(path: '/photo'),
            statusCode: 404,
          ),
          type: DioExceptionType.badResponse,
        );

        await app.synchronize();

        expect(app.queue, isEmpty);
        expect(app.photos, isEmpty);
        expect(File(photo.localPath).existsSync(), isFalse);
        expect(
          local.journal.find('delete-${photo.id.toLowerCase()}')!.state,
          ConstructionJournalState.committed,
        );
      },
    );

    for (final status in const [
      'missing_original',
      'hash_mismatch',
      'not_found',
      'missing_thumbnail',
      'missing_mapping',
      'not_verified',
      'mapping_conflict',
      'deleted',
    ]) {
      test(
        'verify $status preserves original and follows recovery policy',
        () async {
          final photo = evidence(state: PhotoSyncState.uploadedUnverified);
          app.surveys = [baseSurvey(surveyA)];
          app.photos = [photo];
          app.queue = [
            job(QueueOperation.verifyPhotos, step: 1, photo: photoA),
          ];
          remote.verifyStatus = status;

          await app.synchronize();

          expect(File(photo.localPath).existsSync(), isTrue);
          if (status == 'mapping_conflict') {
            expect(app.photos.single.syncState, PhotoSyncState.mappingConflict);
            expect(app.queue.single.requiresReview, isTrue);
          } else if (status == 'deleted') {
            expect(
              app.photos.single.syncState,
              PhotoSyncState.permanentFailure,
            );
            expect(app.queue, isEmpty);
          } else {
            expect(app.queue, isNotEmpty);
            expect(app.queue.any((item) => item.nextAttemptAt != null), isTrue);
            if (const {
              'missing_original',
              'hash_mismatch',
              'not_found',
            }.contains(status)) {
              expect(
                remote.events,
                contains('${surveyA.toLowerCase()}:upload:1'),
              );
            } else {
              expect(
                remote.events,
                isNot(contains('${surveyA.toLowerCase()}:upload:1')),
              );
            }
          }
        },
      );
    }

    test('structural 409 requires review without a retry loop', () async {
      app.surveys = [baseSurvey(surveyA), baseSurvey(surveyB)];
      app.queue = [
        job(QueueOperation.openStep, step: 1),
        job(QueueOperation.openStep, survey: surveyB, step: 1),
      ];
      remote.structuralOpen.add(surveyA.toLowerCase());

      await app.synchronize();

      final blocked = app.queue.single;
      expect(blocked.requiresReview, isTrue);
      expect(blocked.lastErrorCode, 'STRUCTURAL_CONFLICT');
      expect(app.survey(surveyA).syncState, SyncState.requiresReview);
      expect(
        app.queue.any((item) => item.surveyId.toLowerCase() == surveyB),
        isFalse,
      );
    });

    test(
      'reconciliation removes an operation already satisfied by server',
      () async {
        app.surveys = [baseSurvey(surveyA)];
        app.queue = [job(QueueOperation.openStep, step: 1)];
        await local.saveQueue(app.queue.single);
        remote.steps[surveyA.toLowerCase()] = {1: 'open'};
        await app.synchronize();
        expect(app.queue, isEmpty);
        expect(remote.events, isEmpty);
      },
    );

    test(
      'reconciliation creates missing verify after ambiguous upload',
      () async {
        app.surveys = [baseSurvey(surveyA)];
        app.photos = [evidence(state: PhotoSyncState.uploading)];
        app.queue = [job(QueueOperation.uploadPhoto, step: 1, photo: photoA)];
        await local.savePhoto(app.photos.single);
        await local.saveQueue(app.queue.single);
        remote.serverPhotos[photoA.toLowerCase()] = {
          'photo_id': photoA.toLowerCase(),
          'surveyId': surveyA.toLowerCase(),
          'integrity_status': 'not_verified',
        };

        await app.synchronize();

        expect(
          remote.events,
          isNot(contains('${surveyA.toLowerCase()}:upload:1')),
        );
        expect(remote.events, contains('verify'));
        expect(app.photos.single.syncState, PhotoSyncState.confirmed);
        expect(app.queue, isEmpty);
      },
    );

    test(
      'review accept fires once and immediately merges accepted state',
      () async {
        app.profile = const ConstructionProfile(
          userId: 'user',
          displayName: 'Reviewer',
          email: 'reviewer@example.com',
          phone: '',
          role: ConstructionRole.resident,
        );
        app.surveys = [
          baseSurvey(surveyA).copyWith(status: SurveyStatus.executed),
        ];
        remote.reviewGate = Completer<void>();

        final first = app.acceptSurvey(surveyA);
        final duplicate = app.acceptSurvey(surveyA);
        expect(app.reviewSubmitting(surveyA), isTrue);
        expect(remote.reviewActions, hasLength(1));
        remote.reviewGate!.complete();
        await Future.wait([first, duplicate]);

        expect(app.survey(surveyA).status, SurveyStatus.accepted);
        expect(app.reviewSubmitting(surveyA), isFalse);
      },
    );

    test(
      'review reject trims reason, merges state and surfaces request error',
      () async {
        app.profile = const ConstructionProfile(
          userId: 'user',
          displayName: 'Reviewer',
          email: 'reviewer@example.com',
          phone: '',
          role: ConstructionRole.admin,
        );
        app.surveys = [
          baseSurvey(surveyA).copyWith(status: SurveyStatus.executed),
        ];

        await app.rejectSurvey(surveyA, '  Corregir evidencia  ');
        expect(app.survey(surveyA).status, SurveyStatus.rejected);
        expect(app.survey(surveyA).rejectionReason, 'Corregir evidencia');
        expect(remote.reviewActions.single, contains('Corregir evidencia'));

        app.surveys = [
          baseSurvey(surveyA).copyWith(status: SurveyStatus.executed),
        ];
        remote.reviewFailure = DioException(
          requestOptions: RequestOptions(path: '/reject'),
          response: Response(
            requestOptions: RequestOptions(path: '/reject'),
            statusCode: 409,
            data: {'detail': 'La transición no es válida.'},
          ),
        );
        await expectLater(
          app.rejectSurvey(surveyA, 'Motivo válido'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'La transición no es válida.',
            ),
          ),
        );
        expect(app.survey(surveyA).status, SurveyStatus.executed);
        expect(app.reviewSubmitting(surveyA), isFalse);
        expect(() => app.rejectSurvey(surveyA, '   '), throwsStateError);
      },
    );

    test('role and user switches isolate the persistent survey workspace', () {
      final ownedByA = baseSurvey(surveyA).copyWith(contractorUserId: 'user-a');
      final ownedByB = baseSurvey(surveyB).copyWith(contractorUserId: 'user-b');
      app.surveys = [ownedByA, ownedByB];

      app.profile = const ConstructionProfile(
        userId: 'reviewer',
        displayName: 'Admin',
        email: 'admin@example.com',
        phone: '',
        role: ConstructionRole.admin,
      );
      app.session = fieldSession('reviewer');
      expect(app.visibleSurveys, hasLength(2));

      app.profile = const ConstructionProfile(
        userId: 'user-a',
        displayName: 'A',
        email: 'a@example.com',
        phone: '',
        role: ConstructionRole.contractor,
      );
      app.session = fieldSession('user-a');
      expect(app.visibleSurveys.map((item) => item.id), [surveyA]);
      expect(() => app.survey(surveyB), throwsStateError);

      app.profile = const ConstructionProfile(
        userId: 'user-b',
        displayName: 'B',
        email: 'b@example.com',
        phone: '',
        role: ConstructionRole.contractor,
      );
      app.session = fieldSession('user-b');
      expect(app.visibleSurveys.map((item) => item.id), [surveyB]);

      app.profile = const ConstructionProfile(
        userId: 'resident',
        displayName: 'Resident',
        email: 'resident@example.com',
        phone: '',
        role: ConstructionRole.resident,
      );
      app.session = fieldSession('resident');
      expect(app.visibleSurveys, hasLength(2));
      expect(app.surveys, hasLength(2), reason: 'storage is never erased');
    });

    test(
      'legacy unknown remains hidden and cannot create a false duplicate',
      () {
        final json = baseSurvey(surveyA).toJson()..remove('contractorUserId');
        app.surveys = [BaseSurvey.fromJson(json)];
        app.profile = const ConstructionProfile(
          userId: 'user-b',
          displayName: 'B',
          email: 'b@example.com',
          phone: '',
          role: ConstructionRole.contractor,
        );
        app.session = fieldSession('user-b');

        expect(app.visibleSurveys, isEmpty);
        expect(app.duplicateKnown('A'), isFalse);
        expect(() => app.survey(surveyA), throwsStateError);
      },
    );

    test(
      'foreign queue stays byte-for-byte unchanged under another user',
      () async {
        final foreign = job(
          QueueOperation.openStep,
          step: 1,
          attempts: 4,
          nextAttemptAt: DateTime.utc(2030),
        );
        app.surveys = [
          baseSurvey(surveyA).copyWith(contractorUserId: 'user-a'),
        ];
        app.queue = [foreign];
        await local.saveSurvey(app.surveys.single);
        await local.saveQueue(foreign);
        final persistedBefore = local.queue().single.toJson();
        app.profile = const ConstructionProfile(
          userId: 'user-b',
          displayName: 'B',
          email: 'b@example.com',
          phone: '',
          role: ConstructionRole.contractor,
        );
        app.session = fieldSession('user-b');

        await app.synchronize(force: true);

        expect(remote.events, isEmpty);
        expect(app.queue.single.toJson(), foreign.toJson());
        expect(local.queue().single.toJson(), persistedBefore);
      },
    );

    test(
      'contractor refresh proves own rows without exposing cached foreign rows',
      () async {
        app.surveys = [
          baseSurvey(surveyB).copyWith(contractorUserId: 'user-b'),
        ];
        app.profile = const ConstructionProfile(
          userId: 'user-a',
          displayName: 'A',
          email: 'a@example.com',
          phone: '',
          role: ConstructionRole.contractor,
        );
        app.session = fieldSession('user-a');
        remote.serverRows = [
          {
            'survey_id': surveyA,
            'display_identifier': 'A',
            'contractor_name': 'A',
            'status': 'in_progress',
            'current_step': 1,
          },
        ];

        await app.refreshServer();

        expect(app.visibleSurveys.map((item) => item.id), [
          surveyA.toLowerCase(),
        ]);
        expect(app.surveys, hasLength(2));
        expect(app.survey(surveyA).contractorUserId, 'user-a');
      },
    );

    test(
      'remote detail persists counts, corrections and deduplicates local UUIDs',
      () async {
        final synced = baseSurvey(
          surveyA,
        ).copyWith(contractorUserId: 'user', syncState: SyncState.synchronized);
        final localPhoto = evidence(state: PhotoSyncState.confirmed);
        app.surveys = [synced];
        app.photos = [localPhoto];
        remote.detailResponse = {
          'survey_id': surveyA,
          'contractor_user_id': 'user',
          'contractor_name': 'Contractor',
          'status': 'in_progress',
          'current_step': 2,
          'steps': [
            {'step_number': 1, 'status': 'completed', 'comment': 'Servidor'},
          ],
          'photos': [
            {
              'photo_id': photoA,
              'photo_context': 'step',
              'step_number': 1,
              'captured_at': epoch.toIso8601String(),
              'upload_status': 'verified',
              'integrity_status': 'confirmed',
            },
            for (var index = 1; index <= 5; index++)
              {
                'photo_id':
                    '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}',
                'photo_context': index == 5 ? 'correction' : 'step',
                'step_number': index == 5 ? null : 1,
                'correction_round': index == 5 ? 1 : null,
                'photo_purpose': index == 1 ? 'north' : null,
                'captured_at': epoch.toIso8601String(),
                'upload_status': 'verified',
                'integrity_status': 'confirmed',
              },
          ],
          'corrections': [
            {
              'correction_id': correctionA,
              'round_number': 1,
              'status': 'completed',
              'comment': 'Corregida',
            },
          ],
        };

        await app.loadSurveyDetail(surveyA);

        expect(app.survey(surveyA).remotePhotos, hasLength(6));
        expect(app.photoCountForStep(surveyA, 1), 5);
        expect(app.survey(surveyA).steps.first.comment, 'Servidor');
        expect(app.survey(surveyA).corrections.single.photoIds, hasLength(1));
        expect(
          app.photoCountForCorrection(
            surveyA,
            app.survey(surveyA).corrections.single,
          ),
          1,
        );
        expect(local.surveys().single.remotePhotos, hasLength(6));
        expect(app.queue, isEmpty);
        expect(local.journal.pending(), isEmpty);
      },
    );

    test(
      'remote bytes use thumb/original, cache, and failures preserve metadata',
      () async {
        final photo = RemoteConstructionPhoto(
          id: photoA,
          surveyId: surveyA,
          context: 'step',
          stepNumber: 1,
          capturedAt: epoch,
          uploadStatus: 'verified',
          integrityStatus: 'confirmed',
        );
        app.surveys = [
          baseSurvey(surveyA).copyWith(
            contractorUserId: 'user',
            remotePhotos: [photo],
            syncState: SyncState.synchronized,
          ),
        ];

        await app.remotePhotoBytes(photo, original: false);
        await app.remotePhotoBytes(photo, original: false);
        await app.remotePhotoBytes(photo, original: true);
        expect(remote.photoContentCalls.map((call) => call.$3), [false, true]);

        for (final failure in <Object>[
          DioException.badResponse(
            statusCode: 404,
            requestOptions: RequestOptions(path: '/content'),
            response: Response<void>(
              requestOptions: RequestOptions(path: '/content'),
              statusCode: 404,
            ),
          ),
          DioException.badResponse(
            statusCode: 503,
            requestOptions: RequestOptions(path: '/content'),
            response: Response<void>(
              requestOptions: RequestOptions(path: '/content'),
              statusCode: 503,
            ),
          ),
          DioException.connectionTimeout(
            requestOptions: RequestOptions(path: '/content'),
            timeout: const Duration(seconds: 5),
          ),
        ]) {
          remote.photoContentFailure = failure;
          final unavailable = RemoteConstructionPhoto(
            id: '00000000-0000-4000-8000-${remote.photoContentCalls.length.toString().padLeft(12, '0')}',
            surveyId: surveyA,
            context: 'step',
            stepNumber: 1,
            capturedAt: epoch,
            uploadStatus: 'verified',
            integrityStatus: 'confirmed',
          );
          await expectLater(
            app.remotePhotoBytes(unavailable, original: false),
            throwsA(same(failure)),
          );
          expect(app.survey(surveyA).remotePhotos, [photo]);
          expect(app.queue, isEmpty);
          expect(local.journal.pending(), isEmpty);
        }
      },
    );
  });

  test(
    'legacy restart canonicalizes, deduplicates and clears stale cooldown',
    () async {
      final root = await Directory.systemTemp.createTemp('causal-restart-');
      Hive.init(root.path);
      var local = await LocalStore.open();
      await local.metadataBox.delete(LocalStore.causalQueueRecoveryMarker);
      final upper = job(
        QueueOperation.openStep,
        survey: surveyA,
        step: 2,
        attempts: 8,
        nextAttemptAt: DateTime.utc(2030),
      );
      final lower = job(
        QueueOperation.openStep,
        survey: surveyA.toLowerCase(),
        step: 2,
      );
      await local.queueBox.put('legacy-upper', _encode(upper));
      await local.queueBox.put('legacy-lower', _encode(lower));
      await Hive.close();

      Hive.init(root.path);
      local = await LocalStore.open();
      expect(local.queue(), hasLength(1));
      expect(local.queue().single.surveyId, surveyA.toLowerCase());
      expect(local.queue().single.attempts, 8);
      expect(local.queue().single.nextAttemptAt, isNull);
      await Hive.close();
      await root.delete(recursive: true);
    },
  );
}

String _encode(SyncQueueItem item) => jsonEncode(item.toJson());
