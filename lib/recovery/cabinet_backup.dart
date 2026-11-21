import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;
import '../domain/cabinets/cabinet_models.dart' show CabinetRecord;

const cabinetBoxes = [
  'cabinets_documents_v1',
  'cabinets_media_documents_v1',
  'cabinets_media_photos_v1',
  'cabinets_media_queue_v1',
  'cabinets_media_metadata_v1',
  'cabinets_media_journal_v1',
];
final _secret = RegExp(
  r'access[_-]?token|refresh[_-]?token|password|authorization|construction_field_session|Bearer\s|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.',
  caseSensitive: false,
);
void rejectSecrets(List<int> bytes) {
  if (_secret.hasMatch(latin1.decode(bytes))) {
    throw StateError(
      'Contenido potencialmente secreto: exportación bloqueada.',
    );
  }
}

Future<String> fileHash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
Map<String, dynamic> map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Map<String, dynamic>> maps(Object? value) =>
    value is List ? value.map(map).toList() : [];
String payloadHash(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

class CabinetBackup {
  CabinetBackup({
    required this.root,
    required this.destination,
    required this.assertExclusive,
    this.afterCopy,
  });
  final Directory root, destination;
  // Android supplies a dedicated, plugin-free process with no other app processes.
  // Tests inject a gate. A stable hash alone is NOT exclusion of writers.
  final Future<void> Function() assertExclusive;
  final Future<void> Function()? afterCopy;
  final _files = <String, Map<String, dynamic>>{};
  final _issues = <String>{};
  final _documents = <Map<String, dynamic>>[];
  final _values = <Object?>[];
  final _expectedPhotoIds = <String>{};
  bool _used = false;

  Future<void> _copy(String relative) async {
    if (_files.containsKey(relative)) return;
    if (p.isAbsolute(relative) || p.split(relative).contains('..')) {
      throw StateError('Ruta fuera del módulo.');
    }
    final source = File(p.join(root.path, relative));
    final type = await FileSystemEntity.type(source.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      _issues.add('missing:$relative');
      return;
    }
    if (type != FileSystemEntityType.file ||
        await source.resolveSymbolicLinks() !=
            p.join(await root.resolveSymbolicLinks(), relative)) {
      throw StateError('Referencia no regular o enlace simbólico.');
    }
    final bytes = await source.readAsBytes();
    if (!RegExp(
          r'\.(jpg|jpeg|png|webp)$',
          caseSensitive: false,
        ).hasMatch(relative) &&
        !relative.endsWith('/original')) {
      rejectSecrets(bytes);
    }
    final hash = sha256.convert(bytes).toString();
    final target = File(p.join(destination.path, 'raw', relative));
    await target.parent.create(recursive: true);
    await target.writeAsBytes(bytes, flush: true);
    if (await fileHash(target) != hash) throw StateError('Copia no íntegra.');
    _files[relative] = {'path': relative, 'size': bytes.length, 'sha256': hash};
  }

  Future<void> _tree(String relative) async {
    final directory = Directory(p.join(root.path, relative));
    if (!await directory.exists()) return;
    if (await directory.resolveSymbolicLinks() !=
        p.join(await root.resolveSymbolicLinks(), relative)) {
      throw StateError('Directorio enlazado.');
    }
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is Link) throw StateError('Enlace en evidencia.');
      if (entry is File) await _copy(p.relative(entry.path, from: root.path));
    }
  }

  Future<void> _references(Object? value) async {
    if (value is List) {
      for (final item in value) {
        await _references(item);
      }
    } else if (value is Map) {
      if (value['photoId'] is String) {
        _expectedPhotoIds.add(value['photoId'] as String);
      }
      for (final entry in value.entries) {
        if ([
              'localPath',
              'sourcePath',
              'uploadPath',
              'thumbnailPath',
            ].contains(entry.key) &&
            entry.value is String &&
            (entry.value as String).isNotEmpty) {
          final path = entry.value as String;
          final relative = p.isAbsolute(path)
              ? p.relative(path, from: root.path)
              : path;
          if ([
                'files/cabinets/',
                'files/camera_dispatch_v1/',
                'cache/',
              ].any(relative.startsWith) &&
              !p.split(relative).contains('..')) {
            await _copy(relative);
          } else {
            _issues.add('reference-outside-allowlist');
          }
        }
        await _references(entry.value);
      }
      final expected =
          value['sha256'] ?? map(value['metadata'])['clientSha256'];
      final path = value['uploadPath'] ?? value['localPath'];
      if (expected is String && path is String) {
        final relative = p.isAbsolute(path)
            ? p.relative(path, from: root.path)
            : path;
        if (_files[relative]?['sha256'] != expected.toLowerCase()) {
          _issues.add('declared-photo-hash-mismatch:$relative');
        }
      }
    }
  }

  Future<Map<String, dynamic>> create() async {
    if (_used) throw StateError('Exportador de un solo uso.');
    _used = true;
    await assertExclusive();
    if (await destination.exists()) throw StateError('Destino debe ser nuevo.');
    if (p.isWithin(root.absolute.path, destination.absolute.path) &&
        !p.isWithin(
          p.join(root.absolute.path, 'cache'),
          destination.absolute.path,
        )) {
      throw StateError('Destino debe estar fuera de originales.');
    }
    await destination.create(recursive: true);
    final sourceListing = await _sourceListing();
    for (final name in cabinetBoxes) {
      await _copy('app_flutter/$name.hive');
    }
    if (!_files.containsKey('app_flutter/cabinets_documents_v1.hive')) {
      throw StateError(
        'No existe caja principal; no se declara respaldo vacío.',
      );
    }
    // Hive may mutate its working copy; raw preservation files stay untouched.
    final hive = Hive;
    final work = Directory(p.join(destination.path, 'decode'));
    await work.create();
    hive.init(work.path);
    try {
      for (final name in cabinetBoxes) {
        final raw = File(
          p.join(destination.path, 'raw/app_flutter/$name.hive'),
        );
        if (!await raw.exists()) continue;
        await raw.copy(p.join(work.path, '$name.hive'));
        final box = await hive.openBox<dynamic>(
          name,
          crashRecovery: false,
          compactionStrategy: (_, _) => false,
        );
        for (final key in box.keys) {
          if (name == cabinetBoxes.first &&
              key == 'schemaVersion' &&
              box.get(key) != '1') {
            _issues.add('unknown-schema-version');
          }
          final rawValue = box.get(key);
          rejectSecrets(utf8.encode(jsonEncode(rawValue)));
          final Object? value = rawValue is String
              ? _decode(rawValue)
              : rawValue;
          _values.add(value);
          if (name == cabinetBoxes.first && '$key'.startsWith('cabinet:')) {
            if (value is! Map || value['id'] == null) {
              _issues.add('unknown-document-format');
              continue;
            }
            _documents.add(map(value));
          }
        }
      }
    } finally {
      await hive.close();
    }
    await _tree('files/cabinets');
    final broker = Directory(p.join(root.path, 'files/camera_dispatch_v1'));
    if (await broker.exists()) {
      await for (final entry in broker.list(followLinks: false)) {
        if (entry is Link) throw StateError('Broker enlazado.');
        if (entry is File && entry.path.endsWith('.json')) {
          final row = map(_decode(await entry.readAsString()));
          if (row['module'] == 'cabinets') {
            await _copy(p.relative(entry.path, from: root.path));
            final id = '${row['id']}';
            if (!RegExp(r'^[a-fA-F0-9-]{36}$').hasMatch(id)) {
              _issues.add('unknown-broker-id');
              continue;
            }
            await _tree('files/camera_dispatch_v1/$id');
            _values.add(row);
          } else if (row['module'] == 'QUARANTINE' ||
              row['state'] == 'AMBIGUOUS') {
            _issues.add('broker-unattributed-evidence');
          }
        }
      }
    }
    for (final value in _values) {
      await _references(value);
    }
    for (final doc in _documents) {
      for (final photo in maps(doc['photos'])) {
        final id = photo['id'];
        if (id is String) {
          _expectedPhotoIds.add(id);
        }
        if (!_files.keys.any(
          (f) => f.endsWith('/$id.source.jpg') || f.endsWith('/$id/original'),
        )) {
          _issues.add('original-unverified:$id');
        }
      }
    }
    for (final id in _expectedPhotoIds) {
      if (!_files.keys.any(
        (f) => f.endsWith('/$id.source.jpg') || f.endsWith('/$id/original'),
      )) {
        _issues.add('original-unverified:$id');
      }
    }
    await afterCopy?.call();
    await assertExclusive();
    if (jsonEncode(sourceListing) != jsonEncode(await _sourceListing())) {
      throw StateError('Archivos cambiaron durante la exportación.');
    }
    for (final entry in _files.entries) {
      final source = File(p.join(root.path, entry.key));
      if (!await source.exists() ||
          await fileHash(source) != entry.value['sha256']) {
        throw StateError('Origen cambió durante la exportación.');
      }
    }
    final inventory = _documents.map((doc) {
      final row = inventoryRow(doc);
      row['originals'] = maps(doc['photos']).map((photo) {
        final id = '${photo['id']}';
        final files = _files.values
            .where((f) => '${f['path']}'.contains(id))
            .toList();
        return {
          'photoId': id,
          'files': files,
          'originalAvailable': files.any(
            (f) =>
                '${f['path']}'.endsWith('/$id.source.jpg') ||
                '${f['path']}'.endsWith('/$id/original'),
          ),
        };
      }).toList();
      return row;
    }).toList();
    final manifest = <String, dynamic>{
      'format': 'ddr-cabinets-private-v1',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'complete': _issues.isEmpty,
      'issues': _issues.toList(),
      'dossiers': inventory.length,
      'files': _files.values.toList(),
      'inventory': inventory,
    };
    await File(
      p.join(destination.path, 'manifest.json'),
    ).writeAsString(jsonEncode(manifest), flush: true);
    await _bundle(manifest);
    return manifest;
  }

  Object? _decode(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return raw;
    }
  }

  Future<List<String>> _sourceListing() async {
    final rows = <String>[];
    for (final folder in [
      'app_flutter',
      'files/cabinets',
      'files/camera_dispatch_v1',
    ]) {
      final directory = Directory(p.join(root.path, folder));
      if (!await directory.exists()) continue;
      await for (final entry in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        final rel = p.relative(entry.path, from: root.path);
        if (folder == 'app_flutter' &&
            !p.basename(rel).startsWith('cabinets_')) {
          continue;
        }
        if (entry is Link) throw StateError('Enlace en origen.');
        if (entry is File) {
          rows.add(
            '$rel:${(await entry.stat()).size}:${await fileHash(entry)}',
          );
          if (folder == 'app_flutter' &&
              rel.endsWith('.hive') &&
              !cabinetBoxes.any((n) => rel == 'app_flutter/$n.hive')) {
            _issues.add('unknown-namespace:$rel');
          }
        }
      }
    }
    rows.sort();
    return rows;
  }

  Future<void> _bundle(Map<String, dynamic> manifest) async {
    final sink = File(p.join(destination.path, 'backup.ddr.jsonl')).openWrite();
    try {
      sink.writeln(jsonEncode({'manifest': manifest}));
      for (final file in _files.values) {
        sink.writeln(jsonEncode({'file': file['path']}));
        await for (final bytes in File(
          p.join(destination.path, 'raw', file['path'] as String),
        ).openRead()) {
          sink.writeln(jsonEncode({'data': base64Encode(bytes)}));
        }
        sink.writeln('{"end":true}');
      }
      sink.writeln('{"completeBundle":true}');
      await sink.flush();
    } finally {
      await sink.close();
    }
    await verifyBundle(File(p.join(destination.path, 'backup.ddr.jsonl')));
  }
}

