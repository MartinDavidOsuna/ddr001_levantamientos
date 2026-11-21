import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import '../../domain/cabinets/cabinet_models.dart';
import '../../recovery/cabinet_backup.dart' show fileHash, payloadHash;
import 'legacy_photo_diagnostic.dart' show imageHeader;

typedef LegacyJpegEncoder =
    Future<void> Function(
      String source,
      String target,
      int width,
      int height,
      int quality,
    );
Future<void> encodeLegacyJpeg(
  String source,
  String target,
  int width,
  int height,
  int quality,
) async {
  final result = await FlutterImageCompress.compressAndGetFile(
    source,
    target,
    // Android swaps requested dimensions for EXIF rotation. Equal short-side
    // bounds preserve the aspect ratio and cap the long side in either orientation.
    minWidth: min(width, height),
    minHeight: min(width, height),
    quality: quality,
    format: CompressFormat.jpeg,
    keepExif: false,
  );
  if (result == null) throw StateError('DERIVATIVE_ENCODE_FAILED');
}

/// Private immutable transport representation; historical document is never edited.
class LegacyDerivativeEvidence {
  LegacyDerivativeEvidence(this.directory, this.photo, this.manifest);
  final Directory directory;
  final Json photo, manifest;
  static const maxBytes = 6 * 1024 * 1024;
  Json get transport => {
    ...clone(photo),
    'localPath': '${directory.path}/upload.jpg',
    'metadata': {
      ...object(photo['metadata']),
      'clientSha256': manifest['transportSha256'],
    },
  };
  String get summary =>
      'Foto ${photo['id'].toString().substring(0, 8)} · original ${manifest['sourceBytes']} bytes protegido · derivado ${manifest['bytes']} bytes · '
      '${manifest['width']}×${manifest['height']} · SHA original/derivado verificados · photoId conservado';
  Future<void> verify() async {
    if (await fileHash(File(manifest['sourcePath'])) !=
            manifest['sourceSha256'] ||
        await fileHash(File(photo['localPath'])) !=
            manifest['historicalUploadSha256'] ||
        await fileHash(File('${directory.path}/upload.jpg')) !=
            manifest['transportSha256'] ||
        await File('${directory.path}/upload.jpg').length() !=
            manifest['bytes'] ||
        manifest['originalMetadataSha256'] != payloadHash(photo['metadata'])) {
      throw StateError('DERIVATIVE_INTEGRITY_BLOCKED');
    }
    final persisted = object(
      jsonDecode(await File('${directory.path}/manifest.json').readAsString()),
    );
    if (payloadHash(persisted) != payloadHash(manifest)) {
      throw StateError('DERIVATIVE_MANIFEST_CHANGED');
    }
  }

