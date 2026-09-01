import 'dart:convert';
import 'dart:io';
import 'package:ddr001_levantamientos/core/identity/uuid_identity.dart';
import 'package:ddr001_levantamientos/core/persistence/local_store.dart';
import 'package:ddr001_levantamientos/core/persistence/uuid_hive_migration.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

const lowerSurvey = '287cd764-d7d5-4123-8108-8e2558bdb1b0';
const upperSurvey = '287CD764-D7D5-4123-8108-8E2558BDB1B0';
const lowerPhoto = '9559f69b-9584-432b-ac6e-79203e5e7bca';
const upperPhoto = '9559F69B-9584-432B-AC6E-79203E5E7BCA';

void main() {
  late Directory root;
  late Box<String> surveysBox, photosBox, queueBox, metadataBox;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('uuid-hive-migration-');
    Hive.init(root.path);
    surveysBox = await Hive.openBox<String>('construction_surveys_v1');
    photosBox = await Hive.openBox<String>('construction_photos_v1');
    queueBox = await Hive.openBox<String>('construction_sync_queue_v1');
    metadataBox = await Hive.openBox<String>('construction_metadata_v1');
  });

  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });

  test('canonical utility treats every UUID identity as case-insensitive', () {
    expect(canonicalUuid(' $upperSurvey '), lowerSurvey);
    expect(uuidEquals(lowerSurvey, upperSurvey), isTrue);
    expect(
      uuidEquals(
        'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE',
        'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
      ),
      isTrue,
      reason: 'The same rule applies to step and correction UUIDs.',
    );
  });

  test(
    'Pixel regression merges casing duplicates without evidence loss',
    () async {
      final image = File('${root.path}/photo.jpg')
        ..writeAsStringSync('fixture');
      final local = _survey(
        id: lowerSurvey,
        status: SurveyStatus.executed,
        sync: SyncState.pending,
        updatedAt: DateTime.utc(2026, 8, 27, 5, 40),
        account: '890',
        comment: 'primer levantamiento',
        photoId: lowerPhoto,
      );
      final remote = _survey(
        id: upperSurvey,
        status: SurveyStatus.delivered,
        sync: SyncState.synchronized,
        updatedAt: DateTime.utc(2026, 8, 27, 5, 50),
        serverSteps: true,
      );
      await surveysBox.put(lowerSurvey, jsonEncode(local.toJson()));
      await surveysBox.put(
        upperSurvey,
        jsonEncode({...remote.toJson(), 'id': upperSurvey}),
      );
      await photosBox.put(
        lowerPhoto,
        jsonEncode(_photo(lowerPhoto, lowerSurvey, image.path).toJson()),
      );
      await photosBox.put(
        upperPhoto,
        jsonEncode({
          ..._photo(upperPhoto, upperSurvey, image.path).toJson(),
          'id': upperPhoto,
          'surveyId': upperSurvey,
          'syncState': PhotoSyncState.confirmed.name,
        }),
      );
      final pending = SyncQueueItem(
        id: '$upperSurvey-updateComment-1',
        surveyId: upperSurvey,
        operation: QueueOperation.updateComment,
        step: 1,
        createdAt: DateTime.utc(2026, 8, 27),
      );
      await queueBox.put(pending.id, jsonEncode(pending.toJson()));

      final store = await LocalStore.open();
      final surveys = store.surveys(),
          photos = store.photos(),
          queue = store.queue();
      expect(surveys, hasLength(1));
      expect(surveys.single.id, lowerSurvey);
      expect(surveys.single.steps.first.comment, 'primer levantamiento');
      expect(surveys.single.steps.first.photoIds, [lowerPhoto]);
      expect(surveys.single.accountNumber, '890');
      expect(surveys.single.status, SurveyStatus.executed);
      expect(surveys.single.syncState, SyncState.pending);
      expect(photos, hasLength(1));
      expect(photos.single.id, lowerPhoto);
      expect(photos.single.localPath, image.path);
      expect(photos.single.syncState, PhotoSyncState.confirmed);
      expect(queue, hasLength(1));
      expect(queue.single.surveyId, lowerSurvey);
      expect(surveysBox.keys, [lowerSurvey]);
      expect(photosBox.keys, [lowerPhoto]);
      expect(metadataBox.get('schemaVersion'), '3');
      expect(metadataBox.get(LocalStore.causalQueueRecoveryMarker), 'complete');
      expect(metadataBox.get(UuidHiveMigration.marker), 'complete');
    },
  );

  test('uppercase local and lowercase server also merge to lowercase', () {
    final merged = mergeDuplicateSurveys([
      _survey(id: upperSurvey, comment: 'local'),
      _survey(
        id: lowerSurvey,
        status: SurveyStatus.accepted,
        sync: SyncState.synchronized,
        serverSteps: true,
        updatedAt: DateTime.utc(2026, 8, 28),
      ),
    ], hasPendingOperations: false);
    expect(merged.id, lowerSurvey);
    expect(merged.steps.first.comment, 'local');
    expect(merged.status, SurveyStatus.accepted);
    expect(merged.updatedAt, DateTime.utc(2026, 8, 28));
  });

  test('repeated and interrupted-style migration is idempotent', () async {
    final local = _survey(id: lowerSurvey, comment: 'preserve');
    final duplicate = _survey(id: upperSurvey, sync: SyncState.synchronized);
    await surveysBox.put(lowerSurvey, jsonEncode(local.toJson()));
    await surveysBox.put(
      upperSurvey,
      jsonEncode({...duplicate.toJson(), 'id': upperSurvey}),
    );
    const migration = UuidHiveMigration();
    await migration.run(
      surveysBox: surveysBox,
      photosBox: photosBox,
      queueBox: queueBox,
      metadataBox: metadataBox,
    );
    await metadataBox.delete(UuidHiveMigration.marker);
    await migration.run(
      surveysBox: surveysBox,
      photosBox: photosBox,
      queueBox: queueBox,
      metadataBox: metadataBox,
    );
    expect(surveysBox.keys, [lowerSurvey]);
    expect(
      BaseSurvey.fromJson(
        _json(surveysBox.get(lowerSurvey)!),
      ).steps.first.comment,
      'preserve',
    );
  });
}

