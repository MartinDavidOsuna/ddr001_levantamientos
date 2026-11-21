// HAPI-3.2 only: real HTTP + real Hive in an isolated Android TEST package.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/core/network/api_client.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_sync_runner.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_repository.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_store.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync_api.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync_store.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';

String uuid() => const Uuid().v4();
void check(bool v, String why) {
  if (!v) throw StateError(why);
}

class QaClock implements HydrostaticClock {
  DateTime utc = DateTime.now().toUtc().subtract(const Duration(hours: 2));
  int ticks = 0;
  final run = uuid();
  void advance(int ms) {
    utc = utc.add(Duration(milliseconds: ms));
    ticks += ms;
  }

  @override
  HydrostaticClockReading now() => HydrostaticClockReading(utc, run, ticks);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final info = await PackageInfo.fromPlatform();
  check(
    kDebugMode &&
        info.packageName == 'com.aquafim.ddr001levantamientos.hydrosyncqa' &&
        const String.fromEnvironment('APP_ENV') == 'test' &&
        const bool.fromEnvironment('HYDROSTATIC_SYNC_ENABLED'),
    'Isolated TEST build required',
  );
  final root = await getApplicationSupportDirectory();
  final qa = Qa(root);
  await qa.open();
  runApp(MaterialApp(theme: ThemeData(useMaterial3: true), home: QaPage(qa)));
}

