import 'dart:convert';
import 'package:hive_ce/hive.dart';
import '../../domain/construction/construction_models.dart';
import '../identity/uuid_identity.dart';
import 'uuid_hive_migration.dart';

class LocalStore {
  LocalStore(this.surveysBox, this.photosBox, this.queueBox, this.metadataBox);
  static const schemaVersion = 2;
  final Box<String> surveysBox, photosBox, queueBox, metadataBox;
  static Future<LocalStore> open() async {
    final store = LocalStore(
      await Hive.openBox<String>('construction_surveys_v1'),
      await Hive.openBox<String>('construction_photos_v1'),
      await Hive.openBox<String>('construction_sync_queue_v1'),
      await Hive.openBox<String>('construction_metadata_v1'),
    );
    await const UuidHiveMigration().run(
      surveysBox: store.surveysBox,
      photosBox: store.photosBox,
      queueBox: store.queueBox,
      metadataBox: store.metadataBox,
    );
    await store.metadataBox.put('schemaVersion', '$schemaVersion');
    return store;
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
