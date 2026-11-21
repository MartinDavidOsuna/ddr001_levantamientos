import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'app/app.dart';
import 'core/media/camera_capture_broker.dart';
import 'core/hydrostatic/hydrostatic_bootstrap.dart';
import 'data/hydrostatic/hydrostatic_access_adapter.dart';
import 'data/hydrostatic/hydrostatic_cabinet_lookup.dart';
import 'features/hydrostatic/hydrostatic_controller.dart';
import 'data/cabinets/cabinet_api.dart';
import 'data/cabinets/cabinet_store.dart';
import 'data/cabinets/cabinet_controller.dart';
import 'core/config/app_config.dart';
import 'core/network/api_client.dart';
import 'core/persistence/local_store.dart';
import 'core/qa/device_certification_fixture.dart';
import 'core/security/session_store.dart';
import 'core/services/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  await Hive.initFlutter();
  try {
    await CameraCaptureBroker.shared.recover();
  } on Object catch (error) {
    // Preserve the dispatch receipt and originals; never block legacy startup
    // or fall back to assigning by cache timestamp.
    debugPrint('[CAMERA_RECOVERY] pending ${error.runtimeType}');
  }
  final local = await LocalStore.open();
  final sessions = SecureSessionStore();
  await seedDeviceCertificationFixture(local, sessions);
  final api = ApiClient(config: config, sessions: sessions);
  final controller = AppController(
    config: config,
    local: local,
    sessions: sessions,
    api: api,
    packageInfo: await PackageInfo.fromPlatform(),
  );
  await controller.bootstrap();
  final cabinets = CabinetController(
    app: controller,
    store: await CabinetStore.open(),
    remote: CabinetApi(api),
  );
  await cabinets.start();
  final hydrostaticAccess = HydrostaticAccessAdapter(
    session: () => controller.session,
    profile: () => controller.profile,
    cabinetAuthorized: () => cabinets.allowed,
    sessions: sessions,
    changes: [controller, cabinets],
  );
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: controller),
        ChangeNotifierProvider.value(value: cabinets),
        ChangeNotifierProvider<HydrostaticController>(
          create: (_) => createHydrostaticController(
            authorization: hydrostaticAccess,
            api: api,
            config: config,
            online: () => controller.online,
            lookup: LocalHydrostaticCabinetLookup.fromStore(cabinets.store),
          ),
        ),
      ],
      child: const LevantamientosApp(),
    ),
  );
}
