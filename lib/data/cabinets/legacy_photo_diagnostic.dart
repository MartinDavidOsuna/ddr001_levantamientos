import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import '../../domain/cabinets/cabinet_models.dart';
import '../../recovery/cabinet_backup.dart' show fileHash;
import 'cabinet_api.dart';

/// Header-only dimensions, bounded to 1 MiB: no decoding/recompression or writes.
Future<String> imageHeader(File file) async {
  final f = await file.open();
  late Uint8List bytes;
  try {
    bytes = await f.read(min(await f.length(), 1024 * 1024));
  } finally {
    await f.close();
  }
  if (bytes.length >= 24 &&
      bytes.take(8).join(',') == '137,80,78,71,13,10,26,10') {
    final b = ByteData.sublistView(bytes);
    return 'image/png · ${b.getUint32(16)}×${b.getUint32(20)}';
  }
  if (bytes.length < 2 || bytes[0] != 255 || bytes[1] != 216) {
    return 'formato/resolución no reconocidos';
  }
  var i = 2;
  while (i + 3 < bytes.length) {
    if (bytes[i++] != 255) break;
    while (i < bytes.length && bytes[i] == 255) {
      i++;
    }
    if (i >= bytes.length) break;
    final marker = bytes[i++];
    if (marker == 217 || marker == 218) break;
    if (marker == 1 || (marker >= 208 && marker <= 215)) continue;
    if (i + 1 >= bytes.length) break;
    final length = bytes[i] * 256 + bytes[i + 1];
    if (length < 2 || i + length > bytes.length) break;
    if ({
          192,
          193,
          194,
          195,
          197,
          198,
          199,
          201,
          202,
          203,
          205,
          206,
          207,
        }.contains(marker) &&
        length >= 8) {
      return 'image/jpeg · ${bytes[i + 5] * 256 + bytes[i + 6]}×${bytes[i + 3] * 256 + bytes[i + 4]}';
    }
    i += length;
  }
  return 'image/jpeg · resolución no disponible en cabecera acotada';
}

Future<String> legacyPhotoDiagnostic(
  Json photo,
  File original, {
  int referenceApiLimit = 8388608,
}) async {
  String size(int bytes) =>
      '$bytes bytes (${(bytes / 1048576).toStringAsFixed(6)} MiB)';
  final metadata = object(photo['metadata']);
  final context =
      const {
        'registration',
        'parts_validation',
        'correction',
        'installation',
        'final_review',
      }.contains(metadata['context'])
      ? metadata['context']
      : 'no reconocido';
  final rawId = '${photo['id']}';
  final id =
      RegExp(
        r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
      ).hasMatch(rawId)
      ? '${rawId.substring(0, 8)}…${rawId.substring(32)}'
      : 'no válido';
  final heading = 'Foto: $id · contexto: $context\n';
  if (!await original.exists()) {
    return '${heading}Original no disponible; no se repara ni genera. Medición incompleta.';
  }
  final originalSize = await original.length();
  final originalHash = await fileHash(original);
  final originalHeader = await imageHeader(original);
  if (photo['localPath'] is! String ||
      !await File(photo['localPath']).exists()) {
    return '${heading}Original: ${size(originalSize)} · $originalHeader\n'
        'Carga no disponible; no se genera ni sustituye por el original. Multipart no calculable.\n'
        'SHA-256 original: $originalHash\nLímite real de producción NO CERTIFICADO.';
  }
  final upload = File(photo['localPath']);
  final uploadSize = await upload.length(), uploadHash = await fileHash(upload);
  final multipart = await cabinetPhotoMultipart(photo);
  final uploadHeader = await imageHeader(upload);
  final shared =
      await original.resolveSymbolicLinks() ==
      await upload.resolveSymbolicLinks();
  if (await fileHash(original) != originalHash ||
      await fileHash(upload) != uploadHash) {
    return '${heading}Archivos cambiaron durante lectura; medición no certificada. No se modificaron.';
  }
  return '$heading'
      'Original: ${size(originalSize)} · $originalHeader\n'
      'Carga: ${size(uploadSize)} · $uploadHeader\n'
      '${shared ? "Original y carga comparten archivo existente; sin regeneración." : "Original y carga separados."}\n'
      'MIME multipart declarado: image/jpeg\n'
      'Compatibilidad MIME: ${uploadHeader.startsWith("image/jpeg") ? "JPEG por cabecera; no certifica decodificación" : "incompatible o no reconocida; revisar"}\n'
      'Multipart calculado (cuerpo Dio): ${size(multipart.length)}; no incluye cabeceras HTTP/TLS\n'
      'SHA-256 original: $originalHash\nSHA-256 carga: $uploadHash\n'
      'Hash declarado: ${metadata['clientSha256'] == uploadHash ? "coincide" : "NO coincide; detener"}\n'
      'Límite informativo por archivo: ${size(referenceApiLimit)}; '
      '${uploadSize < referenceApiLimit
          ? "por debajo"
          : uploadSize == referenceApiLimit
          ? "EXACTAMENTE en el umbral; multipart es mayor"
          : "SUPERADO: EXCEDE el umbral de referencia"}. '
      'Límite real de producción NO CERTIFICADO. No autoriza envío.';
}
