import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../../domain/construction/construction_models.dart';
import '../persistence/local_store.dart';
import '../persistence/uuid_hive_migration.dart';
import '../security/session_store.dart';

const deviceCertificationFixtureEnabled = bool.fromEnvironment(
  'DEVICE_CERTIFICATION_FIXTURE',
);
const deviceCertificationProfileFixtureEnabled = bool.fromEnvironment(
  'DEVICE_CERTIFICATION_PROFILE_FIXTURE',
);
const deviceCertificationProfileSurveyCount = int.fromEnvironment(
  'DEVICE_CERTIFICATION_PROFILE_SURVEYS',
  defaultValue: 100,
);
const deviceCertificationProfilePhotoCount = int.fromEnvironment(
  'DEVICE_CERTIFICATION_PROFILE_PHOTOS',
  defaultValue: 400,
);

const _surveyId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _photoId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

/// Seeds only a TEST build and never overwrites an existing certification
/// snapshot. The false production constant lets tree shaking remove this path.
Future<void> seedDeviceCertificationFixture(
  LocalStore local,
  SessionStore sessions,
) async {
  if (deviceCertificationProfileFixtureEnabled) {
    await _seedProfileFixture(local, sessions);
    return;
  }
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

Future<void> _seedProfileFixture(
  LocalStore local,
  SessionStore sessions,
) async {
  if (local.metadataBox.get('deviceCertificationProfileFixture') == 'seeded') {
    return;
  }
  if (deviceCertificationProfileSurveyCount < 1 ||
      deviceCertificationProfilePhotoCount < 1) {
    throw StateError('El fixture de perfil requiere surveys y fotos.');
  }
  final now = DateTime.now().toUtc();
  final directory = Directory(
    '${(await getApplicationSupportDirectory()).path}/profile-certification',
  )..createSync(recursive: true);
  final asset = await rootBundle.load('assets/branding/logo_symbol.png');
  final bytes = asset.buffer.asUint8List(
    asset.offsetInBytes,
    asset.lengthInBytes,
  );
  final digest = sha256.convert(bytes).toString();
  final photoIds = <String>[];
  for (var index = 0; index < deviceCertificationProfilePhotoCount; index++) {
    final photoId =
        '20000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
    photoIds.add(photoId);
    final thumbnail = File('${directory.path}/$photoId.thumb.png');
    await thumbnail.writeAsBytes(bytes, flush: true);
    await local.savePhoto(
      ConstructionPhoto(
        id: photoId,
        surveyId: _surveyId,
        localPath: thumbnail.path,
        thumbnailPath: thumbnail.path,
        sha256: digest,
        capturedAt: now.add(Duration(milliseconds: index)),
        stepNumber: 6,
        purpose: index < cardinalPhotoPurposes.length
            ? cardinalPhotoPurposes[index]
            : PhotoPurpose.additional,
        location: GeoPoint(
          latitude: 29,
          longitude: -110,
          accuracy: 5,
          capturedAt: now.add(Duration(milliseconds: index)),
        ),
        syncState: PhotoSyncState.confirmed,
      ),
    );
  }
  for (var index = 0; index < deviceCertificationProfileSurveyCount; index++) {
    final surveyId = index == 0
        ? _surveyId
        : '10000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
    await local.saveSurvey(
      BaseSurvey(
        id: surveyId,
        displayIdentifier: index == 0
            ? 'PROFILE-$deviceCertificationProfilePhotoCount-THUMBNAILS'
            : 'PROFILE-${index.toString().padLeft(3, '0')}',
        contractorName: 'Certificación de recursos',
        createdAt: now.add(Duration(seconds: index)),
        updatedAt: now.add(Duration(seconds: index)),
        status: SurveyStatus.inProgress,
        localState: LocalSurveyState.active,
        syncState: SyncState.synchronized,
        currentStep: index == 0 ? 6 : 1,
        steps: List.generate(
          6,
          (stepIndex) => SurveyStep(
            number: stepIndex + 1,
            state: index == 0
                ? (stepIndex < 5 ? StepState.completedLocal : StepState.open)
                : (stepIndex == 0 ? StepState.open : StepState.locked),
            photoIds: index == 0 && stepIndex == 5 ? photoIds : const [],
          ),
        ),
      ),
    );
  }
  await sessions.save(
    const FieldSession(
      sessionId: '30000000-0000-4000-8000-000000000001',
      userId: '30000000-0000-4000-8000-000000000002',
      accessToken: 'profile-fixture-access-not-a-real-credential',
      refreshToken: 'profile-fixture-refresh-not-a-real-credential',
      installationId: '30000000-0000-4000-8000-000000000003',
      name: 'Perfilado local',
      email: 'profile-certification@example.invalid',
      phone: '0000000000',
    ),
  );
  await local.metadataBox.put('deviceCertificationProfileFixture', 'seeded');
}
