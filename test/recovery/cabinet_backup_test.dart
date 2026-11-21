import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ddr001_levantamientos/recovery/cabinet_backup.dart';

void main() {
  late Directory temp, root, output;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('recovery-fixture-');
    root = Directory('${temp.path}/device');
    output = Directory('${temp.path}/backup');
    await Directory('${root.path}/app_flutter').create(recursive: true);
    Hive.init('${root.path}/app_flutter');
    for (final name in cabinetBoxes) {
      final box = await Hive.openBox<String>(name);
      if (name == cabinetBoxes.first) {
        await box.put('schemaVersion', '1');
        for (var n = 0; n < 22; n++) {
          final id = '00000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
          final photo =
              '10000000-0000-4000-8000-${n.toString().padLeft(12, '0')}';
          final f = File(
            '${root.path}/files/cabinets/$id/evidence/$photo.source.jpg',
          );
          await f.parent.create(recursive: true);
          await f.writeAsBytes([255, 216, n, 255, 217]);
          await box.put(
            'cabinet:$id',
            jsonEncode({
              'id': id,
              'working': {
                'uid': 'synthetic-$n',
                'model': 'A1',
                'status': n.isEven ? 'validated' : 'draft',
                'partsValidated': n.isEven,
                'parts': [
                  {'code': 'legacy', 'checked': true},
                ],
                'catalogVersion': 'legacy-20261005',
              },
              'server': {'status': 'draft', 'version': 1},
              'dirty': n.isEven,
              'photos': [
                {'id': photo, 'localPath': f.path, 'verified': n == 0},
              ],
              'operations': [
                {
                  'state': ['queued', 'sending', 'done', 'conflict'][n % 4],
                  'body': {
                    'operationId':
                        '20000000-0000-4000-8000-${n.toString().padLeft(12, '0')}',
                    'expectedVersion': 1,
                    'type': n.isEven ? 'parts_validate' : 'registration_close',
                  },
                },
              ],
            }),
          );
        }
      }
      await box.close();
    }
    await Hive.close();
    await Directory('${root.path}/shared_prefs').create();
    await File(
      '${root.path}/shared_prefs/secret.xml',
    ).writeAsString('accessToken=not-for-export');
  });
  tearDown(() async {
    await Hive.close();
    await temp.delete(recursive: true);
  });
  Future<Map<String, String>> originals() async {
    final result = <String, String>{};
    await for (final f in root.list(recursive: true, followLinks: false)) {
      if (f is File) result[f.path] = await fileHash(f);
    }
    return result;
  }

  CabinetBackup exporter({
    Future<void> Function()? gate,
    Future<void> Function()? after,
  }) => CabinetBackup(
    root: root,
    destination: output,
    assertExclusive: gate ?? () async {},
    afterCopy: after,
  );

  test(
    '22 historical snapshots and photos: raw originals unchanged, portable verified bundle, no secrets',
    () async {
      final before = await originals();
      final manifest = await HttpOverrides.runZoned(
        () => exporter().create(),
        createHttpClient: (_) => throw StateError('Unexpected network'),
      );
      expect(manifest['dossiers'], 22);
      expect(manifest['complete'], true);
      expect(await originals(), before);
      final bundle = File('${output.path}/backup.ddr.jsonl');
      expect(await verifyBundle(bundle), manifest);
      expect(await bundle.readAsString(), isNot(contains('not-for-export')));
      expect(maps(manifest['inventory']).first['localValidated'], true);
      expect(maps(manifest['inventory']).first['server'], 'draft');
      expect(maps(manifest['inventory']).first['checklistItems'], 1);
      // Verification is independent of the original device directory.
      await root.rename('${temp.path}/disconnected');
      expect((await verifyBundle(bundle))['dossiers'], 22);
      final extracted = Directory('${temp.path}/independent');
      await extractBundle(bundle, extracted);
      Hive.init('${extracted.path}/app_flutter');
      final copiedBox = await Hive.openBox<String>(
        cabinetBoxes.first,
        crashRecovery: false,
      );
      expect(
        copiedBox.keys.where((k) => '$k'.startsWith('cabinet:')).length,
        22,
      );
      await copiedBox.close();
    },
  );
  test('writer gate aborts before creating destination', () async {
    final before = await originals();
    await expectLater(
      exporter(gate: () async => throw StateError('writer')).create(),
      throwsStateError,
    );
    expect(await output.exists(), false);
    expect(await originals(), before);
  });
  test('mutation during copy aborts without declaring bundle', () async {
    await expectLater(
      exporter(
        after: () async {
          await File(
            '${root.path}/files/cabinets/new.jpg',
          ).writeAsString('concurrent');
        },
      ).create(),
      throwsStateError,
    );
    expect(await File('${output.path}/backup.ddr.jsonl').exists(), false);
  });
  test(
    'missing original remains partial, preserves payload and does not invent close',
    () async {
      final photo = await root
          .list(recursive: true)
          .where((e) => e.path.endsWith('.jpg'))
          .first;
      await photo.delete();
      final before = await originals();
      final m = await exporter().create();
      expect(m['complete'], false);
      expect(await originals(), before);
      expect(m['issues'], isNotEmpty);
    },
  );
  test('secret even in a deleted Hive value aborts export', () async {
    Hive.init('${root.path}/app_flutter');
    final box = await Hive.openBox<String>(cabinetBoxes.first);
    await box.put('unsafe', '{"refreshToken":"private-value"}');
    await box.delete('unsafe');
    await box.close();
    final before = await originals();
    await expectLater(exporter().create(), throwsStateError);
    expect(await originals(), before);
  });
  test('unknown namespace is explicitly partial', () async {
    await File(
      '${root.path}/app_flutter/cabinets_legacy.hive',
    ).writeAsString('unknown');
    final m = await exporter().create();
    expect(m['complete'], false);
  });
  test('corrupt Hive aborts without modifying originals', () async {
    await File(
      '${root.path}/app_flutter/${cabinetBoxes.first}.hive',
    ).writeAsBytes([1, 2, 3, 4, 5, 6, 7]);
    final before = await originals();
    await expectLater(exporter().create(), throwsA(anything));
    expect(await originals(), before);
  });
  test('bundle truncation and altered bytes are rejected', () async {
    await exporter().create();
    final f = File('${output.path}/backup.ddr.jsonl');
    final rows = await f.readAsLines();
    await f.writeAsString(rows.take(rows.length - 1).join('\n'));
    await expectLater(verifyBundle(f), throwsStateError);
    rows[2] = jsonEncode({
      'data': base64Encode([1, 2, 3]),
    });
    await f.writeAsString('${rows.join('\n')}\n');
    await expectLater(verifyBundle(f), throwsStateError);
  });
  test('symlink is rejected, no external file exported', () async {
    await Link(
      '${root.path}/files/cabinets/external',
    ).create('${root.path}/shared_prefs/secret.xml');
    await expectLater(exporter().create(), throwsStateError);
  });
  test(
    'historical incomplete journal and broker receipt preserved without recovery',
    () async {
      Hive.init('${root.path}/app_flutter');
      final box = await Hive.openBox<String>('cabinets_media_journal_v1');
      await box.put(
        'capture',
        jsonEncode({
          'state': 'prepared',
          'sourcePath': '${root.path}/cache/missing.jpg',
        }),
      );
      await box.close();
      final broker = Directory('${root.path}/files/camera_dispatch_v1');
      await broker.create(recursive: true);
      await File('${broker.path}/receipt.json').writeAsString(
        jsonEncode({
          'id': '90000000-0000-4000-8000-000000000001',
          'module': 'cabinets',
          'state': 'PREPARED',
        }),
      );
      await File('${broker.path}/foreign.json').writeAsString(
        jsonEncode({'module': 'hydrostatic', 'private': 'foreign-evidence'}),
      );
      final before = await originals();
      final m = await exporter().create();
      expect(m['complete'], false);
      expect(await originals(), before);
      final paths = maps(m['files']).map((f) => f['path']);
      expect(paths, contains('files/camera_dispatch_v1/receipt.json'));
      expect(paths, isNot(contains('files/camera_dispatch_v1/foreign.json')));
    },
  );
  test(
    'unknown schema preserves raw data but never claims full compatibility',
    () async {
      Hive.init('${root.path}/app_flutter');
      final b = await Hive.openBox<String>(cabinetBoxes.first);
      await b.put('schemaVersion', 'future');
      await b.close();
      final before = await originals();
      final m = await exporter().create();
      expect(m['complete'], false);
      expect(await originals(), before);
    },
  );
  test(
    'declared photo hash mismatch yields partial backup without repairing bytes',
    () async {
      Hive.init('${root.path}/app_flutter');
      final b = await Hive.openBox<String>(cabinetBoxes.first);
      final key = b.keys.firstWhere((k) => '$k'.startsWith('cabinet:'));
      final doc = map(jsonDecode(b.get(key)!));
      (doc['photos'] as List).first['metadata'] = {'clientSha256': '0' * 64};
      await b.put(key, jsonEncode(doc));
      await b.close();
      final before = await originals();
      final m = await exporter().create();
      expect(m['complete'], false);
      expect(await originals(), before);
      expect(
        (m['issues'] as List).any(
          (s) => '$s'.startsWith('declared-photo-hash-mismatch'),
        ),
        true,
      );
    },
  );
  test(
    'evidence references absent from photo list still require original bytes',
    () async {
      Hive.init('${root.path}/app_flutter');
      final b = await Hive.openBox<String>(cabinetBoxes.first);
      final key = b.keys.firstWhere((k) => '$k'.startsWith('cabinet:'));
      final doc = map(jsonDecode(b.get(key)!));
      doc['working']['registrationEvidence'] = [
        {'photoId': '30000000-0000-4000-8000-000000000001'},
      ];
      await b.put(key, jsonEncode(doc));
      await b.close();
      final m = await exporter().create();
      expect(m['complete'], false);
      expect(
        m['issues'],
        contains('original-unverified:30000000-0000-4000-8000-000000000001'),
      );
    },
  );
}
