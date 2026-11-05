// Isolated Android certification only; never imported by the normal entrypoint.
// Reuses the same synthetic backend as the automated controller regression.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'harness.dart';
import 'package:ddr001_levantamientos/core/media/photo_capture_service.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';

class _NoNetwork extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('ANDROID-1: network forbidden');
}

class _Remote extends FakeCabinetRemote {
  Completer<Uint8List>? download;
  @override
  Future<Uint8List> content(
    String id,
    String photoId, {
    bool thumbnail = true,
  }) => download!.future;
}

String _uid(int n) {
  for (var d = 0; d < 10; d++) {
    try {
      return cabinetUid('AQ26${n.toString().padLeft(5, '0')}$d');
    } on FormatException {
      /* Use the application's actual check digit. */
    }
  }
  throw StateError('Synthetic UID invalid');
}

void _check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final info = await PackageInfo.fromPlatform();
  _check(
    kDebugMode &&
        const String.fromEnvironment('APP_ENV') == 'test' &&
        const bool.fromEnvironment('CABINET_DELETION_QA') &&
        info.packageName == 'com.aquafim.ddr001levantamientos.cabinettest',
    'Isolated debug TEST package required',
  );
  HttpOverrides.global = _NoNetwork();
  final support = await getApplicationSupportDirectory();
  final directory = Directory('${support.path}/android1-synthetic');
  final h = Harness();
  final remote = _Remote();
  await h.open(storageDirectory: directory, remote: remote);
  // Restore only the in-memory fake server; never contacts a real endpoint.
  for (final r in h.store.all()) {
    if (r.server.isNotEmpty) remote.documents[r.id] = clone(r.server);
  }
  runApp(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: _Page(h: h, remote: remote, directory: directory),
    ),
  );
}

class _Page extends StatefulWidget {
  const _Page({required this.h, required this.remote, required this.directory});
  final Harness h;
  final _Remote remote;
  final Directory directory;
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> {
  final results = <String>[];
  bool busy = false;
  String? error;
  Harness get h => widget.h;
  _Remote get remote => widget.remote;
  File get checkpoint =>
      File('${widget.directory.path}/android1-checkpoint.json');
  File get report => File('${widget.directory.path}/android1-results.json');
  final png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j9ZkAAAAASUVORK5CYII=',
  );
  @override
  void initState() {
    super.initState();
    if (report.existsSync()) {
      results.addAll(
        (jsonDecode(report.readAsStringSync())['results'] as List)
            .cast<String>(),
      );
    }
  }