Map<String, dynamic> inventoryRow(Map<String, dynamic> doc) {
  final w = map(doc['working']), s = map(doc['server']);
  final ops = maps(doc['operations']);
  return {
    'uid': w['uid'],
    'cabinetId': doc['id'],
    'model': w['model'],
    'working': w['status'],
    'server': s['status'],
    'localVersion': w['version'],
    'serverVersion': s['version'],
    'dirty': doc['dirty'],
    'synchronized': CabinetRecord(doc).synchronized,
    'originals': maps(
      doc['photos'],
    ).map((photo) => {'photoId': photo['id'], 'required': true}).toList(),
    'checklistItems': maps(w['parts']).length,
    'localValidated': w['partsValidated'],
    'evidence': w['registrationEvidence'],
    'photos': maps(doc['photos'])
        .map(
          (p) => {
            'photoId': p['id'],
            'verified': p['verified'],
            'remote': p['remote'],
          },
        )
        .toList(),
    'operations': ops.map((o) {
      final b = map(o['body']);
      return {
        'operationId': b['operationId'],
        'type': b['type'],
        'state': o['state'],
        'expectedVersion': b['expectedVersion'],
        'payloadSha256': payloadHash(b),
        'actor': o['actor'],
        'httpStatus': map(o['diagnostic'])['httpStatus'],
        'problemCode': map(o['problem'])['code'],
        'hasReceipt': map(o['result']).isNotEmpty,
        'errorPresent': o['error'] != null,
        'errorSha256': o['error'] == null ? null : payloadHash(o['error']),
        'requiresReceiptLookup': o['state'] == 'sending',
      };
    }).toList(),
    'recoveryScenarios': [
      if (ops.any((o) => map(o['result']).isNotEmpty))
        'A-recheck-original-receipt',
      if (ops.any((o) => ['queued', 'sending'].contains(o['state'])))
        'B-verify-original-command',
      if ((w['partsValidated'] == true || w['status'] == 'validated') &&
          !ops.any((o) => map(o['body'])['type'] == 'parts_validate'))
        'C-local-validation-without-durable-command',
      if (maps(
        doc['photos'],
      ).any((f) => f['verified'] != true && f['remote'] != true))
        'D-local-photo',
      if (ops.any((o) => o['state'] == 'conflict')) 'E-conflict',
    ],
    'dependenciesToVerify': [
      'existing cabinetId',
      'same actor',
      'remote version and receipt',
      'original photo hashes and remote verification',
      'registration_close',
      'parts_save',
      'parts_validate',
    ],
    'retransmissionAuthorized': false,
  };
}

