import 'dart:io';
import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/core/network/api_client.dart';
import 'package:ddr001_levantamientos/core/persistence/local_store.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/core/services/app_controller.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/features/auth/login_page.dart';
import 'package:ddr001_levantamientos/features/home/home_page.dart';
import 'package:ddr001_levantamientos/features/map/construction_map_page.dart';
import 'package:ddr001_levantamientos/features/profile/profile_page.dart';
import 'package:ddr001_levantamientos/features/surveys/new_survey_page.dart';
import 'package:ddr001_levantamientos/features/surveys/survey_detail_page.dart';
import 'package:ddr001_levantamientos/features/surveys/surveys_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

class WidgetSessions implements SessionStore {
  @override
  Future<void> clear() async {}
  @override
  Future<String> installationId() async => 'i';
  @override
  Future<FieldSession?> read() async => null;
  @override
  Future<void> save(FieldSession value) async {}
}

Future<(AppController, Directory)> controller(ConstructionRole role) async {
  final root = await Directory.systemTemp.createTemp('ddr001-widget-');
  Hive.init(root.path);
  final local = await LocalStore.open(),
      sessions = WidgetSessions(),
      config = AppConfig.fromEnvironment(
        environment: 'test',
        baseUrl: 'http://127.0.0.1:3003/api/v1',
      );
  final app = AppController(
    config: config,
    local: local,
    sessions: sessions,
    api: ApiClient(config: config, sessions: sessions, dio: Dio()),
    packageInfo: PackageInfo(
      appName: 'DDR001',
      packageName: 'com.aquafim.ddr001levantamientos',
      version: '0.1.0',
      buildNumber: '1',
    ),
  );
  app.session = const FieldSession(
    sessionId: 's',
    userId: 'u',
    accessToken: 'a',
    refreshToken: 'r',
    installationId: 'i',
    name: 'Usuario',
    email: 'u@example.com',
    phone: '1234567890',
    crew: 'C1',
  );
  app.profile = ConstructionProfile(
    userId: 'u',
    displayName: 'Usuario',
    email: 'u@example.com',
    phone: '1234567890',
    crew: 'C1',
    role: role,
  );
  return (app, root);
}

Widget page(AppController app, Widget child) => ChangeNotifierProvider.value(
  value: app,
  child: MaterialApp(home: child),
);

void main() {
  testWidgets('login renders exact field auth inputs', (tester) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(page(app, const LoginPage()));
    expect(find.byKey(const Key('login_email')), findsOneWidget);
    expect(find.byKey(const Key('login_submit')), findsOneWidget);
  });
  testWidgets('contractor home exposes primary actions', (tester) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(page(app, const HomePage()));
    expect(find.text('INICIAR NUEVO LEVANTAMIENTO'), findsOneWidget);
    expect(find.text('MIS LEVANTAMIENTOS'), findsOneWidget);
  });
  testWidgets('new survey requires display identifier UI', (tester) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(page(app, const NewSurveyPage()));
    expect(find.byKey(const Key('display_identifier')), findsOneWidget);
    expect(find.textContaining('cuenta se asignará'), findsOneWidget);
  });
  testWidgets('survey step capture shows camera-only action', (tester) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    final survey = (await tester.runAsync(() => app.createSurvey('Losa 1')))!;
    await tester.pumpWidget(page(app, SurveyDetailPage(surveyId: survey.id)));
    expect(find.byKey(const Key('camera_1')), findsOneWidget);
    expect(find.text('Tomar foto'), findsOneWidget);
  });
  testWidgets('surveys offers search and filters', (tester) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(page(app, const SurveysPage()));
    expect(find.byKey(const Key('survey_search')), findsOneWidget);
    expect(find.text('Todos'), findsOneWidget);
  });
  testWidgets('map and profile have graceful empty and identity states', (
    tester,
  ) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(page(app, const ConstructionMapPage()));
    expect(find.textContaining('ubicación aparecerán'), findsOneWidget);
    await tester.pumpWidget(page(app, const ProfilePage()));
    expect(find.text('Contratista'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pump();
    expect(find.byKey(const Key('logout')), findsOneWidget);
  });
  testWidgets('resident home includes review and future installation', (
    tester,
  ) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.resident),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(page(app, const HomePage()));
    expect(find.text('REVISIÓN DE BASE'), findsOneWidget);
    expect(find.text('REGISTRAR INSTALACIÓN'), findsOneWidget);
    expect(find.text('Próximamente'), findsOneWidget);
  });
}