class Qa {
  Qa(this.root);
  final Directory root;
  final sessions = SecureSessionStore();
  late ApiClient api;
  late HydrostaticSyncApi remote;
  late HydrostaticStore store;
  late HydrostaticSyncStore outbox;
  late HydrostaticRepository repo;
  late HydrostaticSync sync;
  HydrostaticSyncRunner? runner;
  final clock = QaClock();
  late HydroJson fixtures;
  HydroJson state = {};
  FieldSession? session;
  bool online = true;
  String? dropFor;
  final trace = <HydroJson>[];
  final results = <String>[];
  File get file => File('${root.path}/hapi32-state.json');
  HydrostaticActorSnapshot get actor => HydrostaticActorSnapshot(
    userId: session!.userId,
    name: session!.name,
    sessionId: session!.sessionId,
    deviceInstallationId: session!.installationId,
  );
  HydrostaticAccess access() =>
      HydrostaticAccess(actor: actor, authorized: true, fieldSession: true);
  HydrostaticSyncIdentity? identity() => session == null
      ? null
      : HydrostaticSyncIdentity(
          session!.userId,
          session!.sessionId,
          session!.installationId,
        );
  Future<void> open() async {
    fixtures = hydroObject(
      jsonDecode(
        await File('${root.path}/hapi32-fixtures.json').readAsString(),
      ),
    );
    if (await file.exists()) {
      state = hydroObject(jsonDecode(await file.readAsString()));
      results.addAll((state['results'] as List).cast<String>());
      trace.addAll((state['trace'] as List? ?? []).map(hydroObject));
    }
    session = await sessions.read();
    api = ApiClient(
      config: AppConfig(
        environment: 'test',
        apiBaseUrl: Uri.parse('http://127.0.0.1:3002/api/v1'),
      ),
      sessions: sessions,
    );
    api.dio.options.connectTimeout = const Duration(seconds: 4);
    api.dio.options.receiveTimeout = const Duration(seconds: 15);
    api.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          if (o.uri.host != '127.0.0.1' || o.uri.port != 3002) {
            h.reject(DioException(requestOptions: o, error: 'QA host refused'));
            return;
          }
          if (o.path.endsWith('/commands')) {
            final d = hydroObject(o.data);
            trace.add({
              'kind': 'request',
              'path': o.path,
              'operationId': d['operationId'],
              'type': d['type'],
              'payloadSha256': d['payloadSha256'],
              'expectedVersion': d['expectedVersion'],
            });
          }
          h.next(o);
        },
        onResponse: (r, h) {
          trace.add({
            'kind': 'response',
            'path': r.requestOptions.path,
            'status': r.statusCode,
          });
          if (dropFor != null &&
              r.requestOptions.path ==
                  '${HydrostaticSyncApi.root}/$dropFor/commands') {
            dropFor = null;
            h.reject(
              DioException(
                requestOptions: r.requestOptions,
                type: DioExceptionType.receiveTimeout,
                error: 'QA discarded real COMMITTED response',
              ),
            );
            return;
          }
          h.next(r);
        },
      ),
    );
    remote = HydrostaticSyncApi(api);
    store = await HydrostaticStore.open(
      Directory('${root.path}/hydrostatic/db'),
    );
    outbox = await HydrostaticSyncStore.open(
      Directory('${root.path}/hydrostatic/db'),
    );
    repo = HydrostaticRepository(
      store: store,
      clock: clock,
      access: access,
      files: LocalHydrostaticEvidenceFiles(root),
    );
    sync = HydrostaticSync(
      repository: repo,
      store: outbox,
      remote: remote,
      identity: identity,
      verifySession: () async {
        check(
          (await sessions.read())?.sessionId == session?.sessionId,
          'Session changed',
        );
      },
      online: () => online,
      enabled: true,
      jitter: () => 0,
    );
    if (session != null) {
      await repo.recover();
    }
  }

  Future<void> save() async {
    state['results'] = results;
    state['trace'] = trace;
    await file.writeAsString(jsonEncode(state), flush: true);
  }

  Future<void> pass(String s) async {
    results.add(s);
    debugPrint('HAPI32 $s');
    await save();
  }

  Future<FieldSession> login(int index, {String? installation}) async {
    final u = hydroObject(fixtures['users'][index]);
    final install = installation ?? await sessions.installationId();
    final r = await api.dio.post(
      '/field-sessions/start',
      options: Options(extra: {'skipAuth': true}),
      data: {
        'name': u['name'],
        'email': u['email'],
        'phone': u['phone'],
        'crew': fixtures['crew'],
        'client_app': 'ddr001_levantamientos',
        'device': {
          'installationId': install,
          'platform': 'android',
          'manufacturer': 'Google',
          'model': 'HAPI32 SYNTHETIC Pixel',
          'androidVersion': '17',
          'appVersion': '1.5.24-qa.hapi32',
        },
      },
    );
    final d = hydroObject(r.data);
    final next = FieldSession.fromJson({
      ...d,
      'installationId': install,
      'name': u['name'],
      'email': u['email'],
      'phone': u['phone'],
      'crew': fixtures['crew'],
      'kind': 'field',
    });
    await sessions.save(next);
    session = next;
    return next;
  }

  HydrostaticCabinetSnapshot get cabinet =>
      HydrostaticCabinetSnapshot.fromJson(hydroObject(fixtures['cabinet']));
  HydrostaticLocation location() => HydrostaticLocation(
    latitude: 0,
    longitude: 0,
    accuracy: 5,
    fixAt: clock.utc,
    acquiredAt: clock.utc,
    source: 'HAPI32_SYNTHETIC_NOT_FIELD',
  );
  Future<void> photo(String id, HydrostaticEvidenceRole role) async {
    final photoId = uuid(), relative = 'hydrostatic/$id/evidence/$photoId.png';
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawColor(
      Color(0xff000000 | int.parse(photoId.substring(0, 6), radix: 16)),
      BlendMode.src,
    );
    final pic = recorder.endRecording();
    final im = await pic.toImage(16, 16);
    final data = (await im.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    im.dispose();
    pic.dispose();
    final f = File('${root.path}/$relative');
    await f.parent.create(recursive: true);
    await f.writeAsBytes(data, flush: true);
    await repo.addEvidence(
      id,
      uuid(),
      HydrostaticEvidence(
        id: photoId,
        testId: id,
        captureIntentId: uuid(),
        actorId: actor.userId,
        role: role,
        originalPath: relative,
        sha256: sha256.convert(data).toString(),
        byteLength: data.length,
        capturedAt: clock.utc,
        timeSource: HydrostaticCaptureTimeSource.cameraMetadata,
        location: location(),
        state: HydrostaticEvidenceState.ready,
        integrity: HydrostaticIntegrity.verified,
      ),
    );
  }

  Future<String> make(String label, {String result = 'PASS'}) async {
    final id = uuid();
    state[label] = id;
    await save();
    await repo.prepare(operationId: uuid(), testId: id, cabinet: cabinet);
    await photo(id, HydrostaticEvidenceRole.initialSetup);
    await repo.requestStart(id, uuid());
    await repo.start(id, uuid(), location());
    clock.advance(10000);
    if (result == 'PASS') {
      await photo(id, HydrostaticEvidenceRole.manometer5Bar);
    }
    clock.advance(1000);
    await repo.finish(id, uuid());
    if (result == 'DISCARD') {
      clock.advance(1800001);
      await repo.discardExpired(id, uuid());
    } else if (result == 'LEAK') {
      await repo.answerLeaks(id, uuid(), true);
      await repo.saveLeakDraft(id, uuid(), {
        'version': 1,
        'observation': 'HAPI32 SYNTHETIC',
        'joints': {
          'J01': {'selected': true, 'pressure': '2.345', 'description': ''},
        },
      });
      await photo(id, HydrostaticEvidenceRole.leakEvidence);
      await repo.closeLeak(id, uuid());
    } else {
      await repo.answerLeaks(id, uuid(), false);
      clock.advance(1000);
      await photo(id, HydrostaticEvidenceRole.final4Bar);
      await repo.closePass(id, uuid());
    }
    return id;
  }

  HydroJson row(String id) => outbox.read(id)!;
  Future<void> acknowledged(String id) async {
    check(
      row(id)['active'] == null && row(id)['serverVersion'] > 0,
      'Missing ACK $id: ${row(id)['active']?['state']} ${row(id)['active']?['errorCode']} ${sync.error}',
    );
    final status = await remote.status(id, repo.get(id)!.revision, identity()!);
    state['status:$id'] = status;
    state['receipt:$id'] = row(id)['receipts'];
    check(status['fullyReconciled'] == false, 'Photos must remain pending');
    await save();
  }

  Future<void> first() async {
    // Retry resumes the same durable UUIDs and frozen outbox commands.
    await login(0);
    final caps = await remote.capabilities(identity()!);
    check(
      caps['contractVersion'] == 'hydrostatic-sync-v1' &&
          (caps['joints'] as List).length == 11,
      'Capabilities mismatch',
    );
    state['capabilities'] = caps;
    state['identity'] = {
      'actor': actor.userId,
      'session': actor.sessionId,
      'installation': actor.deviceInstallationId,
    };
    await pass('T1 PASS: Flutter HTTP real, capabilities TEST y catálogo');
    if (state['A'] == null) {
      final cat = hydroObject(
        (await api.dio.get('/construction/cabinets/catalog')).data,
      );
      final op = uuid();
      await api.dio.post(
        '/construction/cabinets/${cabinet.cabinetId}/commands',
        options: Options(headers: {'Idempotency-Key': op}),
        data: {
          'type': 'register',
          'operationId': op,
          'expectedVersion': 0,
          'capturedAt': DateTime.now().toUtc().toIso8601String(),
          'uid': cabinet.uid,
          'model': 'A1',
          'automated': false,
          'catalogVersion': cat['version'],
          'expectedCrewId': session!.crewId,
        },
      );
    }
    final a = state['A'] as String? ?? await make('A');
    if (!results.any((r) => r.startsWith('T5 PASS'))) {
      await sync.run(manual: true);
      await acknowledged(a);
      await pass('T2 PASS: APROBADO registrado con recibo COMMITTED HTTP');
      final first = hydroObject((row(a)['receipts'] as List).first);
      final replay = await remote.command(
        a,
        hydroObject(first['command']),
        identity()!,
      );
      check(
        replay['committedAt'] == first['receipt']['committedAt'] &&
            replay['replayed'] == true,
        'Replay mismatch',
      );
      state['replay'] = replay;
      await pass('T3 PASS: replay exacto devuelve recibo original');
      final d = await make('D');
      dropFor = d;
      await sync.run(manual: true);
      check(
        row(d)['active']['state'] == 'SENT_UNKNOWN',
        'Lost response not durable',
      );
      state['lostCommand'] = row(d)['active']['command'];
      await save();
      await sync.run(manual: true);
      await acknowledged(d);
      check(
        row(d)['receipts'][0]['command']['operationId'] ==
            state['lostCommand']['operationId'],
        'Recovered new operation',
      );
      await pass(
        'T4 PASS: respuesta real descartada tras COMMIT, recibo recuperado por GET',
      );
      await repo.declareVideoSent(d, uuid());
      await sync.run(manual: true);
      await acknowledged(d);
      check(row(d)['serverVersion'] == 2, 'UPDATE version incorrect');
      await pass('T5 PASS: UPDATE_DOCUMENT durable y versión 2');
    }
    if (!results.any((r) => r.startsWith('T7 PASS'))) {
      final b = state['B'] as String? ?? await make('B', result: 'LEAK');
      if (repo.get(b)!.state == HydrostaticTestState.leakDetailsPending) {
        await repo.saveLeakDraft(b, uuid(), {
          'version': 1,
          'observation': 'HAPI32 SYNTHETIC',
          'joints': {
            'J01': {'selected': true, 'pressure': '2.345', 'description': ''},
          },
        });
        await photo(b, HydrostaticEvidenceRole.leakEvidence);
        await repo.closeLeak(b, uuid());
      }
      await sync.run(manual: true);
      await acknowledged(b);
      await pass('T6 PASS: FUGA J01 a 2.345 bar declarada; fotos pendientes');
      final c = await make('C', result: 'DISCARD');
      await sync.run(manual: true);
      await acknowledged(c);
      check(repo.get(c)!.toJson()['discardedAt'] != null, 'Discard changed');
      await pass('T7 PASS: DESCARTADA preservada, sin convertir en FUGA');
    }
    if (!results.any((r) => r.startsWith('T10 PASS'))) {
      final original = session!;
      await login(1, installation: uuid());
      check(
        repo.forUser().isEmpty && sync.view(a) == null,
        'Other actor can see data',
      );
      final requests = trace.where((x) => x['kind'] == 'request').length;
      await sync.run(manual: true);
      check(
        trace.where((x) => x['kind'] == 'request').length == requests,
        'Other actor sent old data',
      );
      try {
        await remote.status(a, 0, identity()!);
        throw StateError('IDOR');
      } on HydrostaticSyncFailure catch (e) {
        check(e.status == 404, 'Expected owner 404');
      }
      session = original;
      await sessions.save(original);
      await pass(
        'T10 PASS: segunda identidad TEST no ve ni transmite expedientes ajenos',
      );
    }
    final conflictId = uuid();
    state['CONFLICT'] = conflictId;
    await save();
    await repo.prepare(
      operationId: uuid(),
      testId: conflictId,
      cabinet: cabinet,
    );
    await sync.run(manual: true);
    await acknowledged(conflictId);
    final first = hydroObject((row(conflictId)['receipts'] as List).first);
    // Controlled second writer, same authorized owner; sends real HTTP, never SQL JSON.
    final originalCommand = hydroObject(first['command']);
    final payload = hydroObject(jsonDecode(originalCommand['payloadJson']));
    final document = hydroObject(payload['document']);
    document['revision'] = (document['revision'] as int) + 1;
    document['qaConcurrentWriter'] = 'HAPI32 synthetic';
    payload['document'] = document;
    payload['baseSourceRevision'] = first['receipt']['acceptedSourceRevision'];
    payload['baseSourceHash'] = first['receipt']['acceptedSourceHash'];
    final bytes = canonicalHydroJson(payload);
    final concurrent = {
      ...originalCommand,
      'operationId': uuid(),
      'type': 'UPDATE_DOCUMENT',
      'expectedVersion': 1,
      'payloadJson': bytes,
      'payloadSha256': hydroSyncHash(bytes),
      'clientCreatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    state['concurrent'] = await remote.command(
      conflictId,
      concurrent,
      identity()!,
    );
    await photo(conflictId, HydrostaticEvidenceRole.initialSetup);
    final before = canonicalHydroJson(repo.get(conflictId)!.toJson());
    await sync.run(manual: true);
    check(
      row(conflictId)['active']['state'] == 'CONFLICT' &&
          canonicalHydroJson(repo.get(conflictId)!.toJson()) == before,
      'Conflict overwrote source',
    );
    state['conflict'] = row(conflictId)['active'];
    await pass('T11 PASS: 409 preserva fuente y comando, sin last-write-wins');
    // Offline scenario is explicitly separate: remove only this ADB reverse first.
    final offline = await make('OFFLINE');
    online = false;
    await sync.run();
    online = true;
    state['offlineCommand'] = row(offline)['active']['command'];
    state['hashes'] = {
      for (final t in repo.forUser())
        for (final e in t.evidence) e.originalPath: e.sha256,
    };
    await save();
    await pass('PREPARADO: quitar reverse QA y pulsar PRUEBA SIN RED');
  }

  Future<void> offline() async {
    await sync.run(manual: true);
    final id = state['OFFLINE'] as String;
    check(
      row(id)['active'] != null &&
          canonicalHydroJson(row(id)['active']['command']) ==
              canonicalHydroJson(state['offlineCommand']),
      'Offline command changed',
    );
    check(sync.error != null, 'Network must be interrupted for this case');
    await pass('T8 PASS: HTTP sin conexión conserva outbox y fingerprint');
  }

  Future<void> restart() async {
    final id = state['OFFLINE'] as String;
    check(
      row(id)['active'] != null &&
          canonicalHydroJson(row(id)['active']['command']) ==
              canonicalHydroJson(state['offlineCommand']),
      'Restart lost outbox',
    );
    runner = HydrostaticSyncRunner(sync)..start();
    for (var n = 0; n < 60 && row(id)['active'] != null; n++) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    await acknowledged(id);
    runner!.dispose();
    runner = null;
    check(
      row(state['CONFLICT'])['active']['state'] == 'CONFLICT',
      'Conflict was silently discarded',
    );
    await pass(
      'T9 PASS: proceso nuevo recupera Hive y envío automático sin duplicados',
    );
    for (final e in hydroObject(state['hashes']).entries) {
      check(
        sha256
                .convert(await File('${root.path}/${e.key}').readAsBytes())
                .toString() ==
            e.value,
        'Photo lost or altered',
      );
    }
    await pass('T12 PASS: originales SHA-256 intactos; ningún binario enviado');
  }
}

