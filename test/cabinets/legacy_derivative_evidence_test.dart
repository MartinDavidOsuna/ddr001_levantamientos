import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_derivative_evidence.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/recovery/cabinet_backup.dart'
    show fileHash;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late File source, upload;
  late Json photo;
  var encodes = 0;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('legacy-derived-test-');
    source = await File(
      'test/cabinets/fixtures/legacy-12000x6752.jpg',
    ).copy('${root.path}/original.jpg');
    upload = await source.copy('${root.path}/historical-upload.jpg');
    photo = {
      'id': 'b1000000-0000-4000-8000-000000000006',
      'actor': 'synthetic',
      'localPath': upload.path,
      'metadata': {
        'clientSha256': await fileHash(upload),
        'context': 'registration',
      },
    };
    encodes = 0;
  });
  tearDown(() async => root.delete(recursive: true));
  Future<void> encoder(String s, String t, int w, int h, int q) async {
    encodes++;
    expect(w, 1920);
    expect(h, 1080);
    expect(q, 82);
    await File('test/cabinets/fixtures/legacy-derived.jpg').copy(t);
  }

  Future<LegacyDerivativeEvidence> prepare({LegacyJpegEncoder? use}) =>
      LegacyDerivativeEvidence.prepare(
        support: root,
        cabinetId: 'b0000000-0000-4000-8000-000000000006',
        photo: photo,
        source: source,
        assertLease: () {},
        encoder: use ?? encoder,
      );
  test(
    'read originals, hash distinct, reusable immutable derivative',
    () async {
      final before = await fileHash(source);
      final d = await prepare();
      await d.verify();
      expect(d.manifest['sourceSha256'], before);
      expect(d.manifest['transportSha256'], isNot(before));
      expect(
        d.transport['metadata']['clientSha256'],
        await fileHash(File(d.transport['localPath'])),
      );
      expect(photo['metadata']['clientSha256'], before);
      expect((await prepare()).directory.path, d.directory.path);
      expect(encodes, 1);
      expect(await fileHash(source), before);
      expect(await fileHash(upload), before);
    },
  );
  test(
    'interrupted unpublished write retries without changing originals',
    () async {
      final before = await fileHash(source);
      await expectLater(
        prepare(
          use: (s, t, w, h, q) async {
            await File(t).writeAsBytes([1, 2, 3]);
            throw StateError('INTERRUPTION');
          },
        ),
        throwsStateError,
      );
      final d = await prepare();
      await d.verify();
      expect(await fileHash(source), before);
      expect(await fileHash(upload), before);
    },
  );
  test('bounded size reduction rejects four oversized results', () async {
    var tries = 0;
    await expectLater(
      prepare(
        use: (s, t, w, h, q) async {
          tries++;
          final f = await File(t).open(mode: FileMode.write);
          await f.truncate(6 * 1024 * 1024 + 1);
          await f.close();
        },
      ),
      throwsStateError,
    );
    expect(tries, 4);
  });
  test(
    'completed pending manifest promotes atomically after interruption',
    () async {
      final d = await prepare();
      await d.directory.rename('${d.directory.path}.pending');
      final resumed = await prepare();
      await resumed.verify();
      expect(resumed.directory.path, d.directory.path);
      expect(encodes, 1);
    },
  );
  test('published symlink is rejected rather than followed', () async {
    final d = await prepare();
    final file = File(d.transport['localPath']);
    await file.delete();
    await Link(file.path).create(source.path);
    await expectLater(prepare(), throwsStateError);
    expect(await fileHash(source), photo['metadata']['clientSha256']);
  });
  test(
    'EXIF-normalized portrait retains aspect and maximum dimension',
    () async {
      final d = await prepare(
        use: (s, t, w, h, q) async {
          await File(
            'test/cabinets/fixtures/legacy-derived-portrait.jpg',
          ).copy(t);
        },
      );
      await d.verify();
      expect(d.manifest['width'], 1080);
      expect(d.manifest['height'], 1920);
    },
  );
  test('incorrect MIME cannot be published', () async {
    await expectLater(
      prepare(
        use: (s, t, w, h, q) async {
          await File(t).writeAsString('not a JPEG');
        },
      ),
      throwsStateError,
    );
  });
  test('historical hash mismatch blocks before encoding', () async {
    photo['metadata']['clientSha256'] = '0' * 64;
    await expectLater(prepare(), throwsStateError);
    expect(encodes, 0);
  });
  test(
    'pilot original must match the historically certified upload hash',
    () async {
      await source.writeAsBytes([1], mode: FileMode.append);
      await expectLater(prepare(), throwsStateError);
      expect(encodes, 0);
    },
  );
  test('missing original blocks before encoding', () async {
    await source.delete();
    await expectLater(prepare(), throwsA(isA<FileSystemException>()));
    expect(encodes, 0);
  });
  test('changed manifest and corrupt derivative fail closed', () async {
    final d = await prepare();
    await File('${d.directory.path}/manifest.json').writeAsString('{}');
    await expectLater(d.verify(), throwsStateError);
    await expectLater(prepare(), throwsStateError);
  });
}
