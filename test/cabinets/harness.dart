import 'dart:async';
import 'package:ddr001_levantamientos/core/location/location_service.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/core/media/photo_capture_service.dart';
import 'package:ddr001_levantamientos/core/network/api_client.dart';
import 'package:ddr001_levantamientos/core/persistence/local_store.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/core/services/app_controller.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_api.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_controller.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_store.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:dio/dio.dart';
import 'package:hive_ce/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

CabinetCatalog fixtureCatalog() => CabinetCatalog(
  object(
    jsonDecode(
      File('test/cabinets/fixtures/catalog-46b0265.json').readAsStringSync(),
    ),
  ),
);

class Sessions implements SessionStore {
  FieldSession? value;
  @override
  Future<void> clear() async {
    value = null;
  }

  @override
  Future<String> installationId() async =>
      value?.installationId ?? const Uuid().v4();
  @override
  Future<FieldSession?> read() async => value;
  @override
  Future<void> save(FieldSession value) async {
    this.value = value;
  }
}

FieldSession testSession({
  String user = '11111111-1111-4111-8111-111111111111',
  SessionKind kind = SessionKind.field,
}) => FieldSession(
  sessionId: const Uuid().v4(),
  userId: user,
  accessToken: 'test',
  refreshToken: 'test',
  installationId: const Uuid().v4(),
  name: 'TEST',
  email: 'test@example.invalid',
  phone: '7777777777',
  kind: kind,
);

class Harness {
  late Directory directory;
  late CabinetStore store;
  late AppController app;
  late CabinetController controller;
  late ApiClient client;
  final sessions = Sessions();
  Future<void> open({
    CabinetRemote? remote,
    FieldSession? session,
    LocationService? locations,
    ConstructionImagePicker? picker,
  }) async {
    directory = await Directory.systemTemp.createTemp('cabinet-mobile-test-');
    Hive.init(directory.path);
    final local = await LocalStore.open();
    store = await CabinetStore.open();
    sessions.value = session ?? testSession();
    final config = AppConfig(
      environment: 'test',
      apiBaseUrl: Uri.parse('http://127.0.0.1:3003/api/v1'),
    );
    client = ApiClient(config: config, sessions: sessions);
    app = AppController(
      config: config,
      local: local,
      locations: locations,
      sessions: sessions,
      api: client,
      packageInfo: PackageInfo(
        appName: 'TEST',
        packageName: 'test',
        version: '1',
        buildNumber: '1',
      ),
    );
    app.session = sessions.value;
    app.online = false;
    setRole(ConstructionRole.resident);
    await store.saveCatalog(fixtureCatalog());
    await store.authorize(app.session!.userId, true);
    controller = CabinetController(
      app: app,
      store: store,
      remote: remote ?? CabinetApi(client),
      camera: PhotoCaptureService(
        local: store.media,
        supportDirectory: () async => directory,
        directoryName: 'cabinets',
        picker: picker,
        representationBuilder: (source, upload, thumb) async {
          await source.copy(upload.path);
          await source.copy(thumb.path);
          return true;
        },
      ),
    );
  }

  void setRole(ConstructionRole role) {
    app.profile = ConstructionProfile(
      userId: app.session!.userId,
      displayName: 'TEST',
      email: 'test@example.invalid',
      phone: '7777777777',
      role: role,
    );
  }

  Future<Json> photo(String id, String context, {File? source}) async {
    final photoId = const Uuid().v4();
    final file = File('${directory.path}/$photoId.jpg');
    if (source != null) {
      await source.copy(file.path);
    } else {
      await file.writeAsBytes([1, 2, 3, 4]);
    }
    final p = <String, dynamic>{
      'id': photoId,
      'actor': controller.actor,
      'localPath': file.path,
      'thumbnailPath': file.path,
      'verified': false,
      'metadata': {
        'photoId': photoId,
        'context': context,
        'clientSha256': await sha256File(file),
        'capturedAt': DateTime.now().toUtc().toIso8601String(),
        'latitude': 20.0,
        'longitude': -103.0,
        'accuracy': 5.0,
      },
    };
    final r = clone(store.read(id)!.json);
    r['photos'] = [...objects(r['photos']), p];
    await store.save(r);
    return p;
  }