Map<String, dynamic> _json(String value) =>
    Map<String, dynamic>.from(jsonDecode(value) as Map);

BaseSurvey _survey({
  required String id,
  SurveyStatus status = SurveyStatus.inProgress,
  SyncState sync = SyncState.pending,
  DateTime? updatedAt,
  String? account,
  String? comment,
  String? photoId,
  bool serverSteps = false,
}) => BaseSurvey(
  id: id,
  displayIdentifier: '9999',
  accountNumber: account,
  contractorName: serverSteps ? '' : 'Contratista1',
  createdAt: DateTime.utc(2026, 8, 27, 5, 40),
  updatedAt: updatedAt ?? DateTime.utc(2026, 8, 27, 5, 40),
  status: status,
  localState: LocalSurveyState.executedLocal,
  syncState: sync,
  currentStep: 6,
  steps: List.generate(
    6,
    (index) => SurveyStep(
      number: index + 1,
      state: serverSteps ? StepState.completedServer : StepState.completedLocal,
      comment: index == 0 ? comment : null,
      photoIds: index == 0 && photoId != null ? [photoId] : const [],
    ),
  ),
);

ConstructionPhoto _photo(String id, String surveyId, String path) =>
    ConstructionPhoto(
      id: id,
      surveyId: surveyId,
      localPath: path,
      thumbnailPath: '$path.thumb',
      sha256: List.filled(64, 'a').join(),
      capturedAt: DateTime.utc(2026, 8, 27),
      stepNumber: 1,
      location: GeoPoint(
        latitude: 21,
        longitude: -102,
        accuracy: 5,
        capturedAt: DateTime.utc(2026, 8, 27),
      ),
      syncState: PhotoSyncState.queued,
    );
