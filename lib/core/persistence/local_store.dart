import 'dart:convert';
import 'package:hive_ce/hive.dart';
import '../../domain/construction/construction_models.dart';

class LocalStore {
  LocalStore(this.surveysBox, this.photosBox, this.queueBox, this.metadataBox);
  static const schemaVersion = 1;
  final Box<String> surveysBox, photosBox, queueBox, metadataBox;
  static Future<LocalStore> open() async {
    final store = LocalStore(
      await Hive.openBox<String>('construction_surveys_v1'),
      await Hive.openBox<String>('construction_photos_v1'),
      await Hive.openBox<String>('construction_sync_queue_v1'),
      await Hive.openBox<String>('construction_metadata_v1'),
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
  Future<void> saveSurvey(BaseSurvey value) =>
      surveysBox.put(value.id, jsonEncode(value.toJson()));
  Future<void> savePhoto(ConstructionPhoto value) =>
      photosBox.put(value.id, jsonEncode(value.toJson()));
  Future<void> deletePhoto(String id) => photosBox.delete(id);
  Future<void> saveQueue(SyncQueueItem value) =>
      queueBox.put(value.id, jsonEncode(value.toJson()));
  Future<void> deleteQueue(String id) => queueBox.delete(id);
}
