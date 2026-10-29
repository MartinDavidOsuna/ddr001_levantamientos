import 'dart:convert';
import 'package:hive_ce/hive.dart';
import '../../domain/cabinets/cabinet_models.dart';
import '../../core/persistence/local_store.dart';

/// One atomic Hive value per dossier contains draft, photos and durable operation journal.
/// Additive namespace; never migrates or clears the bases boxes.
class CabinetStore {
  CabinetStore(this.box, this.media);
  final Box<String> box;
  final LocalStore media;
  static Future<CabinetStore> open() async {
    final store = CabinetStore(
      await Hive.openBox<String>('cabinets_documents_v1'),
      LocalStore(
        await Hive.openBox<String>('cabinets_media_documents_v1'),
        await Hive.openBox<String>('cabinets_media_photos_v1'),
        await Hive.openBox<String>('cabinets_media_queue_v1'),
        await Hive.openBox<String>('cabinets_media_metadata_v1'),
        await Hive.openBox<String>('cabinets_media_journal_v1'),
      ),
    );
    final version = store.box.get('schemaVersion');
    if (version != null && version != '1') {
      throw StateError(
        'Versión local de gabinetes no compatible. Datos conservados.',
      );
    }
    await store.box.put('schemaVersion', '1');
    return store;
  }

  List<CabinetRecord> all() => box.keys
      .where((k) => '$k'.startsWith('cabinet:'))
      .map((k) => CabinetRecord(object(jsonDecode(box.get(k)!))))
      .toList();
  CabinetRecord? read(String id) {
    final raw = box.get('cabinet:${id.toLowerCase()}');
    return raw == null ? null : CabinetRecord(object(jsonDecode(raw)));
  }

  Future<void> save(Json value) async {
    await box.put(
      'cabinet:${value['id'].toString().toLowerCase()}',
      jsonEncode(value),
    );
    await box.flush();
  }

  CabinetCatalog? catalog([String? version]) {
    final raw = box.get('catalog:${version ?? box.get('currentCatalog')}');
    return raw == null ? null : CabinetCatalog(object(jsonDecode(raw)));
  }

  Future<void> saveCatalog(
    CabinetCatalog catalog, {
    bool current = true,
  }) async {
    await box.put('catalog:${catalog.version}', jsonEncode(catalog.json));
    if (current) await box.put('currentCatalog', catalog.version);
  }

  bool authorized(String user) => box.get('authorized:$user') == 'true';
  Future<void> authorize(String user, bool allowed) =>
      box.put('authorized:$user', '$allowed');
}
