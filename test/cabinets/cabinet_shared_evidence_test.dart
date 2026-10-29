import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_controller.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'harness.dart';

class EvidenceRemote extends FakeCabinetRemote {
  final pages = <int>[];
  int reads = 0;
  bool corrupt = false;
  @override
  Future<Json> get(String path, [Json? query]) async {
    if (!path.endsWith('/photos')) return super.get(path, query);
    final page = query!['page'] as int;
    pages.add(page);
    return {
      'items': List.generate(
        page == 1 ? 100 : 1,
        (i) => {
          'photo_id': 'photo-${(page - 1) * 100 + i}',
          'actor_user_id': 'another-resident',
          'server_sha256': sha256.convert([1, 2, 3]).toString(),
          'metadata': {'context': 'registration', 'accuracy': 5},
        },
      ),
    };
  }

  @override
  Future<Uint8List> content(
    String id,
    String photoId, {
    bool thumbnail = true,
  }) async {
    reads++;
    return Uint8List.fromList(corrupt ? [9] : [1, 2, 3]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late EvidenceRemote remote;
  late String id;
  setUp(() async {
    remote = EvidenceRemote();
    h = Harness();
    await h.open(remote: remote);
    id = await h.controller.scan('AQ26000017', 'A1', false);
    await h.sync();
  });
  tearDown(() => h.close());

  test(
    'remote inventory is paginated, readable with foreign pending edits, and never uploaded',
    () async {
      final r = clone(h.store.read(id)!.json);
      r['dirty'] = true;
      r['draftActor'] = 'another-resident';
      r['operations'] = [
        ...objects(r['operations']),
        {
          'state': 'queued',
          'actor': 'another-resident',
          'body': {'type': 'parts_save'},
        },
      ];
      await h.store.save(r);
      final before = jsonEncode(r['operations']);
      await h.controller.downloadEvidence(id);
      expect(remote.pages, [1, 2]);
      expect(remote.reads, 0);
      expect(h.store.read(id)!.photos.length, 101);
      expect(jsonEncode(h.store.read(id)!.json['operations']), before);
      expect(h.store.read(id)!.json['dirty'], true);
      await h.sync();
      expect(remote.uploads, isEmpty);
      expect(
        h.store.read(id)!.photos.every((p) => p['verified'] != true),
        true,
      );
    },
  );

  test(
    'remote inventory is not an unsent photo; original downloads are hash checked and cached',
    () async {
      await h.controller.downloadEvidence(id);
      expect(h.store.read(id)!.synchronized, true);
      final p = h.store.read(id)!.photos.first;
      expect(await h.controller.photoBytes(id, p), [1, 2, 3]);
      expect(await h.controller.photoBytes(id, p), [1, 2, 3]);
      expect(remote.reads, 1);
      expect(await h.controller.photoBytes(id, p, original: true), [1, 2, 3]);
      expect(remote.reads, 2);
      await File(h.store.read(id)!.photos.first['localPath']).delete();
      expect(await h.controller.photoBytes(id, p, original: true), [1, 2, 3]);
      expect(remote.reads, 3);
      remote.corrupt = true;
      await expectLater(
        h.controller.photoBytes(
          id,
          h.store.read(id)!.photos[1],
          original: true,
        ),
        throwsStateError,
      );
      h.setRole(ConstructionRole.contractor);
      await expectLater(h.controller.photoBytes(id, p), throwsStateError);
    },
  );

  test('saving pieces cannot bypass a draft registration', () async {
    await expectLater(
      h.controller.savePartsSide(id, 'district'),
      throwsStateError,
    );
    expect(h.store.read(id)!.pending, isEmpty);
  });

  test('timeouts and HTTP errors retain distinct actionable explanations', () {
    final req = RequestOptions(
      path: '/commands',
      headers: {'X-Request-ID': 'trace', 'Authorization': 'secret'},
    );
    final timeout = DioException(
      requestOptions: req,
      type: DioExceptionType.receiveTimeout,
    );
    expect(CabinetController.explain(timeout), contains('comprobará'));
    expect(
      CabinetController.diagnostic(timeout).toString(),
      isNot(contains('secret')),
    );
    final http = DioException(
      requestOptions: req,
      response: Response(
        requestOptions: req,
        statusCode: 502,
        data: '<html>gateway</html>',
      ),
    );
    expect(CabinetController.explain(http), contains('HTTP 502'));
    expect(CabinetController.explain(http), isNot(contains('CONNECTION')));
    final problem = DioException(
      requestOptions: req,
      response: Response(
        requestOptions: req,
        statusCode: 409,
        data: utf8.encode(
          jsonEncode({
            'code': 'PHOTO_NOT_READY',
            'detail': 'Evidencia pendiente',
            'retryable': true,
          }),
        ),
      ),
    );
    expect(
      CabinetController.explain(problem),
      contains('PHOTO_NOT_READY: Evidencia pendiente'),
    );
    expect(
      CabinetController.problemData(problem.response!.data)['retryable'],
      true,
    );
  });
}
