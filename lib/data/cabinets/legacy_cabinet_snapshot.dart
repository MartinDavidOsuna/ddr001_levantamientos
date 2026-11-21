import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'cabinet_store.dart';
import '../../domain/cabinets/cabinet_models.dart';
import '../../recovery/cabinet_backup.dart'
    show
        fileHash,
        rejectSecrets,
        writePrivateCabinetBundle,
        verifyBundle,
        inventoryRow;

class LegacyCabinetSnapshot {
  LegacyCabinetSnapshot(this.directory, this.sourceHashes, this.recordRaw);
  final Directory directory;
  final Map<String, String> sourceHashes;
  final String recordRaw;
  Future<void> verify() async {
    await verifyBundle(File('${directory.path}/backup.ddr.jsonl'));
    for (final entry in sourceHashes.entries) {
      if (!await File(entry.key).exists() ||
          await fileHash(File(entry.key)) != entry.value) {
        throw StateError(
          'Fotografía original cambió o falta. Respaldo conservado; recuperación bloqueada.',
        );
      }
    }
  }

  static Future<LegacyCabinetSnapshot> create({
    required CabinetStore store,
    required String id,
    required Directory support,
    required void Function() assertLease,
  }) async {
    assertLease();
    final raw = store.box.get('cabinet:$id');
    if (raw == null) throw StateError('Expediente local ausente.');
    rejectSecrets(utf8.encode(raw));
    final doc = CabinetRecord(object(jsonDecode(raw)));
    final destination = Directory(
      '${support.path}/cabinet_support_backups/$id/${DateTime.now().microsecondsSinceEpoch}',
    );
    if (await destination.exists()) throw StateError('Respaldo ya existe.');
    final files = <Json>[];
    final originals = <String, String>{};
    Future<void> bytes(String name, List<int> data) async {
      if (name.endsWith('.json')) rejectSecrets(data);
      final file = File('${destination.path}/raw/$name');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data, flush: true);
      final hash = sha256.convert(data).toString();
      if (await fileHash(file) != hash) throw StateError('Copia incompleta.');
      files.add({'path': name, 'size': data.length, 'sha256': hash});
    }

    final ownedIds = <String>{
      id,
      ...doc.photos.map((photo) => '${photo['id']}'),
      ...doc.operations.map((op) => '${object(op['body'])['operationId']}'),
    }..removeWhere((value) => value == 'null' || value.isEmpty);
    bool belongs(Object? value) {
      if (value is String && ownedIds.contains(value)) return true;
      if (value is Map) return value.values.any(belongs);
      if (value is List) return value.any(belongs);
      return false;
    }

    Json media() {
      final result = <String, dynamic>{};
      for (final box in [
        store.media.surveysBox,
        store.media.photosBox,
        store.media.queueBox,
        store.media.metadataBox,
        store.media.journalBox,
      ]) {
        final selected = <String, String>{};
        for (final key in box.keys) {
          final value = box.get(key)!;
          Object? parsed;
          try {
            parsed = jsonDecode(value);
          } catch (_) {
            throw StateError(
              'Journal no legible: no es seguro descartar referencias.',
            );
          }
          if (ownedIds.contains('$key') || belongs(parsed)) {
            selected['$key'] = value;
          }
        }
        result[box.name] = selected;
      }
      return result;
    }

    void verifyDescriptors(Object? value) {
      if (value is Map) {
        final photoId = value['photoId'];
        if (photoId is String && !doc.photos.any((p) => p['id'] == photoId)) {
          throw StateError(
            'Referencia fotográfica sin descriptor original; respaldo incompleto.',
          );
        }
        for (final child in value.values) {
          verifyDescriptors(child);
        }
      }
      if (value is List) {
        for (final child in value) {
          verifyDescriptors(child);
        }
      }
    }