  static Future<LegacyDerivativeEvidence> prepare({
    required Directory support,
    required String cabinetId,
    required Json photo,
    required File source,
    required void Function() assertLease,
    LegacyJpegEncoder encoder = encodeLegacyJpeg,
    int quality = 82,
  }) async {
    assertLease();
    if (quality < 60 || quality > 90) {
      throw StateError('DERIVATIVE_QUALITY_RANGE');
    }
    final sourceHash = await fileHash(source),
        uploadHash = await fileHash(File(photo['localPath']));
    if (uploadHash != object(photo['metadata'])['clientSha256']) {
      throw StateError('HISTORICAL_HASH_MISMATCH');
    }
    // This pilot's RC10 measurements certified byte-identical original/upload.
    // Do not derive from an unlinked source merely because its filename matches.
    if (sourceHash != uploadHash) {
      throw StateError('LEGACY_SOURCE_UPLOAD_MISMATCH');
    }
    final header = await imageHeader(source);
    final dimensions = RegExp(r'^image/jpeg · (\d+)×(\d+)$').firstMatch(header);
    if (dimensions == null) throw StateError('DERIVATIVE_SOURCE_JPEG_REQUIRED');
    final width = int.parse(dimensions[1]!), height = int.parse(dimensions[2]!);
    final key = payloadHash({
      'cabinetId': cabinetId,
      'photoId': photo['id'],
      'source': sourceHash,
      'upload': uploadHash,
      'metadata': photo['metadata'],
      'actor': photo['actor'],
      'quality': quality,
      'policy': 'legacy-jpeg-1920-6m-v1',
    });
    final finalDir = Directory(
      '${support.path}/cabinet_legacy_derivatives_v1/$cabinetId/$key',
    );
    final pending = Directory('${finalDir.path}.pending');
    for (final directory in [
      finalDir.parent.parent,
      finalDir.parent,
      finalDir,
      pending,
    ]) {
      final type = await FileSystemEntity.type(
        directory.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.directory) {
        throw StateError('DERIVATIVE_PATH_BLOCKED');
      }
    }
    Future<LegacyDerivativeEvidence> load(Directory dir) async {
      for (final name in ['manifest.json', 'upload.jpg']) {
        if (await FileSystemEntity.type(
              '${dir.path}/$name',
              followLinks: false,
            ) !=
            FileSystemEntityType.file) {
          throw StateError('DERIVATIVE_FILE_BLOCKED');
        }
      }
      final m = object(
        jsonDecode(await File('${dir.path}/manifest.json').readAsString()),
      );
      if (m['key'] != key ||
          m['sourceSha256'] != sourceHash ||
          m['historicalUploadSha256'] != uploadHash ||
          m['bytes'] is! int ||
          m['bytes'] > maxBytes ||
          m['width'] > 1920 ||
          m['height'] > 1920) {
        throw StateError('DERIVATIVE_PLAN_MISMATCH');
      }
      final result = LegacyDerivativeEvidence(dir, clone(photo), m);
      await result.verify();
      return result;
    }

    if (await finalDir.exists()) return load(finalDir);
    if (await File('${pending.path}/manifest.json').exists()) {
      await load(pending);
      assertLease();
      await pending.rename(finalDir.path);
      return load(finalDir);
    }
    await pending.create(recursive: true);
    final target = File('${pending.path}/upload.jpg');
    // Only an unpublished, application-owned temporary derivative can be retried.
    if (await target.exists()) await target.delete();
    Json? result;
    for (var step = 0; step < 4; step++) {
      assertLease();
      final bound = [1920, 1600, 1280, 960][step];
      final scale = min(1.0, bound / max(width, height));
      final w = max(1, (width * scale).floor()),
          h = max(1, (height * scale).floor());
      if (await target.exists()) await target.delete();
      await encoder(
        source.path,
        target.path,
        w,
        h,
        max(60, quality - step * 6),
      );
      assertLease();
      final bytes = await target.length();
      if (bytes > maxBytes) continue;
      if (!(await imageHeader(target)).startsWith('image/jpeg · ')) {
        throw StateError('DERIVATIVE_MIME_INVALID');
      }
      final codec = await ui.instantiateImageCodec(await target.readAsBytes());
      late int dw, dh;
      try {
        final frame = await codec.getNextFrame();
        dw = frame.image.width;
        dh = frame.image.height;
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
      if (dw > bound ||
          dh > bound ||
          (((dw / dh) - (width / height)).abs() > 0.02 &&
              ((dh / dw) - (width / height)).abs() > 0.02)) {
        throw StateError('DERIVATIVE_DIMENSIONS_INVALID');
      }
      if (await fileHash(source) != sourceHash ||
          await fileHash(File(photo['localPath'])) != uploadHash) {
        throw StateError('HISTORICAL_BYTES_CHANGED');
      }
      result = {
        'key': key,
        'policy': 'legacy-jpeg-1920-6m-v1',
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'cabinetId': cabinetId,
        'photoId': photo['id'],
        'actor': photo['actor'],
        'sourcePath': source.path,
        'sourceSha256': sourceHash,
        'sourceBytes': await source.length(),
        'historicalUploadBytes': await File(photo['localPath']).length(),
        'historicalUploadSha256': uploadHash,
        'originalMetadataSha256': payloadHash(photo['metadata']),
        'originalMetadata': clone(object(photo['metadata'])),
        'transportSha256': await fileHash(target),
        'bytes': bytes,
        'width': dw,
        'height': dh,
        'quality': max(60, quality - step * 6),
      };
      break;
    }
    if (result == null) throw StateError('DERIVATIVE_SIZE_BLOCKED');
    final handle = await target.open(mode: FileMode.append);
    await handle.flush();
    await handle.close();
    await File(
      '${pending.path}/manifest.json.part',
    ).writeAsString(jsonEncode(result), flush: true);
    await File(
      '${pending.path}/manifest.json.part',
    ).rename('${pending.path}/manifest.json');
    assertLease();
    await load(pending);
    await pending.rename(finalDir.path);
    return load(finalDir);
  }
}
