import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/features/surveys/surveys_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('status mapper exposes every persistent status in Spanish', () {
    expect(SurveyStatus.values.map(surveyStatusLabel), [
      'Creado',
      'En proceso',
      'Ejecutado',
      'Rechazado',
      'Entregable',
      'Entregado',
    ]);
  });

  test(
    'reviewer capabilities are identical for resident admin and superadmin',
    () {
      for (final role in const [
        ConstructionRole.resident,
        ConstructionRole.admin,
        ConstructionRole.superadmin,
      ]) {
        expect(role.isReviewer, isTrue);
        expect(role.canViewAllSurveys, isTrue);
        expect(role.canAccept, isTrue);
        expect(role.canReject, isTrue);
        expect(role.canEditIdentity, isTrue);
        expect(role.canDeliver, isTrue);
        expect(role.canCorrectCanonicalLocation, isTrue);
        expect(role.canMutateEvidence, isFalse);
        expect(role.surveyListTitle, 'Levantamientos');
      }
      expect(ConstructionRole.contractor.isReviewer, isFalse);
      expect(ConstructionRole.contractor.canMutateEvidence, isTrue);
      expect(ConstructionRole.contractor.surveyListTitle, 'Mis levantamientos');
    },
  );
  test('duplicate normalization trims collapses and ignores case', () {
    expect(normalizeIdentifier('  Base   norte '), 'BASE NORTE');
  });
  test('steps 1-5 require one and cap four photos', () {
    for (var i = 1; i <= 5; i++) {
      final step = SurveyStep(number: i, state: StepState.open);
      expect(step.minimumPhotos, 1);
      expect(step.maximumPhotos, 4);
    }
  });
  test('step 6 requires four and has no maximum', () {
    const step = SurveyStep(number: 6, state: StepState.open);
    expect(step.minimumPhotos, 4);
    expect(step.maximumPhotos, isNull);
  });
  test('single En proceso filter includes created and in progress', () {
    expect(surveyMatchesFilter(_survey(), SurveyListFilter.inProgress), isTrue);
    expect(
      surveyMatchesFilter(
        _survey(status: SurveyStatus.inProgress),
        SurveyListFilter.inProgress,
      ),
      isTrue,
    );
    expect(
      SurveyListFilter.values
          .map(surveyFilterLabel)
          .where((label) => label == 'En proceso'),
      hasLength(1),
    );
  });
  test('location pending distinguishes missing and poor GPS', () {
    final photo = ConstructionPhoto(
      id: 'p',
      surveyId: 's',
      localPath: 'x',
      thumbnailPath: 't',
      sha256: List.filled(64, '0').join(),
      capturedAt: DateTime.utc(2026),
      stepNumber: 1,
      syncState: PhotoSyncState.localOnly,
    );
    expect(photo.locationPending, isTrue);
    expect(
      photo
          .copyWith(
            location: GeoPoint(
              latitude: 29,
              longitude: -110,
              accuracy: 10,
              capturedAt: DateTime.utc(2026),
            ),
          )
          .locationPending,
      isFalse,
    );
  });
  test('step 6 cardinal purpose survives local serialization', () {
    final photo = ConstructionPhoto(
      id: 'north',
      surveyId: 's',
      localPath: 'x',
      thumbnailPath: 't',
      sha256: List.filled(64, '0').join(),
      capturedAt: DateTime.utc(2026),
      stepNumber: 6,
      purpose: PhotoPurpose.north,
      syncState: PhotoSyncState.localOnly,
    );
    expect(
      ConstructionPhoto.fromJson(photo.toJson()).purpose,
      PhotoPurpose.north,
    );
  });
  test('completed state round-trips immutable marker', () {
    const step = SurveyStep(
      number: 1,
      state: StepState.completedLocal,
      photoIds: ['p'],
    );
    expect(SurveyStep.fromJson(step.toJson()).state, StepState.completedLocal);
  });
  test('canonical location is an explicit persisted value', () {
    final point = GeoPoint(
      latitude: 29,
      longitude: -110,
      accuracy: 4,
      capturedAt: DateTime.utc(2026),
    );
    final survey = _survey(canonical: point);
    expect(
      BaseSurvey.fromJson(survey.toJson()).canonicalLocation?.latitude,
      29,
    );
  });
  test(
    'queue retry applies exponential backoff and survives serialization',
    () {
      final now = DateTime.utc(2026),
          item = SyncQueueItem(
            id: 'q',
            surveyId: 's',
            operation: QueueOperation.uploadPhoto,
            createdAt: now,
          ).retry(now).retry(now);
      expect(item.attempts, 2);
      expect(item.nextAttemptAt!.isAfter(now), isTrue);
      expect(SyncQueueItem.fromJson(item.toJson()).attempts, 2);
    },
  );
  test('hardened verify states do not collapse into a synced boolean', () {
    expect(
      PhotoSyncState.values,
      containsAll([
        PhotoSyncState.uploadedUnverified,
        PhotoSyncState.verifying,
        PhotoSyncState.confirmed,
        PhotoSyncState.mappingConflict,
        PhotoSyncState.missingLocal,
      ]),
    );
  });
  test('correction rounds persist independently from original steps', () {
    final survey = _survey(
      corrections: const [
        CorrectionRound(id: 'c', round: 2, state: StepState.open),
      ],
    );
    expect(BaseSurvey.fromJson(survey.toJson()).corrections.single.round, 2);
  });
  test('construction profile reads crew and tolerates a legacy omission', () {
    final profile = ConstructionProfile.fromJson({
      'userId': '00000000-0000-4000-8000-000000000001',
      'displayName': 'Usuario',
      'email': 'usuario@example.com',
      'phone': '1234567890',
      'crew': 'CUADRILLA NORTE',
      'constructionRole': 'contractor',
    });
    expect(profile.crew, 'CUADRILLA NORTE');
    expect(
      ConstructionProfile.fromJson({
        'userId': '00000000-0000-4000-8000-000000000001',
        'constructionRole': 'contractor',
      }).crew,
      isEmpty,
    );
  });
  test('survey owner UUID is canonical and legacy omission stays unknown', () {
    final owned = _survey(contractorUserId: 'USER-A');
    expect(BaseSurvey.fromJson(owned.toJson()).contractorUserId, 'user-a');
    final legacy = owned.toJson()..remove('contractorUserId');
    expect(BaseSurvey.fromJson(legacy).contractorUserId, isNull);
  });

  test('remote evidence metadata round-trips without local capture fields', () {
    final photo = RemoteConstructionPhoto.fromWire('SURVEY', {
      'photo_id': 'PHOTO',
      'photo_context': 'correction',
      'correction_round': 2,
      'photo_purpose': 'west',
      'captured_at': DateTime.utc(2026).toIso8601String(),
      'upload_status': 'verified',
      'integrity_status': 'confirmed',
    });
    final restored = RemoteConstructionPhoto.fromJson(photo.toJson());
    expect(restored.id, 'photo');
    expect(restored.surveyId, 'survey');
    expect(restored.correctionRound, 2);
    expect(restored.purpose, PhotoPurpose.west);
  });
}

BaseSurvey _survey({
  GeoPoint? canonical,
  List<CorrectionRound> corrections = const [],
  SurveyStatus status = SurveyStatus.created,
  String? contractorUserId,
}) => BaseSurvey(
  id: 's',
  displayIdentifier: 'Losa 1',
  contractorName: 'A',
  contractorUserId: contractorUserId,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  status: status,
  localState: LocalSurveyState.createdLocal,
  syncState: SyncState.pending,
  currentStep: 0,
  steps: List.generate(
    6,
    (i) => SurveyStep(
      number: i + 1,
      state: i == 0 ? StepState.open : StepState.locked,
    ),
  ),
  canonicalLocation: canonical,
  corrections: corrections,
);
