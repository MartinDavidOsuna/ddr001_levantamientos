import 'dart:io';
import 'dart:convert';

import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/core/network/api_client.dart';
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
}) => ConstructionPhoto(
  id: id,
  surveyId: survey,
  localPath: '/tmp/$id.jpg',
  thumbnailPath: '/tmp/${id}_thumb.jpg',
  sha256: List.filled(64, 'a').join(),
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

BaseSurvey baseSurvey(String id) => BaseSurvey(
  id: id,
  displayIdentifier: id == surveyA ? 'A' : 'B',
  contractorName: 'Contractor',
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

  @override
  Future<Map<String, dynamic>> detail(String surveyId) async => {
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
    if (failOpen.contains(id)) throw StateError('survey failure');
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
    events.add('${photo.surveyId.toLowerCase()}:upload:${photo.stepNumber}');
    serverPhotos[photo.id.toLowerCase()] = {
      'photo_id': photo.id.toLowerCase(),
      'surveyId': photo.surveyId.toLowerCase(),
      'integrity_status': 'not_verified',
    };
  }

  @override
  Future<Map<String, dynamic>> verify(List<String> ids) async {
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
  Future<void> deletePhoto(String surveyId, String photoId) async {}
  @override
  Future<ConstructionProfile> profile() async => const ConstructionProfile(
    userId: 'user',
    displayName: 'Contractor',
    email: 'a@b.mx',
    phone: '1234567890',
    crew: 'C1',
    role: ConstructionRole.contractor,
  );
  @override
  Future<FieldSession> login({
    required String name,
    required String email,
    required String phone,
    required String crew,
  }) => throw UnimplementedError();
  @override
  Future<void> logout(FieldSession session) async {}
  @override
  Future<void> revokeExisting(String takeoverToken) async {}
  @override
  Future<List<Map<String, dynamic>>> list({
    bool resident = false,
    String? search,
    String? status,
  }) async => [];
  @override
  Future<void> residentAction(
    String id,
    String action, [
    Map<String, dynamic>? body,
  ]) async {}
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

    setUp(() async {
      root = await Directory.systemTemp.createTemp('causal-sync-');
      Hive.init(root.path);
      local = await LocalStore.open();
      final sessions = MemorySessions();
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
        crew: 'C1',
      );
    });

    tearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });

    test(
      'manual retry probes server even when connectivity state is stale',
      () async {
        app.surveys = [baseSurvey(surveyA)];
        app.queue = [job(QueueOperation.openStep, step: 1)];
        app.online = false;

        await app.synchronize(force: true);

        expect(app.online, isTrue);
        expect(app.queue, isEmpty);
        expect(remote.events, contains('${surveyA.toLowerCase()}:open:1'));
      },
    );

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
