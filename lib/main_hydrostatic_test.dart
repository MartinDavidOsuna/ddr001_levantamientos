// Standalone certification entry point. Never imported by production main.dart.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import 'core/hydrostatic/hydrostatic_contracts.dart';
import 'core/hydrostatic/hydrostatic_location.dart';
import 'core/hydrostatic/hydrostatic_photos.dart';
import 'core/location/location_service.dart';
import 'core/media/camera_capture_broker.dart';
import 'data/hydrostatic/hydrostatic_cabinet_lookup.dart';
import 'data/hydrostatic/hydrostatic_repository.dart';
import 'data/hydrostatic/hydrostatic_store.dart';
import 'domain/cabinets/cabinet_models.dart';
import 'domain/hydrostatic/hydrostatic_models.dart';
import 'features/hydrostatic/hydrostatic_controller.dart';
import 'features/hydrostatic/hydrostatic_pages.dart';
import 'qa/hydrostatic_test_guard.dart';

class _NoNetwork extends HttpOverrides {
  int blocked = 0;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    blocked++;
    throw StateError('TEST local: HTTP bloqueado');
  }
}

class _TestClock implements HydrostaticClock {
  _TestClock(this.file, this.offset);
  final File file;
  final SystemHydrostaticClock real = SystemHydrostaticClock();
  int offset;
  @override
  HydrostaticClockReading now() {
    final r = real.now();
    return HydrostaticClockReading(
      r.utc.add(Duration(milliseconds: offset)),
      r.runId,
      r.monotonicMs! + offset,
    );
  }

  Future<void> setOffset(int value) async {
    await file.writeAsString('$value', flush: true);
    offset = value;
  }
}

