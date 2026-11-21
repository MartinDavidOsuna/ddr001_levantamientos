import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_api.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_photo_diagnostic.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_operation_diagnostic.dart';
import 'package:ddr001_levantamientos/recovery/cabinet_backup.dart'
    show fileHash;

void main() {
  for (final large in [false, true]) {
    test('read only multipart and image sizes: over limit=$large', () async {
      final dir = await Directory.systemTemp.createTemp('photo413-test');
      try {
        final source = await File(
          'test/cabinets/fixtures/evidence.jpg',
        ).copy('${dir.path}/original.jpg');
        final upload = await source.copy('${dir.path}/upload.jpg');
        final limit = await upload.length() + (large ? -1 : 1);
        final photo = <String, dynamic>{
          'id': 'b1000000-0000-4000-8000-000000000006',
          'localPath': upload.path,
          'metadata': {
            'context': 'registration',
            'clientSha256': await fileHash(upload),
          },
        };
        final before = jsonEncode(photo), hash = await fileHash(source);
        final diagnostic = await legacyPhotoDiagnostic(
          photo,
          source,
          referenceApiLimit: limit,
        );
        expect(diagnostic, contains(large ? 'SUPERADO' : 'por debajo'));
        expect(diagnostic, contains('image/jpeg'));
        expect(diagnostic, contains('Hash declarado: coincide'));
        expect(diagnostic, isNot(contains(dir.path)));
        final form = await cabinetPhotoMultipart(photo);
        final size = form.length;
        final actual = await form.finalize().fold<int>(
          0,
          (n, b) => n + b.length,
        );
        expect(size, actual);
        expect(size, greaterThan(await upload.length()));
        expect(await fileHash(source), hash);
        expect(await fileHash(upload), hash);
        expect(jsonEncode(photo), before);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  }
  test(
    'missing upload and incompatible bytes/hash are reported without repair',
    () async {
      final dir = await Directory.systemTemp.createTemp('metrics-invalid');
      try {
        final original = await File(
          '${dir.path}/source.jpg',
        ).writeAsBytes([1, 2, 3]);
        final missing = '${dir.path}/missing.jpg';
        final photo = <String, dynamic>{
          'id': 'b1000000-0000-4000-8000-000000000006',
          'localPath': missing,
          'metadata': {'context': 'registration', 'clientSha256': 'bad'},
        };
        expect(
          await legacyPhotoDiagnostic(photo, original),
          contains('Carga no disponible'),
        );
        expect(await File(missing).exists(), false);
        photo['localPath'] = original.path;
        final result = await legacyPhotoDiagnostic(photo, original);
        expect(result, contains('NO coincide'));
        expect(result, contains('incompatible o no reconocida'));
        expect(result, contains('comparten archivo'));
        expect(await original.readAsBytes(), [1, 2, 3]);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    '413 API or opaque proxy response is not a transient retry permission',
    () {
      for (final problem in [
        <String, dynamic>{
          'status': 413,
          'type': 'https://rvs.example/problems/payload-too-large',
        },
        <String, dynamic>{},
      ]) {
        final op = <String, dynamic>{
          'state': 'conflict',
          'actor': 'a',
          'diagnostic': {
            'httpStatus': 413,
            'path': '/construction/cabinets/SECRET/photos',
          },
          'problem': problem,
          'body': {'type': 'registration_close'},
        };
        final before = jsonEncode(op);
        final d = LegacyOperationDiagnostic(
          op,
          actor: 'a',
          index: 0,
          photos: [],
        );
        expect(d.category, contains('413'));
        expect(d.transient, false);
        expect(d.historicalPhase, contains('antes del comando'));
        expect(d.recommendation, contains('no reintentar'));
        expect(d.summary, isNot(contains('SECRET')));
        expect(jsonEncode(op), before);
      }
    },
  );
}