    verifyDescriptors(doc.json);
    final selected = media();
    rejectSecrets(utf8.encode(jsonEncode(selected)));
    await bytes('documents/cabinet.json', utf8.encode(raw));
    await bytes('documents/media.json', utf8.encode(jsonEncode(selected)));
    final catalog = store.catalog(doc.working['catalogVersion'] as String?);
    if (catalog == null) throw StateError('Falta catálogo histórico.');
    await bytes(
      'documents/catalog.json',
      utf8.encode(jsonEncode(catalog.json)),
    );
    final canonicalSupport = await support.resolveSymbolicLinks();
    Future<void> preserve(String path) async {
      assertLease();
      if (originals.containsKey(path)) return;
      final file = File(path);
      if (!await file.exists() ||
          await FileSystemEntity.type(path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw StateError(
          'Falta original, carga o miniatura; no se modifica el expediente.',
        );
      }
      final resolved = await file.resolveSymbolicLinks();
      final permitted =
          p.isWithin(p.join(canonicalSupport, 'cabinets', id), resolved) ||
          p.isWithin(
            p.join(canonicalSupport, 'camera_dispatch_v1'),
            resolved,
          ) ||
          p.isWithin(p.join(p.dirname(canonicalSupport), 'cache'), resolved);
      if (!permitted) {
        throw StateError('Referencia fuera de evidencia permitida.');
      }
      final data = await file.readAsBytes();
      final hash = sha256.convert(data).toString();
      await bytes('files/${originals.length}-${p.basename(path)}', data);
      originals[path] = hash;
    }

    Future<void> references(Object? value) async {
      if (value is String) {
        try {
          await references(jsonDecode(value));
        } catch (e) {
          if (e is! FormatException) rethrow;
        }
      }
      if (value is Map) {
        for (final entry in value.entries) {
          if ([
                'localPath',
                'sourcePath',
                'uploadPath',
                'thumbnailPath',
              ].contains(entry.key) &&
              entry.value is String) {
            await preserve(entry.value as String);
          } else {
            await references(entry.value);
          }
        }
      }
      if (value is List) {
        for (final v in value) {
          await references(v);
        }
      }
    }

    await references(selected);
    await references(doc.json);
    for (final photo in doc.photos) {
      final photoId = photo['id'] as String;
      final journal = store.media.journal.find(photoId);
      final original =
          journal?.sourcePath ??
          '${support.path}/cabinets/$id/evidence/$photoId.source.jpg';
      await preserve(original);
      final upload = photo['localPath'];
      if (upload is! String ||
          originals[upload] != object(photo['metadata'])['clientSha256']) {
        throw StateError(
          'Hash declarado de fotografía no coincide; no se repara automáticamente.',
        );
      }
    }
    final directory = Directory('${support.path}/cabinets/$id');
    if (await directory.exists()) {
      await for (final f in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (f is Link) throw StateError('Enlace inesperado.');
        if (f is File) await preserve(f.path);
      }
    }
    final broker = Directory('${support.path}/camera_dispatch_v1');
    if (await broker.exists()) {
      await for (final f in broker.list(followLinks: false)) {
        if (f is File && f.path.endsWith('.json')) {
          final row = object(jsonDecode(await f.readAsString()));
          if (row['module'] == 'cabinets' && row['entityId'] == id) {
            rejectSecrets(await f.readAsBytes());
            await preserve(f.path);
            await references(row);
            final capture = Directory('${broker.path}/${row['id']}');
            if (await capture.exists()) {
              await for (final original in capture.list(
                recursive: true,
                followLinks: false,
              )) {
                if (original is Link) throw StateError('Broker enlazado.');
                if (original is File) await preserve(original.path);
              }
            }
          } else if (row['module'] == 'QUARANTINE' ||
              row['state'] == 'AMBIGUOUS') {
            throw StateError(
              'Hay capturas sin atribución: requiere revisión antes de recuperar.',
            );
          }
        }
      }
    }
    assertLease();
    if (store.box.get('cabinet:$id') != raw ||
        jsonEncode(selected) != jsonEncode(media())) {
      throw StateError('Documento/journal cambió durante el respaldo.');
    }
    final snapshot = LegacyCabinetSnapshot(destination, originals, raw);
    final manifest = <String, dynamic>{
      'format': 'ddr-cabinets-private-v1',
      'kind': 'selected-logical-snapshot-v1',
      'complete': true,
      'issues': <String>[],
      'dossiers': 1,
      'files': files,
      'sourceFiles': originals,
      'inventory': [inventoryRow(doc.json)],
    };
    await writePrivateCabinetBundle(destination, manifest);
    await snapshot.verify();
    return snapshot;
  }
}
