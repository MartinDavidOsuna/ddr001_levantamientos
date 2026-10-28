import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../data/hydrostatic/hydrostatic_access_adapter.dart';
import '../../data/hydrostatic/hydrostatic_repository.dart';
import '../../data/hydrostatic/hydrostatic_store.dart';
import '../../features/hydrostatic/hydrostatic_controller.dart';
import '../location/location_service.dart';
import '../media/camera_capture_broker.dart';
import 'hydrostatic_contracts.dart';
import 'hydrostatic_location.dart';
import 'hydrostatic_photos.dart';

HydrostaticController createHydrostaticController({
  required HydrostaticAccessAdapter authorization,
  required HydrostaticCabinetLookup lookup,
}) {
  late HydrostaticController controller;
  controller = HydrostaticController(
    access: authorization.current,
    verifySession: authorization.verify,
    sessionChanges: authorization,
    lookup: lookup,
    openRepository: () async {
      final support = await getApplicationSupportDirectory();
      final store = await HydrostaticStore.open(
        Directory('${support.path}/hydrostatic/db'),
      );
      final clock = SystemHydrostaticClock();
      final gps = DeviceHydrostaticLocation(LocationService(), clock);
      late DurableHydrostaticPhotos photos;
      final repository = HydrostaticRepository(
        store: store,
        clock: clock,
        access: authorization.current,
        files: LocalHydrostaticEvidenceFiles(support),
        isCapturing: (id) => photos.isCapturing(id),
      );
      photos = DurableHydrostaticPhotos(
        repository: repository,
        broker: CameraCaptureBroker.shared,
        support: support,
        locations: gps,
      );
      controller.photos = photos;
      controller.locations = gps;
      controller.evidencePath = (e) => '${support.path}/${e.originalPath}';
      return repository;
    },
  );
  return controller;
}