class QaPage extends StatefulWidget {
  const QaPage(this.qa, {super.key});
  final Qa qa;
  @override
  State<QaPage> createState() => _QaPageState();
}

class _QaPageState extends State<QaPage> {
  bool busy = false;
  String? error;
  Future<void> run(Future<void> Function() f) async {
    setState(() => busy = true);
    try {
      await f();
    } catch (e) {
      error = e is DioException
          ? 'HTTP ${e.response?.statusCode}: ${e.response?.data is Map ? e.response?.data['code'] : e.type.name}'
          : e.toString();
      debugPrint('HAPI32 ERROR $error');
      widget.qa.state['lastError'] = error;
      await widget.qa.save();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('HAPI-3.2 · HTTP / SQL TEST')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('SINTÉTICO · localhost:3002 · sandbox independiente'),
        FilledButton(
          onPressed: busy ? null : () => run(widget.qa.first),
          child: const Text('T1–T7 / T10–T11'),
        ),
        OutlinedButton(
          onPressed: busy ? null : () => run(widget.qa.offline),
          child: const Text('T8 · PRUEBA SIN RED'),
        ),
        OutlinedButton(
          onPressed: busy ? null : () => run(widget.qa.restart),
          child: const Text('T9 / T12 · DESPUÉS DE REINICIO'),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        for (final s in widget.qa.results)
          Padding(padding: const EdgeInsets.all(4), child: Text(s)),
      ],
    ),
  );
}
