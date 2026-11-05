import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'harness.dart';

class DeletionRemote extends FakeCabinetRemote {
  bool loseResponse = false;
  bool conflict = false;
  final deletionReceipts = <String, Json>{};
  final deletionCalls = <Json>[];
  @override
  Future<Json> get(String path, [Json? query]) async {
    if (path == '/catalog') {
      return {
        ...fixtureCatalog().json,
        'capabilities': {'permanentDeletion': true},
      };
    }
    return super.get(path, query);
  }

  @override
  Future<Json> deleteCabinet(String id, Json body) async {
    deletionCalls.add(clone(body));
    if (conflict) {
      throw DioException(
        requestOptions: RequestOptions(path: id),
        response: Response(
          requestOptions: RequestOptions(path: id),
          statusCode: 409,
          data: {'code': 'VERSION_CONFLICT', 'detail': 'Refresh first'},
        ),
      );
    }
    final result = deletionReceipts.putIfAbsent(
      body['operationId'],
      () => {
        'cabinetId': id,
        'operationId': body['operationId'],
        'deleted': true,
      },
    );
    documents.remove(id);
    if (loseResponse) {
      loseResponse = false;
      throw DioException(
        requestOptions: RequestOptions(path: id),
        type: DioExceptionType.receiveTimeout,
      );
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late DeletionRemote remote;
  setUp(() async {
    remote = DeletionRemote();
    h = Harness();
    await h.open(remote: remote);
  });
  tearDown(() async => h.close());
  test(
    'local deletion removes only matching dossier and media without API calls',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      final other = await h.controller.scan('AQ26000025', 'A2', false);
      final folder = Directory('${h.directory.path}/cabinets/$id');
      await folder.create(recursive: true);
      final photo = File('${folder.path}/original.jpg');
      await photo.writeAsString('local-only');
      await h.store.media.metadataBox.put('target', '{"surveyId":"$id"}');
      await h.store.media.metadataBox.put('other', '{"surveyId":"$other"}');
      await expectLater(
        h.controller.deleteLocalRegistration(id, 'AQ26000025'),
        throwsStateError,
      );
      expect(h.store.read(id), isNotNull);
      await h.controller.deleteLocalRegistration(id, 'AQ26000017');
      expect(h.store.read(id), isNull);
      expect(h.store.read(other), isNotNull);
      expect(await photo.exists(), isFalse);
      expect(h.store.media.metadataBox.get('target'), isNull);
      expect(h.store.media.metadataBox.get('other'), isNotNull);
      expect(remote.deletionCalls, isEmpty);
      expect(remote.calls, isEmpty);
    },
  );

  test(
    'confirmed remote absence allows only the original actor to discard locally',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      final other = await h.controller.scan('AQ26000025', 'A2', false);
      final preserved = clone(h.store.read(other)!.json);
      final folder = Directory('${h.directory.path}/cabinets/$id');
      await folder.create(recursive: true);
      await File('${folder.path}/photo.jpg').writeAsString('pending photo');
      final row = clone(h.store.read(id)!.json);
      for (final code in [
        'VERSION_CONFLICT',
        'ARCHIVE_UNAVAILABLE',
        'HTTP_404',
        null,
      ]) {
        row['deletion'] = {'actor': h.controller.actor, 'code': code};
        await h.store.save(row);
        await expectLater(
          h.controller.deleteLocalRegistration(id, 'AQ26000017'),
          throwsStateError,
        );
        expect(h.store.read(id), isNotNull);
        expect(await folder.exists(), isTrue);
      }
      row['deletion'] = {
        'actor': 'another-resident',
        'code': 'CABINET_NOT_FOUND',
      };
      await h.store.save(row);
      await expectLater(
        h.controller.deleteLocalRegistration(id, 'AQ26000017'),
        throwsStateError,
      );
      row['deletion'] = {
        'actor': h.controller.actor,
        'code': 'CABINET_NOT_FOUND',
      };
      await h.store.save(row);
      await expectLater(
        h.controller.saveDraft(id, 'model', 'A3'),
        throwsStateError,
      );
      await expectLater(
        h.controller.deleteLocalRegistration(id, 'AQ26000025'),
        throwsStateError,
      );
      await h.controller.deleteLocalRegistration(id, 'AQ26000017');
      expect(h.store.read(id), isNull);
      expect(await folder.exists(), isFalse);
      expect(h.store.read(other)!.json, preserved);
      expect(remote.deletionCalls, isEmpty);
      expect(remote.calls, isEmpty);
    },
  );

  test(
    'permanent deletion clears only confirmed dossier, permits rescan with new UUID',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      await h.sync();
      final folder = Directory('${h.directory.path}/cabinets/$id');
      await folder.create(recursive: true);
      final photo = File('${folder.path}/original.jpg');
      await photo.writeAsString('photo');
      await h.app.local.metadataBox.put('field-data', 'preserved');
      await h.controller.deleteRegistration(id, 'AQ26-00001-7');
      expect(h.store.read(id), isNull);
      expect(await photo.exists(), isFalse);
      expect(h.app.local.metadataBox.get('field-data'), 'preserved');
      final replacement = await h.controller.scan('AQ26000017', 'A2', true);
      expect(replacement, isNot(id));
      expect(h.store.read(replacement)!.working['uid'], 'AQ26000017');
    },
  );
  test(
    'lost deletion response preserves bytes and journal until receipt replay',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      await h.sync();
      final folder = Directory('${h.directory.path}/cabinets/$id');
      await folder.create(recursive: true);
      final photo = File('${folder.path}/original.jpg');
      await photo.writeAsString('photo');
      remote.loseResponse = true;
      await expectLater(
        h.controller.deleteRegistration(id, 'AQ26000017'),
        throwsStateError,
      );
      expect(h.store.read(id)!.json['deletion'], isNotNull);
      expect(await photo.exists(), isTrue);
      await expectLater(
        h.controller.saveDraft(id, 'model', 'A2'),
        throwsStateError,
      );
      await h.sync();
      expect(h.store.read(id), isNull);
      expect(await photo.exists(), isFalse);
      expect(remote.deletionCalls[0], remote.deletionCalls[1]);
    },
  );
  test(
    'version rejection keeps data and allows explicit cancellation',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      await h.sync();
      remote.conflict = true;
      await expectLater(
        h.controller.deleteRegistration(id, 'AQ26000017'),
        throwsStateError,
      );
      expect(h.store.read(id)!.json['deletion']['code'], 'VERSION_CONFLICT');
      await h.sync();
      expect(remote.deletionCalls.length, 1);
      await h.controller.cancelRejectedDeletion(id);
      expect(h.store.read(id)!.json['deletion'], isNull);
    },
  );
  test('wrong UID and installed dossier never issue deletion', () async {
    final id = await h.controller.scan('AQ26000017', 'A1', false);
    await h.sync();
    await expectLater(
      h.controller.deleteRegistration(id, 'AQ26000025'),
      throwsA(anything),
    );
    await h.controller.saveDraft(id, 'installation', {'baseId': 'a-base'});
    await expectLater(
      h.controller.deleteRegistration(id, 'AQ26000017'),
      throwsStateError,
    );
    expect(remote.deletionCalls, isEmpty);
    expect(h.store.read(id), isNotNull);
  });
}
