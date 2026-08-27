import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}

BaseSurvey _survey({
  GeoPoint? canonical,
  List<CorrectionRound> corrections = const [],
}) => BaseSurvey(
  id: 's',
  displayIdentifier: 'Losa 1',
  contractorName: 'A',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  status: SurveyStatus.created,
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
