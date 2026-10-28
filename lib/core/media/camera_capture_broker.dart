import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

abstract interface class ConstructionImagePicker {
  Future<XFile?> takePhoto();
  Future<LostDataResponse> retrieveLostData();
}

class ImagePickerAdapter implements ConstructionImagePicker {
  ImagePickerAdapter([ImagePicker? picker]) : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;
  @override
  Future<XFile?> takePhoto() => _picker.pickImage(
    source: ImageSource.camera,
    imageQuality: 100,
    requestFullMetadata: true,
  );
  @override
  Future<LostDataResponse> retrieveLostData() => Platform.isAndroid
      ? _picker.retrieveLostData()
      : Future.value(LostDataResponse.empty());
}

/// The only consumer of the native lost-result slot. Originals and receipts are
/// retained, never handed to a different module or guessed from cache age.
class CameraCaptureBroker {
  CameraCaptureBroker({
    required this.picker,
    Future<Directory> Function()? supportDirectory,
    Future<Directory> Function()? temporaryDirectory,
    this.fault,
    DateTime Function()? now,
  }) : supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       now = now ?? DateTime.now,
       temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;
  static final shared = CameraCaptureBroker(picker: ImagePickerAdapter());
  final ConstructionImagePicker picker;
  final DateTime Function() now;
  final Future<Directory> Function() supportDirectory;
  final Future<Directory> Function() temporaryDirectory;
  Future<void> Function(String)? fault;
  bool _busy = false;
  bool get busy => _busy;
  Future<Directory> _root() async {
    final root = Directory(
      '${(await supportDirectory()).path}/camera_dispatch_v1',
    );
    await root.create(recursive: true);
    return root;
  }