  Future<void> sync() async {
    app.online = true;
    await controller.synchronize(force: true);
    while (controller.syncing) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    app.online = false;
  }

  Future<void> close() async {
    controller.dispose();
    app.dispose();
    client.dio.close(force: true);
    await Hive.close();
    await directory.delete(recursive: true);
  }
}

List<Json> evidence(Json p, {bool serial = false}) => [
  {'photoId': p['id'], 'confirmed': true, if (serial) 'legible': true},
];
DioException failure(int status, String code) => DioException(
  requestOptions: RequestOptions(path: '/test'),
  response: Response(
    requestOptions: RequestOptions(path: '/test'),
    statusCode: status,
    data: {'code': code, 'detail': code},
  ),
);

class FakeCabinetRemote implements CabinetRemote {
  final documents = <String, Json>{}, receipts = <String, Json>{};
  final calls = <Json>[];
  final uploads = <String, int>{};
  bool loseNextResponse = false, interruptUpload = false, deny = false;
  String? conflictId;
  String conflictCode = 'VERSION_CONFLICT';
  @override
  Future<Json> get(String path, [Json? query]) async {
    if (deny) throw failure(403, 'CABINET_RESIDENT_REQUIRED');
    if (path == '/catalog') return fixtureCatalog().json;
    if (path == '') return {'items': [], 'total': 0};
    if (path.contains('/operations/')) {
      final result = receipts[path.split('/').last];
      if (result == null) throw failure(404, 'OPERATION_NOT_FOUND');
      return result;
    }
    if (path == '/resolve') throw failure(404, 'CABINET_NOT_FOUND');
    final id = path.substring(1);
    if (documents[id] == null) throw failure(404, 'CABINET_NOT_FOUND');
    return {'cabinet': documents[id]};
  }

  @override
  Future<Json> command(String id, Json body) async {
    if (deny) throw failure(403, 'CABINET_RESIDENT_REQUIRED');
    calls.add(clone(body));
    if (id == conflictId) throw failure(409, conflictCode);
    if (receipts.containsKey(body['operationId'])) {
      return receipts[body['operationId']]!;
    }
    final c = clone(
      documents[id] ??
          {
            'cabinetId': id,
            'uid': body['uid'],
            'model': body['model'],
            'automated': body['automated'],
            'catalogVersion': fixtureCatalog().version,
            'status': 'draft',
            'version': 0,
          },
    );
    if (c['version'] != body['expectedVersion']) {
      throw failure(409, 'VERSION_CONFLICT');
    }
    c['version'] = (c['version'] as int) + 1;
    if (body['type'] == 'registration_close') {
      c['status'] = 'registered';
      c['registrationEvidence'] = body['evidence'];
    }
    if (body['type'] == 'parts_save') c['parts'] = body['parts'];
    if (body['type'] == 'installation_save') {
      c['installation'] = body['installation'];
    }
    documents[id] = c;
    final result = {'cabinet': c};
    receipts[body['operationId']] = result;
    if (loseNextResponse) {
      loseNextResponse = false;
      throw DioException(
        requestOptions: RequestOptions(path: '/test'),
        type: DioExceptionType.receiveTimeout,
      );
    }
    return result;
  }

  @override
  Future<Json> upload(String id, Json photo) async {
    uploads[photo['id']] = (uploads[photo['id']] ?? 0) + 1;
    if (interruptUpload) {
      interruptUpload = false;
      throw DioException(
        requestOptions: RequestOptions(path: '/photo'),
        type: DioExceptionType.sendTimeout,
      );
    }
    return {'storageVerified': true};
  }

  @override
  Future<Json> verify(String id, List<String> ids) async => {
    'items': ids.map((id) => {'photoId': id, 'storageVerified': true}).toList(),
  };
  @override
  Future<Uint8List> content(
    String id,
    String photoId, {
    bool thumbnail = true,
  }) async => Uint8List(0);
}