/// Streaming validation; no extraction or network. Private inventory stays local.
Future<Map<String, dynamic>> verifyBundle(File bundle) async {
  Map<String, dynamic>? manifest;
  final found = <String>{};
  String? current;
  var size = 0, ended = false;
  ByteConversionSink? hashSink;
  Digest? digest;
  final expected = <String, Map<String, dynamic>>{};
  await for (final line
      in bundle
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
    final row = map(jsonDecode(line));
    if (ended) throw StateError('Datos después del fin.');
    if (row.containsKey('manifest') && manifest == null) {
      manifest = map(row['manifest']);
      if (manifest['format'] != 'ddr-cabinets-private-v1') {
        throw StateError('Formato desconocido.');
      }
      for (final f in maps(manifest['files'])) {
        final path = f['path'] as String;
        if (p.isAbsolute(path) ||
            p.split(path).contains('..') ||
            expected.containsKey(path)) {
          throw StateError('Ruta de bundle inválida.');
        }
        expected[path] = f;
      }
    } else if (row.containsKey('file') && current == null && manifest != null) {
      current = row['file'] as String;
      if (!expected.containsKey(current) || !found.add(current)) {
        throw StateError('Archivo inesperado.');
      }
      size = 0;
      digest = null;
      hashSink = sha256.startChunkedConversion(_DigestSink((d) => digest = d));
    } else if (row.containsKey('data') && current != null) {
      final bytes = base64Decode(row['data'] as String);
      size += bytes.length;
      hashSink!.add(bytes);
    } else if (row['end'] == true && current != null) {
      hashSink!.close();
      if (size != expected[current]!['size'] ||
          digest.toString() != expected[current]!['sha256']) {
        throw StateError('Hash o tamaño incorrecto.');
      }
      current = null;
    } else if (row['completeBundle'] == true &&
        current == null &&
        manifest != null) {
      ended = true;
    } else {
      throw StateError('Bundle fuera de secuencia.');
    }
  }
  if (!ended ||
      manifest == null ||
      found.length != expected.length ||
      current != null) {
    throw StateError('Bundle truncado.');
  }
  return manifest;
}