  void _id(String id) {
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id)) {
      throw StateError('Invalid capture identifier');
    }
  }

  Future<Map<String, dynamic>?> _read(String name) async {
    final file = File('${(await _root()).path}/$name.json');
    if (!await file.exists()) return null;
    return Map<String, dynamic>.from(jsonDecode(await file.readAsString()));
  }

  Future<void> _write(String name, Map<String, dynamic> value) async {
    await fault?.call('before:$name');
    final file = File('${(await _root()).path}/$name.json');
    final partial = File('${file.path}.part');
    await partial.writeAsString(jsonEncode(value), flush: true);
    await partial.rename(file.path);
    await fault?.call('after:$name');
  }

  Future<T> _exclusive<T>(Future<T> Function() action) async {
    if (_busy) {
      throw StateError('Hay una captura o recuperación de cámara en curso.');
    }
    _busy = true;
    try {
      return await action();
    } finally {
      _busy = false;
    }
  }

  Future<Map<String, dynamic>?> receipt(String module, String id) async {
    _id(id);
    final row = await _read(id);
    return row?['module'] == module ? row : null;
  }

  Future<Map<String, dynamic>?> result(String module, String id) async {
    _id(id);
    final data = await _read(id);
    return data?['module'] == module && data?['state'] == 'READY' ? data : null;
  }

  Future<Map<String, dynamic>?> capture({
    required String id,
    required String module,
    required String entityId,
    required String actorId,
    required String role,
    required DateTime requestedAt,
  }) => _exclusive(() async {
    _id(id);
    _id(entityId);
    await _recover();
    final previous = await _read(id);
    if (previous != null) {
      if (previous['module'] != module ||
          previous['entityId'] != entityId ||
          previous['actorId'] != actorId ||
          previous['role'] != role) {
        throw StateError('Capture identity conflict');
      }
      if (previous['state'] == 'READY') return previous;
      if (previous['state'] == 'CANCELLED') return null;
      throw StateError(
        'Captura pendiente de recuperación; no se repetirá con otro propietario.',
      );
    }
    final entry = <String, dynamic>{
      'id': id,
      'module': module,
      'entityId': entityId,
      'actorId': actorId,
      'role': role,
      'requestedAt': requestedAt.toUtc().toIso8601String(),
      'state': 'PREPARED',
    };
    await _write(id, entry);
    await _write('active', {'id': id});
    final picked = await picker.takePhoto();
    if (picked == null) {
      await _write(id, {...entry, 'state': 'CANCELLED'});
      await _write('active', {});
      return null;
    }
    final received = await _receive(entry, picked, false);
    await _write('active', {});
    return received;
  });
  Future<void> recover() => _exclusive(_recover);
  Future<void> _recover() async {
    // Finish receipts whose native response was consumed before interruption,
    // including quarantine copies that have no active owner pointer.
    await for (final file in (await _root()).list()) {
      if (file is File &&
          file.path.endsWith('.json') &&
          !file.path.endsWith('/active.json')) {
        final row = Map<String, dynamic>.from(
          jsonDecode(await file.readAsString()),
        );
        if (row['state'] == 'RECEIVED') {
          final source = File(row['sourcePath']);
          final original = File(
            '${(await _root()).path}/${row['id']}/original',
          );
          final missing = !await source.exists() || await source.length() == 0;
          final badOriginal =
              await original.exists() &&
              ((await sha256.bind(original.openRead()).first).toString() !=
                      row['expectedSha256'] ||
                  await original.length() != row['expectedLength']);
          if ((missing && !await original.exists()) || badOriginal) {
            await _write(row['id'], {
              ...row,
              'state': 'AMBIGUOUS',
              'reason': 'ORIGINAL_MISSING_EMPTY_OR_CORRUPT',
            });
          } else {
            await _persistOriginal(row);
          }
        }
      }
    }
    final pointer = await _read('active');
    final activeId = pointer?['id'] as String?;
    Map<String, dynamic>? entry = activeId == null
        ? null
        : await _read(activeId);
    if (entry?['state'] == 'RECEIVED') {
      await _persistOriginal(entry!);
      await _write('active', {});
      entry = null;
    } else if (entry?['state'] == 'READY' || entry?['state'] == 'CANCELLED') {
      await _write('active', {});
      entry = null;
    }
    final lost = await picker.retrieveLostData();
    final files = <String, XFile>{
      for (final file in [...?lost.files, if (lost.file != null) lost.file!])
        file.path: file,
    }.values.toList();
    if (files.length == 1 && entry?['state'] == 'PREPARED') {
      await _receive(entry!, files.single, true);
    } else {
      for (final file in files) {
        final id = const Uuid().v4();
        await _receive(
          {
            'id': id,
            'module': 'QUARANTINE',
            'entityId': null,
            'actorId': null,
            'role': null,
            'requestedAt': null,
            'reason': 'NO_UNIQUE_DURABLE_OWNER',
          },
          file,
          true,
        );
      }
      if (entry != null) {
        await _write(entry['id'], {
          ...entry,
          'state': 'AMBIGUOUS',
          'reason': files.isEmpty
              ? 'NO_RETURNED_FILE'
              : 'MULTIPLE_RETURNED_FILES',
        });
      }
    }
    if (entry != null && files.isEmpty) {
      try {
        await _preserveUnownedCache(await temporaryDirectory());
      } on Object {
        await _write(entry['id'], {
          ...entry,
          'state': 'AMBIGUOUS',
          'reason': 'CACHE_RECOVERY_PENDING',
        });
      }
    }
    await _write('active', {});
  }

  Future<Map<String, dynamic>> _receive(
    Map<String, dynamic> entry,
    XFile file,
    bool recovered,
  ) async {
    final returned = now().toUtc();
    final modified = (await file.lastModified()).toUtc();
    final received = {
      ...entry,
      'state': 'RECEIVED',
      'sourcePath': file.path,
      'returnedAt': returned.toIso8601String(),
      'fileModifiedAt': modified.toIso8601String(),
      'recovered': recovered,
      'expectedSha256': (await sha256.bind(File(file.path).openRead()).first)
          .toString(),
      'expectedLength': await file.length(),
    };
    await _write(entry['id'], received);
    return _persistOriginal(received);
  }

  Future<Map<String, dynamic>> _persistOriginal(
    Map<String, dynamic> entry,
  ) async {
    final source = File(entry['sourcePath']);
    final directory = Directory('${(await _root()).path}/${entry['id']}');
    await directory.create(recursive: true);
    final target = File('${directory.path}/original');
    final partial = File('${target.path}.part');
    if (!await target.exists()) {
      if (!await source.exists() || await source.length() == 0) {
        throw StateError(
          'Archivo de cámara ausente o vacío; intención conservada.',
        );
      }
      await fault?.call('before:copy');
      final sink = partial.openWrite();
      await sink.addStream(source.openRead());
      await sink.flush();
      await sink.close();
      await fault?.call('after:copy');
      final sourceHash = (await sha256.bind(source.openRead()).first)
          .toString();
      if (await partial.length() != await source.length() ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              sourceHash) {
        throw StateError('La copia del original está incompleta.');
      }
      await partial.rename(target.path);
    }
    final hash = (await sha256.bind(target.openRead()).first).toString();
    if (hash != entry['expectedSha256'] ||
        await target.length() != entry['expectedLength'] ||
        await target.length() == 0) {
      throw StateError('Original corrupto o incompleto; archivos conservados.');
    }
    final ready = {
      ...entry,
      'state': 'READY',
      'originalPath': target.path,
      'sha256': hash,
      'byteLength': await target.length(),
    };
    await _write(entry['id'], ready);
    return ready;
  }

  Future<void> preserveUnownedCache(Directory cache) =>
      _exclusive(() => _preserveUnownedCache(cache));
  Future<void> _preserveUnownedCache(Directory cache) async {
    if (!await cache.exists()) return;
    final index = await _read('cache-index') ?? <String, dynamic>{};
    await for (final file in cache.list()) {
      if (file is! File ||
          !RegExp(
            r'\.(jpg|jpeg|png|heic)$',
            caseSensitive: false,
          ).hasMatch(file.path) ||
          await file.length() == 0) {
        continue;
      }
      final hash = (await sha256.bind(file.openRead()).first).toString();
      if (index.containsKey(hash)) continue;
      final id = const Uuid().v4();
      await _receive(
        {
          'id': id,
          'module': 'QUARANTINE',
          'entityId': null,
          'actorId': null,
          'role': null,
          'requestedAt': null,
          'reason': 'UNOWNED_CACHE_FILE_NOT_ASSOCIATED',
        },
        XFile(file.path),
        true,
      );
      index[hash] = id;
      await _write('cache-index', index);
    }
  }

  Future<List<Map<String, dynamic>>> quarantined() async {
    final result = <Map<String, dynamic>>[];
    await for (final file in (await _root()).list()) {
      if (file is File && file.path.endsWith('.json')) {
        final j = Map<String, dynamic>.from(
          jsonDecode(await file.readAsString()),
        );
        if (j['module'] == 'QUARANTINE' || j['state'] == 'AMBIGUOUS') {
          result.add(j);
        }
      }
    }
    return result;
  }
}