String _testUid(int number) {
  for (var digit = 0; digit < 10; digit++) {
    try {
      return cabinetUid('AQ26${number.toString().padLeft(5, '0')}$digit');
    } on FormatException {
      /* use actual validator */
    }
  }
  throw StateError('Invalid synthetic UID');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  requireHydrostaticTestBuild(
    debug: kDebugMode,
    environment: const String.fromEnvironment('APP_ENV'),
    enabled: const bool.fromEnvironment('HYDROSTATIC_QA'),
    packageName: (await PackageInfo.fromPlatform()).packageName,
  );
  final network = _NoNetwork();
  HttpOverrides.global = network;
  final support = await getApplicationSupportDirectory();
  final identityFile = File('${support.path}/qa-identity.json');
  final identity = await identityFile.exists()
      ? hydroObject(jsonDecode(await identityFile.readAsString()))
      : {
          'userId': const Uuid().v4(),
          'sessionId': const Uuid().v4(),
          'deviceInstallationId': const Uuid().v4(),
          'name': 'OPERADOR SINTÉTICO TEST',
        };
  if (!await identityFile.exists()) {
    await identityFile.writeAsString(jsonEncode(identity), flush: true);
  }
  final actor = HydrostaticActorSnapshot.fromJson(identity);
  final access = HydrostaticAccess(
    actor: actor,
    authorized: true,
    fieldSession: true,
  );
  final fixturesFile = File('${support.path}/qa-cabinets.json');
  if (!await fixturesFile.exists()) {
    await fixturesFile.writeAsString(
      jsonEncode([
        for (var index = 0; index < 3; index++)
          {
            'id': const Uuid().v4(),
            'actor': actor.userId,
            'synthetic': true,
            'working': {
              'uid': _testUid(98001 + index),
              'model': 'A${index + 1}',
              'automated': false,
              'status': 'registered',
            },
            'server': {},
          },
      ]),
      flush: true,
    );
  }
  final records = (jsonDecode(await fixturesFile.readAsString()) as List)
      .map((j) => CabinetRecord(hydroObject(j)))
      .toList();
  final clockFile = File('${support.path}/qa-clock-offset.txt');
  final clock = _TestClock(
    clockFile,
    await clockFile.exists() ? int.parse(await clockFile.readAsString()) : 0,
  );
  final store = await HydrostaticStore.open(
    Directory('${support.path}/hydrostatic/db'),
  );
  final gps = DeviceHydrostaticLocation(LocationService(), clock);
  late DurableHydrostaticPhotos photos;
  final repo = HydrostaticRepository(
    store: store,
    clock: clock,
    access: () => access,
    files: LocalHydrostaticEvidenceFiles(support),
    isCapturing: (id) => photos.isCapturing(id),
  );
  photos = DurableHydrostaticPhotos(
    repository: repo,
    broker: CameraCaptureBroker.shared,
    support: support,
    locations: gps,
  );
  final changes = ChangeNotifier();
  final controller = HydrostaticController(
    openRepository: () async => repo,
    access: () => access,
    verifySession: () async => access.requireUser(actor.userId),
    sessionChanges: changes,
    lookup: LocalHydrostaticCabinetLookup(
      records: () => records,
      authorized: (user) => user == actor.userId,
    ),
    photos: photos,
    locations: gps,
    evidencePath: (e) => '${support.path}/${e.originalPath}',
  );
  await controller.initialize();
  final notice = ValueNotifier<String>(
    'Sólo TEST: cámara y GPS reales, sin datos de campo.',
  );
  Map<String, dynamic>? gpsCheck;
  Future<void> audit() async {
    final documents = <Map<String, dynamic>>[];
    for (final t in repo.forUser()) {
      documents.add({
        'id': t.id,
        'uid': t.cabinet.uid,
        'number': t.attemptNumber,
        'state': hydroWire(t.state),
        'discarded': t.isDiscarded,
        'timeState': hydroWire(t.timeState),
        'startedAt': t.startedAt?.toIso8601String(),
        'endedAt': t.endedAt?.toIso8601String(),
        'durationMs': t.durationMs,
        'video': t.video.toJson(),
        'leaks': t.leaks.map((l) => l.toJson()).toList(),
        'evidence': [
          for (final e in t.evidence)
            {
              'id': e.id,
              'role': hydroWire(e.role),
              'path': e.originalPath,
              'sha256': e.sha256,
              'bytes': e.byteLength,
              'verified': await repo.files.verify(e),
              'ready': e.ready,
              'timeSource': hydroWire(e.timeSource),
              'gpsPresent': e.location != null,
              'accuracy': e.location?.accuracy,
            },
        ],
        'initialGps': t.toJson()['location'] != null,
      });
    }
    await File('${support.path}/qa-audit.json').writeAsString(
      jsonEncode({
        'synthetic': true,
        'package': 'com.aquafim.ddr001levantamientos.hydrotest',
        'networkAttempts': network.blocked,
        'clockOffsetMs': clock.offset,
        'gpsCheck': gpsCheck,
        'documents': documents,
      }),
      flush: true,
    );
  }

  runApp(
    ChangeNotifierProvider.value(
      value: controller,
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.orange),
        builder: (context, child) => Column(
          children: [
            const SafeArea(
              bottom: false,
              child: Material(
                color: Colors.amber,
                child: Padding(
                  padding: EdgeInsets.all(6),
                  child: Text(
                    'HIDRO TEST · SIN RED · NO CERTIFICA PRESIÓN',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
            Expanded(child: child!),
            Material(
              child: SafeArea(
                top: false,
                child: Wrap(
                  alignment: WrapAlignment.center,
                  children: [
                    ValueListenableBuilder<String>(
                      valueListenable: notice,
                      builder: (_, text, _) => Text(text),
                    ),
                    TextButton(
                      onPressed: () async {
                        try {
                          if (clock.offset != 0) {
                            throw StateError('TEST_CLOCK_OFFSET');
                          }
                          final fix = await gps.capture();
                          gpsCheck = {
                            'valid': fix.validAt(clock.now().utc),
                            'accuracy': fix.accuracy,
                            'at': clock.now().utc.toIso8601String(),
                          };
                          notice.value =
                              'GPS REAL VÁLIDO: precisión ${fix.accuracy.toStringAsFixed(1)} m';
                        } catch (e) {
                          gpsCheck = {
                            'valid': false,
                            'errorType': e.runtimeType.toString(),
                          };
                          notice.value =
                              'GPS no disponible: ${e.runtimeType}. Datos conservados.';
                        }
                        await audit();
                      },
                      child: const Text('COMPROBAR GPS REAL'),
                    ),
                    TextButton(
                      onPressed: () async {
                        await audit();
                      },
                      child: const Text('AUDITORÍA TEST'),
                    ),
                    TextButton(
                      onPressed: () async {
                        if (controller.busy ||
                            repo.forUser().any(
                              (t) => t.state == HydrostaticTestState.active,
                            )) {
                          return;
                        }
                        await clock.setOffset(clock.offset + 31 * 60000);
                        await controller.expireResults();
                        await audit();
                      },
                      child: const Text('+31 MIN TEST'),
                    ),
                    TextButton(
                      onPressed: () async {
                        if (controller.busy ||
                            repo.forUser().any(
                              (t) => t.state == HydrostaticTestState.active,
                            )) {
                          return;
                        }
                        await clock.setOffset(0);
                        await audit();
                      },
                      child: const Text('RELOJ REAL'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        home: Scaffold(
          appBar: AppBar(title: const Text('DDR001 HIDRO TEST')),
          body: Builder(
            builder: (context) => ListView(
              children: [
                const ListTile(
                  title: Text(
                    'Datos sintéticos locales; no representan equipos productivos.',
                  ),
                ),
                for (final r in records)
                  ListTile(
                    title: Text(displayUid(r.working['uid'])),
                    subtitle: Text('MODELO ${r.working['model']} · TEST'),
                  ),
                FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      settings: const RouteSettings(name: 'hydrostatic-list'),
                      builder: (_) => const HydrostaticListPage(),
                    ),
                  ),
                  child: const Text('PRUEBAS HIDROSTÁTICAS'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
