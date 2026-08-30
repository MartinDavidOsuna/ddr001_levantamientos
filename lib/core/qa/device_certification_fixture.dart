import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/construction/construction_models.dart';
import '../persistence/local_store.dart';
import '../persistence/uuid_hive_migration.dart';
import '../security/session_store.dart';

const deviceCertificationFixtureEnabled = bool.fromEnvironment(
  'DEVICE_CERTIFICATION_FIXTURE',
);

const _surveyId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _photoId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

/// Seeds only a TEST build and never overwrites an existing certification
/// snapshot. The false production constant lets tree shaking remove this path.
Future<void> seedDeviceCertificationFixture(
  LocalStore local,
  SessionStore sessions,
) async {
  if (!deviceCertificationFixtureEnabled ||
      local.metadataBox.get('deviceCertificationFixture') == 'seeded') {
    return;
  }
  final now = DateTime.now().toUtc();
  final directory = Directory(
    '${(await getApplicationSupportDirectory()).path}/device-certification',
  )..createSync(recursive: true);
  final evidence = File('${directory.path}/$_photoId.upload.jpg');
  final sink = evidence.openWrite();
  for (var block = 0; block < 64; block++) {
    sink.add(List<int>.generate(64 * 1024, (index) => index & 0xff));
  }
  await sink.close();
  final survey = BaseSurvey(
    id: _surveyId,
    displayIdentifier: 'CERT-OFFLINE-ZERO-LOSS',
    contractorName: 'Certificación local',
    createdAt: now,
    updatedAt: now,
    status: SurveyStatus.inProgress,
    localState: LocalSurveyState.active,
    syncState: SyncState.pending,
    currentStep: 1,
    steps: List.generate(
      6,
      (index) => SurveyStep(
        number: index + 1,
        state: index == 0 ? StepState.open : StepState.locked,
        photoIds: index == 0 ? const [_photoId] : const [],
      ),
    ),
  );
  final photo = ConstructionPhoto(
    id: _photoId,
    surveyId: _surveyId,
    localPath: evidence.path,
    thumbnailPath: evidence.path,
    sha256: 'fixture-sha256-is-validated-by-streaming-test'.padRight(64, '0'),
    capturedAt: now,
    stepNumber: 1,
    location: GeoPoint(
      latitude: 29,
      longitude: -110,
      accuracy: 5,
      capturedAt: now,
    ),
    syncState: PhotoSyncState.uploading,
  );
  final draft = SyncQueueItem(
    id: '',
    surveyId: _surveyId,
    operation: QueueOperation.uploadPhoto,
    photoId: _photoId,
    step: 1,
    attempts: 5,
    createdAt: now,
    nextAttemptAt: now.add(const Duration(hours: 1)),
  );
  final queue = SyncQueueItem(
    id: canonicalQueueItemId(draft),
    surveyId: draft.surveyId,
    operation: draft.operation,
    photoId: draft.photoId,
    step: draft.step,
    attempts: draft.attempts,
    createdAt: draft.createdAt,
    nextAttemptAt: draft.nextAttemptAt,
  );
  await local.saveSurvey(survey);
  await local.savePhoto(photo);
  await local.saveQueue(queue);
  await sessions.save(
    const FieldSession(
      sessionId: '10000000-0000-4000-8000-000000000001',
      userId: '10000000-0000-4000-8000-000000000002',
      accessToken: 'fixture-access-not-a-real-credential',
      refreshToken: 'fixture-refresh-not-a-real-credential',
      installationId: '10000000-0000-4000-8000-000000000003',
      name: 'Certificación local',
      email: 'certification@example.invalid',
      phone: '0000000000',
    ),
  );
  await local.metadataBox.put('deviceCertificationFixture', 'seeded');
}
