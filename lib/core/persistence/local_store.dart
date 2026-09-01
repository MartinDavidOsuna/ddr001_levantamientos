import 'dart:convert';
import 'package:hive_ce/hive.dart';
import '../../domain/construction/construction_models.dart';
import '../identity/uuid_identity.dart';
import 'construction_operation_journal.dart';
import 'uuid_hive_migration.dart';

class LocalStore {
  LocalStore(
    this.surveysBox,
    this.photosBox,
    this.queueBox,
    this.metadataBox,
    this.journalBox,
  );
  static const schemaVersion = 3;
  static const causalQueueRecoveryMarker = 'causalQueueRecoveryV2';
  final Box<String> surveysBox, photosBox, queueBox, metadataBox, journalBox;
  ConstructionOperationJournal get journal =>
      ConstructionOperationJournal(journalBox);
  static Future<LocalStore> open() async {
    final store = LocalStore(
      await Hive.openBox<String>('construction_surveys_v1'),
      await Hive.openBox<String>('construction_photos_v1'),
      await Hive.openBox<String>('construction_sync_queue_v1'),
      await Hive.openBox<String>('construction_metadata_v1'),
      await Hive.openBox<String>('construction_operation_journal_v1'),
    );
    await const UuidHiveMigration().run(
      surveysBox: store.surveysBox,
      photosBox: store.photosBox,
      queueBox: store.queueBox,
      metadataBox: store.metadataBox,
    );
    await store._repairLegacyCausalQueue();
    await store.metadataBox.put('schemaVersion', '$schemaVersion');
    return store;
  }

  Future<void> _repairLegacyCausalQueue() async {
    if (metadataBox.get(causalQueueRecoveryMarker) == 'complete') return;
    final source = queueBox.toMap(), repaired = <String, SyncQueueItem>{};
    for (final raw in source.values) {
      final decoded = SyncQueueItem.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
      final key = canonicalQueueItemId(decoded);
      final normalized = SyncQueueItem(
        id: key,
        surveyId: canonicalUuid(decoded.surveyId),
        operation: decoded.operation,
        createdAt: decoded.createdAt,
        photoId: canonicalUuidOrNull(decoded.photoId),
        step: decoded.step,
        correctionId: canonicalUuidOrNull(decoded.correctionId),
        attempts: decoded.attempts,
        // A legacy cooldown may have been caused solely by invalid global
        // ordering. The causal scheduler will assign a new cooldown only if
        // the operation fails after its prerequisites become ready.
        nextAttemptAt: null,
        requiresReview: decoded.requiresReview,
        lastErrorCode: decoded.lastErrorCode,
      );
      final current = repaired[key];
      repaired[key] = current == null
          ? normalized
          : mergeQueueItems(
              current,
              normalized,
            ).copyWith(clearNextAttempt: true);
    }
    for (final entry in repaired.entries) {
      await queueBox.put(entry.key, jsonEncode(entry.value.toJson()));
    }
    for (final key in source.keys) {
      if (!repaired.containsKey('$key')) await queueBox.delete(key);
    }
    await metadataBox.put(causalQueueRecoveryMarker, 'complete');
  }

  List<BaseSurvey> surveys() => surveysBox.values
      .map(
        (v) => BaseSurvey.fromJson(
          Map<String, dynamic>.from(jsonDecode(v) as Map),
        ),
      )
      .toList();
  List<ConstructionPhoto> photos() => photosBox.values
      .map(
        (v) => ConstructionPhoto.fromJson(
          Map<String, dynamic>.from(jsonDecode(v) as Map),
        ),
      )
      .toList();
  List<SyncQueueItem> queue() => queueBox.values
      .map(
        (v) => SyncQueueItem.fromJson(
          Map<String, dynamic>.from(jsonDecode(v) as Map),
        ),
      )
      .toList();
  ConstructionProfile? profile() {
    final value = metadataBox.get('constructionProfile');
    if (value == null) return null;
    return ConstructionProfile.fromJson(
      Map<String, dynamic>.from(jsonDecode(value) as Map),
    );
  }

  Future<void> saveProfile(ConstructionProfile value) =>
      metadataBox.put('constructionProfile', jsonEncode(value.toJson()));
  Future<void> saveSurvey(BaseSurvey value) {
    final normalized = BaseSurvey.fromJson(value.toJson());
    return surveysBox.put(normalized.id, jsonEncode(normalized.toJson()));
  }

  Future<void> savePhoto(ConstructionPhoto value) {
    final normalized = ConstructionPhoto.fromJson(value.toJson());
    return photosBox.put(normalized.id, jsonEncode(normalized.toJson()));
  }

  Future<void> deletePhoto(String id) => photosBox.delete(canonicalUuid(id));
  Future<void> saveQueue(SyncQueueItem value) {
    final normalized = SyncQueueItem.fromJson(value.toJson());
    final key = canonicalQueueItemId(normalized);
    return queueBox.put(key, jsonEncode({...normalized.toJson(), 'id': key}));
  }

  Future<void> deleteQueue(String id) => queueBox.delete(id);
}
