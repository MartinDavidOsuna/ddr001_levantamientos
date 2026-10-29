import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ddr001_levantamientos/core/media/camera_capture_broker.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_photos.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'execution_harness.dart';
import 'harness.dart';

class DeniedPicker implements ConstructionImagePicker {
  String? code = 'camera_access_denied';
  @override
  Future<XFile?> takePhoto() async {
    if (code != null) throw PlatformException(code: code!);
    return null;
  }

  @override
  Future<LostDataResponse> retrieveLostData() async => LostDataResponse.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ExecutionHarness h;
  late DeniedPicker picker;
  late CameraCaptureBroker broker;
  setUp(() async {
    h = ExecutionHarness();
    await h.open();
    picker = DeniedPicker();
    broker = CameraCaptureBroker(
      picker: picker,
      supportDirectory: () async => h.root,
      temporaryDirectory: () async => Directory('${h.root.path}/empty-cache'),
    );
  });
  tearDown(() async => h.close());
  for (final module in ['hydrostatic', 'construction', 'cabinets']) {
    test(
      '$module permission denial durably cancels only its intent and permits retry',
      () async {
        final id = uuid(), entity = uuid();
        Future<Map<String, dynamic>?> capture(String captureId) =>
            broker.capture(
              id: captureId,
              module: module,
              entityId: entity,
              actorId: h.access.actor.userId,
              role: 'INITIAL_SETUP',
              requestedAt: h.clock.utc,
            );
        await expectLater(capture(id), throwsA(isA<PlatformException>()));
        expect((await broker.receipt(module, id))!['state'], 'CANCELLED');
        await broker.recover();
        expect((await broker.receipt(module, id))!['state'], 'CANCELLED');
        expect(await broker.quarantined(), isEmpty);
        picker.code = null;
        expect(await capture(uuid()), isNull);
        expect(await capture(id), isNull);
      },
    );
  }
  test(
    'unknown native failure remains recoverable, never silently cancelled',
    () async {
      picker.code = 'unknown_camera_failure';
      final id = uuid();
      await expectLater(
        broker.capture(
          id: id,
          module: 'hydrostatic',
          entityId: uuid(),
          actorId: h.access.actor.userId,
          role: 'INITIAL_SETUP',
          requestedAt: h.clock.utc,
        ),
        throwsA(isA<PlatformException>()),
      );
      expect((await broker.receipt('hydrostatic', id))!['state'], 'PREPARED');
    },
  );
  test(
    'hydrostatic denied capture preserves old photo and has no pending intent',
    () async {
      final id = await h.ready();
      final before = h.repo.get(id)!.toJson();
      final photos = DurableHydrostaticPhotos(
        repository: h.repo,
        broker: broker,
        support: h.root,
        locations: h.gps,
      );
      final intent = HydrostaticCaptureIntent(
        id: uuid(),
        testId: id,
        actorId: h.access.actor.userId,
        role: HydrostaticEvidenceRole.initialSetup,
        requestedAt: h.clock.utc,
      );
      await expectLater(
        photos.capture(intent),
        throwsA(isA<PlatformException>()),
      );
      expect(
        h.store.read(h.store.metadata, 'capture:${intent.id}')!['state'],
        'CANCELLED',
      );
      expect(jsonEncode(h.repo.get(id)!.toJson()), jsonEncode(before));
      expect(await h.files.verify(h.repo.get(id)!.evidence.single), true);
    },
  );
}