class _DigestSink implements Sink<Digest> {
  _DigestSink(this.done);
  final void Function(Digest) done;
  @override
  void add(Digest data) => done(data);
  @override
  void close() {}
}

/// Extracts only to a NEW directory after validating every byte of the bundle.
/// It never opens original device boxes or overwrites existing files.
Future<Map<String, dynamic>> extractBundle(
  File bundle,
  Directory destination,
) async {
  final manifest = await verifyBundle(bundle);
  if (await destination.exists()) {
    throw StateError('Destino de análisis ya existe.');
  }
  await destination.create(recursive: true);
  IOSink? sink;
  try {
    await for (final line
        in bundle
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final row = map(jsonDecode(line));
      if (row.containsKey('file')) {
        final file = File(p.join(destination.path, row['file'] as String));
        await file.parent.create(recursive: true);
        sink = file.openWrite();
      } else if (row.containsKey('data')) {
        sink!.add(base64Decode(row['data'] as String));
      } else if (row['end'] == true) {
        await sink!.flush();
        await sink.close();
        sink = null;
      }
    }
  } finally {
    await sink?.close();
  }
  for (final file in maps(manifest['files'])) {
    if (await fileHash(
          File(p.join(destination.path, file['path'] as String)),
        ) !=
        file['sha256']) {
      throw StateError('Copia de análisis inválida.');
    }
  }
  return manifest;
}

/// Shared private bundle writer for an already verified, isolated snapshot.
Future<void> writePrivateCabinetBundle(
  Directory destination,
  Map<String, dynamic> manifest,
) async {
  final sink = File(p.join(destination.path, 'backup.ddr.jsonl')).openWrite();
  try {
    sink.writeln(jsonEncode({'manifest': manifest}));
    for (final f in maps(manifest['files'])) {
      sink.writeln(jsonEncode({'file': f['path']}));
      await for (final bytes in File(
        p.join(destination.path, 'raw', f['path'] as String),
      ).openRead()) {
        sink.writeln(jsonEncode({'data': base64Encode(bytes)}));
      }
      sink.writeln('{"end":true}');
    }
    sink.writeln('{"completeBundle":true}');
    await sink.flush();
  } finally {
    await sink.close();
  }
  await verifyBundle(File(p.join(destination.path, 'backup.ddr.jsonl')));
}
