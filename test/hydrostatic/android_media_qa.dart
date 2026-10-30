// Explicit TEST-only physical certification. Does not import operational records.
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_media_sync.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_media_store.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'android_sync_qa.dart' as old;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  old.check(
    kDebugMode &&
        (await PackageInfo.fromPlatform()).packageName ==
            'com.aquafim.ddr001levantamientos.hydrosyncqa' &&
        const String.fromEnvironment('APP_ENV') == 'test',
    'QA only',
  );
  final support = await getApplicationSupportDirectory();
  final root = Directory('${support.path}/hapi4');
  await root.create(recursive: true);
  final q = MediaQa(root);
  await q.open();
  runApp(MaterialApp(home: old.QaPage(q)));
}

class MediaQa extends old.Qa {
  MediaQa(super.root);
  late HydrostaticMediaSync media;
  late HydrostaticMediaStore transfers;
  String? dropEvidence;
  @override
  Future<void> open() async {
    await super.open();
    transfers = await HydrostaticMediaStore.open(
      Directory('${root.path}/hydrostatic/db'),
    );
    media = HydrostaticMediaSync(
      documents: sync,
      store: transfers,
      remote: HydrostaticMediaApi(api),
      support: root,
    );
    sync.media = media;
    api.dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (r, h) {
          if (dropEvidence != null &&
              r.requestOptions.path.endsWith('/$dropEvidence/content')) {
            dropEvidence = null;
            h.reject(
              DioException(
                requestOptions: r.requestOptions,
                type: DioExceptionType.receiveTimeout,
                error: 'HAPI4 dropped committed photo response',
              ),
            );
            return;
          }
          h.next(r);
        },
      ),
    );
  }

  @override
  Future<void> first() async {
    await login(0);
    if (state['cabinetRegistered'] != true) {
      final cat = hydroObject(
        (await api.dio.get('/construction/cabinets/catalog')).data,
      );
      final op = old.uuid();
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
      state['cabinetRegistered'] = true;
      await save();
    }
    final a = state['A'] as String? ?? await make('A');
    final b = state['B'] as String? ?? await make('B', result: 'LEAK');
    final lost = repo.get(a)!.evidence.first;
    if (state['lostInjected'] != true) {
      dropEvidence = lost.id;
      state['lostInjected'] = true;
      await save();
    }
    await sync.run(manual: true);
    await sync.run(manual: true);
    for (final id in [a, b]) {
      await acknowledged(id);
      for (final e in repo.get(id)!.evidence) {
        old.check(
          transfers.read(e.id)?['state'] == 'VERIFIED',
          'Transfer missing ${e.id} ${transfers.read(e.id)}',
        );
        final endpoint =
            '/construction/hydrostatic-tests/$id/evidences/${e.id}';
        final original = await api.dio.get<List<int>>(
          '$endpoint/original',
          options: Options(responseType: ResponseType.bytes),
        );
        old.check(
          sha256.convert(original.data!).toString() == e.sha256,
          'Download hash',
        );
        final thumb = await api.dio.get<List<int>>(
          '$endpoint/thumbnail',
          options: Options(responseType: ResponseType.bytes),
        );
        old.check(thumb.data!.isNotEmpty, 'Thumbnail');
        final r = await media.remote.upload(
          e,
          File('${root.path}/${e.originalPath}'),
          'image/png',
          identity()!,
          (_, _) {},
        );
        old.check(r['verified'] == true, 'Replay');
        state['media:${e.id}'] = r;
      }
    }
    await pass(
      'HAPI4 T1–T7/T11 PASS: cuatro roles, SHA, replay, respuesta perdida, lectura y thumbnail',
    );
    final prior = session!;
    await login(1, installation: old.uuid());
    try {
      await api.dio.get(
        '/construction/hydrostatic-tests/$a/evidences/${lost.id}/original',
      );
      throw StateError('IDOR');
    } on DioException catch (e) {
      old.check(e.response?.statusCode == 404, 'IDOR status');
    }
    session = prior;
    await sessions.save(prior);
    await pass('HAPI4 T12 PASS: IDOR bloqueado');
    final c = state['OFFLINE'] as String? ?? await make('OFFLINE');
    // Declare first, then restore media engine. No uploaded file yet for this attempt.
    sync.media = null;
    await sync.run(manual: true);
    sync.media = media;
    old.check(row(c)['active'] == null, 'Offline declaration ACK');
    await pass('PREPARADO: quitar reverse, pulsar prueba sin red');
  }

  @override
  Future<void> offline() async {
    await media.run(manual: true);
    await save();
    await pass('HAPI4 T8: red cortada; reiniciar QA y restaurar reverse');
  }

  @override
  Future<void> restart() async {
    if (state['missingChecked'] != true) {
      final e = repo.get(state['OFFLINE'])!.evidence.first;
      final f = File('${root.path}/${e.originalPath}');
      final held = File('${f.path}.preserved-test');
      await f.rename(held.path);
      try {
        await sync.run(manual: true);
        old.check(
          transfers.read(e.id)?['error'] == 'PHOTO_MISSING',
          'Missing error not durable',
        );
        old.check(
          (await sha256.bind(held.openRead()).first).toString() == e.sha256,
          'Held original changed',
        );
      } finally {
        await held.rename(f.path);
      }
      state['missingChecked'] = true;
      await pass(
        'HAPI4 T10 PASS: archivo ausente bloqueado, original preservado y restaurado',
      );
    }
    await sync.run(manual: true);
    for (final id in [state['A'], state['B'], state['OFFLINE']]) {
      for (final e in repo.get(id)!.evidence) {
        old.check(transfers.read(e.id)?['state'] == 'VERIFIED', 'Reopen ACK');
        old.check(
          (await sha256
                      .bind(File('${root.path}/${e.originalPath}').openRead())
                      .first)
                  .toString() ==
              e.sha256,
          'Original changed',
        );
        state['media:${e.id}'] = transfers.read(e.id);
      }
    }
    await pass(
      'HAPI4 T8/T9/T15 PASS: nuevo proceso, transferencia recuperada y originales intactos',
    );
  }
}
