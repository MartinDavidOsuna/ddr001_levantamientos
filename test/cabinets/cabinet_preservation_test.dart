import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ddr001_levantamientos/core/location/location_service.dart';
import 'package:ddr001_levantamientos/core/media/photo_capture_service.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_controller.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_store.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'harness.dart';
import 'cabinet_api_test.dart' show Adapter, response;

class FailingLocation extends LocationService {
  @override
  Future<GeoPoint> capture() async => throw StateError('GPS no disponible');
}

class FixturePicker implements ConstructionImagePicker {
  @override
  Future<XFile?> takePhoto() async =>
      XFile('test/cabinets/fixtures/evidence.jpg');
  @override
  Future<LostDataResponse> retrieveLostData() async => LostDataResponse.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'camera persists original and journal when GPS fails; no warehouse fallback',
    () async {
      final h = Harness();
      await h.open(
        remote: FakeCabinetRemote(),
        locations: FailingLocation(),
        picker: FixturePicker(),
      );
      try {
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        await h.controller.capture(id, 'registration');
        final photo = h.store.read(id)!.photos.single;
        expect(File(photo['localPath']).existsSync(), isTrue);
        expect(object(photo['metadata'])['accuracy'], isNull);
        expect(h.controller.message, contains('GPS pendiente'));
        expect(
          h.store.media.journal.find(photo['id'])!.state.name,
          'committed',
        );
        expect(() => h.controller.installationGps(), throwsStateError);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'controller restart recovers sending receipt and exact immutable operation identity',
    () async {
      final remote = FakeCabinetRemote();
      final h = Harness();
      await h.open(remote: remote);
      try {
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        remote.loseNextResponse = true;
        await h.sync();
        final before = clone(h.store.read(id)!.pending.single);
        h.controller.dispose();
        await h.store.box.close();
        h.store = await CabinetStore.open();
        h.controller = CabinetController(
          app: h.app,
          store: h.store,
          remote: remote,
        );
        expect(h.store.read(id)!.pending.single['body'], before['body']);
        await h.sync();
        expect(h.store.read(id)!.pending, isEmpty);
        expect(remote.calls.length, 1);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'waived wire status survives Hive and disallows editing completion and photography',
    () async {
      final h = Harness();
      await h.open(remote: FakeCabinetRemote());
      try {
        h.setRole(ConstructionRole.contractor);
        final survey = await h.app.createSurvey('TEST DISPENSADA');
        const correction = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
        h.client.dio.httpClientAdapter = Adapter(
          (r) async => response(200, {
            'survey_id': survey.id,
            'contractor_user_id': h.app.session!.userId,
            'status': 'accepted',
            'steps': [],
            'photos': [],
            'corrections': [
              {
                'correction_id': correction,
                'round_number': 1,
                'status': 'waived',
                'comment': 'Dispensa auditada',
              },
            ],
          }),
        );
        await h.app.loadSurveyDetail(survey.id);
        expect(
          h.app.survey(survey.id).corrections.single.state,
          StepState.waived,
        );
        expect(
          h.app.local.surveys().single.corrections.single.state,
          StepState.waived,
        );
        await expectLater(
          h.app.updateCorrectionComment(survey.id, correction, 'No permitido'),
          throwsStateError,
        );
        await expectLater(
          h.app.finalizeCorrection(survey.id, correction),
          throwsStateError,
        );
        await expectLater(
          h.app.captureCorrectionPhoto(survey.id, correction),
          throwsStateError,
        );
      } finally {
        await h.close();
      }
    },
  );
  test(
    'editing a validated part clears local validation before installation can complete',
    () async {
      final h = Harness();
      await h.open(remote: FakeCabinetRemote());
      try {
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        final r = clone(h.store.read(id)!.json);
        r['working']['partsValidated'] = true;
        r['working']['status'] = 'validated';
        await h.store.save(r);
        await h.controller.saveDraft(id, 'parts', []);
        expect(h.store.read(id)!.working['partsValidated'], false);
        await expectLater(
          h.controller.enqueue(id, 'installation_close', {}),
          throwsStateError,
        );
      } finally {
        await h.close();
      }
    },
  );
}