  Future<void> log(String s) async {
    results.add(s);
    await report.writeAsString(
      jsonEncode({
        'results': results,
        'error': error,
        'synthetic': true,
        'network': 'disabled',
        'at': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
    debugPrint('ANDROID1 $s');
    if (mounted) setState(() {});
  }

  Future<String> clean(int n) async {
    final id = await h.controller.scan(_uid(n), 'A1', false);
    await h.sync();
    remote.documents[id]!['status'] = 'registered';
    await h.controller.pull(id);
    _check(h.store.read(id)!.pending.isEmpty, 'Fixture not synchronized');
    return id;
  }

  Future<void> blocked(String id, String uid, String expected) async {
    try {
      await h.controller.deleteLocalRegistration(id, uid);
    } on StateError catch (e) {
      _check(e.toString().contains(expected), 'Unexpected blocker: $e');
      await log('Mensaje: ${e.message}');
      return;
    }
    throw StateError('Expected local deletion to be blocked');
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e, st) {
      error = '$e';
      debugPrint('$e\n$st');
      await log('FAIL: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> firstFive() async {
    _check(
      !await checkpoint.exists(),
      'Checkpoint exists; preserve it and run test 6',
    );
    final b = await clean(99992);
    final source = File('${widget.directory.path}/synthetic.png');
    await source.writeAsBytes(png, flush: true);
    final photoB = await h.photo(b, 'registration', source: source);
    await h.sync();
    final bBefore = jsonEncode(h.store.read(b)!.json);
    final bHash = await sha256File(File('${photoB['localPath']}'));
    var a = await clean(99991);
    await h.controller.deleteLocalRegistration(a, _uid(99991));
    _check(
      h.store.read(a) == null && jsonEncode(h.store.read(b)!.json) == bBefore,
      'Test 1 local isolation failed',
    );
    _check(remote.documents.containsKey(a), 'Fake remote was deleted');
    await log('1 PASS — copia local retirada; B y servidor simulado intactos');

    a = await clean(99991);
    remote.download = Completer();
    final otherLoad = h.controller.photoBytes(b, {
      'id': 'qa-other',
      'remote': true,
    });
    _check(!remote.download!.isCompleted, 'Download must remain active');
    await h.controller.deleteLocalRegistration(a, _uid(99991));
    _check(h.store.read(a) == null, 'Other dossier blocked deletion');
    remote.download!.complete(Uint8List.fromList(png));
    await otherLoad;
    _check(
      jsonEncode(h.store.read(b)!.json) == bBefore &&
          await sha256File(File('${photoB['localPath']}')) == bHash,
      'B changed',
    );
    await log('2 PASS — descarga de B no bloquea A; foto B íntegra');

    a = await clean(99991);
    remote.download = Completer();
    final ownLoad = h.controller.photoBytes(a, {
      'id': 'qa-own',
      'remote': true,
    });
    final before = jsonEncode(h.store.read(a)!.json);
    await blocked(a, _uid(99991), 'fotografías de este gabinete');
    _check(
      jsonEncode(h.store.read(a)!.json) == before,
      'Blocked dossier changed',
    );
    await log('3 PASS — operación propia bloquea sin pérdida');
    remote.download!.complete(Uint8List.fromList(png));
    await ownLoad;
    await h.controller.deleteLocalRegistration(a, _uid(99991));
    _check(h.store.read(a) == null, 'Completed operation remained locked');
    await log('4 PASS — operación completada libera bloqueo');

    final probe = await clean(99994);
    final pending = await h.controller.scan(_uid(99993), 'A2', false);
    final photoPending = await h.photo(pending, 'registration', source: source);
    final pendingBefore = jsonEncode(h.store.read(pending)!.json);
    final pendingHash = await sha256File(File('${photoPending['localPath']}'));
    await blocked(pending, _uid(99993), 'pendientes de sincronización');
    _check(
      jsonEncode(h.store.read(pending)!.json) == pendingBefore &&
          await sha256File(File('${photoPending['localPath']}')) == pendingHash,
      'Pending work lost',
    );
    await log('5 PASS — documento, cola y foto pendientes conservados');
    await checkpoint.writeAsString(
      jsonEncode({
        'b': b,
        'bBefore': bBefore,
        'bPhoto': photoB['localPath'],
        'bHash': bHash,
        'pending': pending,
        'pendingBefore': pendingBefore,
        'pendingPhoto': photoPending['localPath'],
        'pendingHash': pendingHash,
        'probe': probe,
      }),
      flush: true,
    );
    // Deliberately leave an in-memory load active before the QA-only process stop.
    remote.download = Completer();
    unawaited(
      h.controller.photoBytes(probe, {'id': 'restart-probe', 'remote': true}),
    );
    await log(
      'REINICIO PREPARADO — cerrar sólo este paquete QA y volver a abrir',
    );
  }

  Future<void> afterRestart() async {
    _check(await checkpoint.exists(), 'Run tests 1–5 first');
    final c = object(jsonDecode(await checkpoint.readAsString()));
    _check(
      jsonEncode(h.store.read(c['pending'])!.json) == c['pendingBefore'],
      'Pending document changed',
    );
    _check(
      await sha256File(File(c['pendingPhoto'])) == c['pendingHash'],
      'Pending photo changed',
    );
    _check(
      jsonEncode(h.store.read(c['b'])!.json) == c['bBefore'] &&
          await sha256File(File(c['bPhoto'])) == c['bHash'],
      'B changed after restart',
    );
    await blocked(c['pending'], _uid(99993), 'pendientes de sincronización');
    await h.controller.deleteLocalRegistration(c['probe'], _uid(99994));
    _check(h.store.read(c['probe']) == null, 'Transient lock persisted');
    await log(
      '6 PASS — reinicio real conserva pendientes y libera bloqueo temporal',
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('ANDROID-1 · GABINETES QA')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'SÓLO DATOS SINTÉTICOS · SIN INTERNET',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const Text(
            'Controlador real + Hive privado Android + servidor simulado. No utiliza expedientes operativos.',
          ),
          FilledButton(
            onPressed: busy ? null : () => run(firstFive),
            child: const Text('EJECUTAR PRUEBAS 1–5'),
          ),
          OutlinedButton(
            onPressed: busy ? null : () => run(afterRestart),
            child: const Text('VERIFICAR REINICIO · PRUEBA 6'),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
          for (final r in results)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(r),
            ),
        ],
      ),
    ),
  );
}
