import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'app/app.dart';
import 'core/config/app_config.dart';
import 'core/network/api_client.dart';
import 'core/persistence/local_store.dart';
import 'core/security/session_store.dart';
import 'core/services/app_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = AppConfig.fromEnvironment();
  await Hive.initFlutter();
  final local = await LocalStore.open();
  final sessions = SecureSessionStore();
  final api = ApiClient(config: config, sessions: sessions);
  final controller = AppController(
    config: config,
    local: local,
    sessions: sessions,
    api: api,
    packageInfo: await PackageInfo.fromPlatform(),
  );
  await controller.bootstrap();
  runApp(
    ChangeNotifierProvider.value(
      value: controller,
      child: const LevantamientosApp(),
    ),
  );
}
