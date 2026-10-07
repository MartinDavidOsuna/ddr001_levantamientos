import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ddr001_levantamientos/core/media/photo_capture_service.dart';
import 'package:ddr001_levantamientos/core/location/location_service.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_controller.dart';
import 'harness.dart';
import 'cabinet_preservation_test.dart' show FixturePicker;

class CancelledPicker implements ConstructionImagePicker {
  @override
  Future<XFile?> takePhoto() async => null;
  @override
  Future<LostDataResponse> retrieveLostData() async => LostDataResponse.empty();
}

class WeakLocation extends LocationService {
  @override
  Future<GeoPoint> capture() async => GeoPoint(
    latitude: 20,
    longitude: -103,
    accuracy: 250,
    capturedAt: DateTime.now().toUtc(),
  );
}

class ExpiredRemote extends FakeCabinetRemote {
  @override
  Future<Map<String, dynamic>> get(
    String path, [
    Map<String, dynamic>? query,
  ]) async {
    throw failure(401, 'SESSION_EXPIRED');
  }
}

class FullStorageCamera extends PhotoCaptureService {
  FullStorageCamera({required super.local});
  @override
  Future<ConstructionPhoto?> capture({
    required String surveyId,
    int? step,
    String? correctionId,
    PhotoPurpose? purpose,
  }) async {
    throw const FileSystemException(
      'No space left on device',
      'test-photo.jpg',
      OSError('ENOSPC', 28),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'simulated full storage preserves previous photos and releases capture lock',
    () async {
      final h = Harness();
      final remote = FakeCabinetRemote();
      await h.open(remote: remote);
      try {
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        final photo = await h.photo(id, 'registration');
        h.controller.dispose();
        h.controller = CabinetController(
          app: h.app,
          store: h.store,
          remote: remote,
          camera: FullStorageCamera(local: h.store.media),
        );
        await expectLater(
          h.controller.capture(id, 'registration'),
          throwsA(isA<FileSystemException>()),
        );
        expect(h.store.read(id)!.photos.single['id'], photo['id']);
        expect(File(photo['localPath']).existsSync(), isTrue);
        expect(h.store.read(id)!.pending, hasLength(1));
        expect(h.controller.capturing, isFalse);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'cancelled camera does not add empty evidence or discard existing photos',
    () async {
      final h = Harness();
      await h.open(remote: FakeCabinetRemote(), picker: CancelledPicker());
      try {
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        final photo = await h.photo(id, 'registration');
        await h.controller.capture(id, 'registration');
        expect(h.store.read(id)!.photos.single['id'], photo['id']);
        expect(File(photo['localPath']).existsSync(), isTrue);
        expect(h.controller.capturing, isFalse);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'weak GPS retains camera evidence but cannot certify installation GPS',
    () async {
      final h = Harness();
      await h.open(
        remote: FakeCabinetRemote(),
        picker: FixturePicker(),
        locations: WeakLocation(),
      );
      try {
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        await h.controller.capture(id, 'registration');
        final photo = h.store.read(id)!.photos.single;
        expect(File(photo['localPath']).existsSync(), isTrue);
        expect((photo['metadata'] as Map)['accuracy'], isNull);
        await expectLater(h.controller.installationGps(), throwsStateError);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'expired session preserves pending operation and captured bytes',
    () async {
      final h = Harness();
      await h.open(remote: ExpiredRemote());
      try {
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        final photo = await h.photo(id, 'registration');
        final operation = h.store.read(id)!.pending.single['body'];
        await h.controller.synchronize(force: true);
        expect(h.store.read(id)!.pending.single['body'], operation);
        expect(File(photo['localPath']).existsSync(), isTrue);
        expect(h.controller.allowed, isFalse);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'modified evidence is blocked before upload and closure remains pending',
    () async {
      final remote = FakeCabinetRemote();
      final h = Harness();
      await h.open(remote: remote);
      try {
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        await h.sync();
        final photo = await h.photo(id, 'registration');
        await h.controller.enqueue(id, 'registration_close', {
          'evidence': evidence(photo),
        });
        await File(photo['localPath']).writeAsBytes([9, 8, 7]);
        await h.sync();
        expect(remote.uploads, isEmpty);
        expect(h.store.read(id)!.pending.single['error'], contains('alterado'));
        expect(h.store.read(id)!.server['status'], 'draft');
        expect(h.store.read(id)!.photos.single['id'], photo['id']);
      } finally {
        await h.close();
      }
    },
  );
}
