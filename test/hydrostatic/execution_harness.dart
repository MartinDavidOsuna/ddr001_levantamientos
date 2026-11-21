import 'dart:io';
import 'package:image_picker/image_picker.dart';
import 'package:ddr001_levantamientos/core/media/camera_capture_broker.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_photos.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'ui_harness.dart';
import 'harness.dart';

class SyntheticPicker implements ConstructionImagePicker {
  SyntheticPicker(this.h);
  final UiHarness h;
  bool cancel = false, corrupt = false, empty = false, throwAfter = false;
  bool distinctBytes = false;
  int paddingBytes = 0;
  int captures = 0, retrievals = 0;
  Future<void> Function()? beforeReturn;
  List<XFile> lost = [];
  @override
  Future<XFile?> takePhoto() async {
    captures++;
    final receipts = Directory('${h.root.path}/camera_dispatch_v1');
    if (!await File('${receipts.path}/active.json').exists()) {
      throw StateError('Intent missing');
    }
    if (cancel) return null;
    final file = File('${h.root.path}/${uuid()}.jpg');
    await file.writeAsBytes(
      empty
          ? []
          : corrupt
          ? [1, 2, 3]
          : [
              ...await File(
                'test/cabinets/fixtures/evidence.jpg',
              ).readAsBytes(),
              if (distinctBytes) ...'synthetic-capture-$captures'.codeUnits,
              ...List<int>.filled(paddingBytes, 0),
            ],
      flush: true,
    );
    h.clock.advance(1000);
    await file.setLastModified(h.clock.utc);
    final result = XFile(file.path);
    await beforeReturn?.call();
    if (throwAfter) {
      lost = [result];
      throw StateError('synthetic process interrupted');
    }
    return result;
  }

  @override
  Future<LostDataResponse> retrieveLostData() async {
    retrievals++;
    final files = lost;
    lost = [];
    return files.isEmpty
        ? LostDataResponse.empty()
        : LostDataResponse(
            files: files,
            file: files.first,
            type: RetrieveType.image,
          );
  }
}

class SyntheticGps implements HydrostaticLocationProvider {
  SyntheticGps(this.h);
  final UiHarness h;
  Object? error;
  HydrostaticLocation? suppliedFix;
  Future<void> Function()? beforeReturn;
  int calls = 0;
  @override
  Future<HydrostaticLocation> capture() async {
    calls++;
    await beforeReturn?.call();
    if (error != null) throw error!;
    return suppliedFix ?? h.location();
  }
}

class ExecutionHarness extends UiHarness {
  late SyntheticPicker picker;
  late SyntheticGps gps;
  late CameraCaptureBroker broker;
  late DurableHydrostaticPhotos photos;
  @override
  Future<void> open() async {
    await super.open();
    picker = SyntheticPicker(this);
    gps = SyntheticGps(this);
    wire();
  }

  void wire() {
    broker = CameraCaptureBroker(
      picker: picker,
      supportDirectory: () => Future.value(root),
      temporaryDirectory: () => Future.value(Directory('${root.path}/cache')),
      now: () => clock.utc,
    );
    photos = DurableHydrostaticPhotos(
      repository: repo,
      broker: broker,
      support: root,
      locations: gps,
    );
    controller.photos = photos;
    controller.locations = gps;
    controller.evidencePath = (e) => '${root.path}/${e.originalPath}';
  }

  Future<String> ready() async {
    final id = await controller.identify('AQ26000017');
    await controller.capturePhoto(id, HydrostaticEvidenceRole.initialSetup);
    return id;
  }

  Future<void> restart() async {
    controller.dispose();
    await reopen();
    makeController();
    clock.reboot();
    wire();
    await controller.initialize();
  }
}
