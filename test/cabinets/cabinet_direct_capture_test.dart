import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/core/location/location_service.dart';
import 'package:ddr001_levantamientos/core/media/photo_capture_service.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/features/cabinets/cabinet_pages.dart';
import 'cabinet_preservation_test.dart' show FixturePicker, FailingLocation;
import 'harness.dart';

class CaptureLocation extends LocationService {
  @override
  Future<GeoPoint> capture() async => GeoPoint(
    latitude: 20,
    longitude: -103,
    accuracy: 5,
    capturedAt: DateTime.now().toUtc(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  setUp(() async {
    h = Harness();
    await h.open(
      remote: FakeCabinetRemote(),
      picker: FixturePicker(),
      locations: CaptureLocation(),
    );
  });
  tearDown(() => h.close());
  testWidgets(
    'each rubric shows only its count and opens only its associated gallery',
    (tester) async {
      final id = (await tester.runAsync(() async {
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        await h.controller.capture(id, 'installation');
        await h.controller.capture(id, 'installation');
        return id;
      }))!;
      final photos = h.controller.record(id).photos;
      expect(photos, hasLength(2));
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: h.controller,
          child: MaterialApp(
            home: Scaffold(
              body: EvidenceEditor(
                id: id,
                contextName: 'installation',
                rubricTitle: 'Fotografía general',
                value: [
                  {'photoId': photos.first['id'], 'confirmed': true},
                ],
                onChanged: (_) async {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('1 foto tomada'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(find.byType(Image), findsNothing);
      await tester.runAsync(() async {
        await tester.tap(find.text('1 foto tomada'));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('Fotografía general'), findsOneWidget);
      expect(
        find.byKey(ValueKey('rubric-photo-${photos.first['id']}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('rubric-photo-${photos.last['id']}')),
        findsNothing,
      );
      h.setRole(ConstructionRole.contractor);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: h.controller,
          child: MaterialApp(
            home: CabinetRubricGallery(
              title: 'Fotografía general',
              id: id,
              photoIds: ['${photos.first['id']}'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('rubric-photo-${photos.first['id']}')),
        findsNothing,
      );
      expect(find.textContaining('Acceso exclusivo'), findsOneWidget);
    },
  );

  testWidgets(
    'camera saves and relates evidence without a clarity review route',
    (tester) async {
      final id = (await tester.runAsync(
        () => h.controller.scan('AQ26000017', 'A1', false),
      ))!;
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: h.controller,
          child: MaterialApp(
            home: Scaffold(
              body: EvidenceEditor(
                id: id,
                contextName: 'registration',
                value: const [],
                onChanged: (e) =>
                    h.controller.saveDraft(id, 'registrationEvidence', e),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Tomar fotografía'));
        for (var i = 0; i < 100; i++) {
          if (objects(
            h.store.read(id)!.working['registrationEvidence'],
          ).isNotEmpty) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      });
      await tester.pumpAndSettle();
      final record = h.store.read(id)!;
      expect(record.photos, hasLength(1));
      expect(
        objects(record.working['registrationEvidence']).single['photoId'],
        record.photos.single['id'],
      );
      expect(find.text('Revisar fotografía'), findsNothing);
      expect(find.text('Foto legible y correcta'), findsNothing);
      expect(find.text('Tomar fotografía'), findsOneWidget);
      expect(File(record.photos.single['localPath']).existsSync(), isTrue);
    },
  );
  test(
    'draft photo deletion preserves bytes until acknowledged and cannot resurrect during recovery',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      await h.sync();
      await h.controller.capture(id, 'registration');
      final photo = h.store.read(id)!.photos.single;
      final file = File(photo['localPath']);
      await h.controller.deleteRegistrationPhoto(id, photo['id']);
      expect(h.store.read(id)!.photos.single['deleting'], isTrue);
      expect(await file.exists(), isTrue);
      await h.sync();
      expect(h.store.read(id)!.photos, isEmpty);
      expect(await file.exists(), isFalse);
      expect(h.store.media.journal.find(photo['id']), isNull);
      await h.controller.recoverPhotos();
      expect(h.store.read(id)!.photos, isEmpty);
    },
  );
  test(
    'late valid GPS is associated automatically but old or distant fixes are rejected',
    () async {
      await h.close();
      h = Harness();
      await h.open(
        remote: FakeCabinetRemote(),
        picker: FixturePicker(),
        locations: FailingLocation(),
      );
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      await h.controller.capture(id, 'registration');
      final p = h.store.read(id)!.photos.single;
      final captured = DateTime.parse(object(p['metadata'])['capturedAt']);
      LocationFix fix(DateTime time) => LocationFix(
        latitude: 20,
        longitude: -103,
        horizontalAccuracy: 5,
        timestamp: time,
        acquiredAt: time,
        source: 'gnss',
        isMocked: false,
      );
      h.app.locations.addFix(
        fix(captured.subtract(const Duration(minutes: 3))),
      );
      await h.controller.recoverPhotoGps();
      expect(
        object(h.store.read(id)!.photos.single['metadata'])['accuracy'],
        isNull,
      );
      h.app.locations.addFix(fix(captured.add(const Duration(seconds: 5))));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await h.controller.recoverPhotoGps();
      final record = h.store.read(id)!;
      expect(object(record.photos.single['metadata'])['latitude'], 20);
      expect(
        objects(record.working['registrationEvidence']).single['photoId'],
        p['id'],
      );
    },
  );
  test('original upload preserves camera bytes and matching SHA-256', () async {
    final camera = PhotoCaptureService(
      local: h.app.local,
      picker: FixturePicker(),
      supportDirectory: () async => h.directory,
      directoryName: 'cabinets',
      preserveOriginalUpload: true,
      representationBuilder: (source, upload, thumbnail) async {
        expect(await upload.readAsBytes(), await source.readAsBytes());
        await source.copy(thumbnail.path);
        return true;
      },
    );
    final photo = (await camera.capture(
      surveyId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    ))!;
    final original = File('test/cabinets/fixtures/evidence.jpg');
    expect(
      await File(photo.localPath).readAsBytes(),
      await original.readAsBytes(),
    );
    expect(photo.sha256, await sha256File(original));
  });
}
