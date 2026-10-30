import '../../data/hydrostatic/hydrostatic_media_sync.dart';
import '../../data/hydrostatic/hydrostatic_media_store.dart';
import 'dart:async';
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
import '../network/api_client.dart';
import '../config/app_config.dart';
import '../../data/hydrostatic/hydrostatic_sync.dart';
import '../../data/hydrostatic/hydrostatic_sync_api.dart';
import '../../data/hydrostatic/hydrostatic_sync_store.dart';
import 'hydrostatic_sync_runner.dart';

bool hydrostaticSyncEnabled(AppConfig? config, {required bool requested}) =>
    requested &&
    config?.environment == 'test' &&
    config?.apiBaseUrl.host != 'cifra.aquafim.com';

HydrostaticController createHydrostaticController({
  required HydrostaticAccessAdapter authorization,
  required HydrostaticCabinetLookup lookup,
  ApiClient? api,
  AppConfig? config,
  bool Function()? online,
}) {
  final syncEnabled =
      hydrostaticSyncEnabled(
        config,
        requested: const bool.fromEnvironment('HYDROSTATIC_SYNC_ENABLED'),
      ) &&
      api != null;
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
      if (syncEnabled) {
        controller.initializeSync = () async {
          final outbox = await HydrostaticSyncStore.open(
            Directory('${support.path}/hydrostatic/db'),
          );
          final sync = HydrostaticSync(
            repository: repository,
            store: outbox,
            remote: HydrostaticSyncApi(api),
            enabled: true,
            identity: () {
              try {
                final a = authorization.current().actor;
                return HydrostaticSyncIdentity(
                  a.userId,
                  a.sessionId,
                  a.deviceInstallationId,
                );
              } catch (_) {
                return null;
              }
            },
            verifySession: authorization.verify,
            online: online ?? () => true,
          );
          final mediaStore = await HydrostaticMediaStore.open(
            Directory('${support.path}/hydrostatic/db'),
          );
          sync.media = HydrostaticMediaSync(
            documents: sync,
            store: mediaStore,
            remote: HydrostaticMediaApi(api),
            support: support,
          )..onChanged = sync.mediaChanged;
          controller.attachSync(sync);
          final runner = HydrostaticSyncRunner(sync)..start();
          controller.disposeSyncRunner = runner.dispose;
        };
      }
      return repository;
    },
  );
  controller.syncOnStartup = syncEnabled;
  if (syncEnabled && authorization.allowed) {
    unawaited(
      Future<void>.microtask(() async {
        try {
          await controller.initialize();
        } catch (_) {
          /* Recover on next authorized access. */
        }
      }),
    );
  }
  return controller;
}
