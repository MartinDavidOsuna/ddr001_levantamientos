import 'package:hive_ce/hive.dart';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_bootstrap.dart';
import 'package:ddr001_levantamientos/core/services/app_controller.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_controller.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_access_adapter.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_cabinet_lookup.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/features/home/home_page.dart';
import 'package:ddr001_levantamientos/features/hydrostatic/hydrostatic_controller.dart';
import 'package:ddr001_levantamientos/features/hydrostatic/hydrostatic_pages.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_repository.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_store.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync_store.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'identity_guid_test.dart' show legacyUser, legacySession, installation;
import '../cabinets/harness.dart';
import 'ui_widgets_test.dart' show localWidgetTest, settle;

class Routes extends NavigatorObserver {
  String? last;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    last = route.settings.name;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late HydrostaticAccessAdapter access;
  late HydrostaticController hydro;
  late Routes routes;
  var requests = 0;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() async {
    h = Harness();
    await h.open(environment: 'production');
    requests = 0;
    h.client.dio.interceptors.clear();
    // No server is needed to render or initialize the local module.
    h.client.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requests++;
          handler.reject(DioException(requestOptions: options));
        },
      ),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, (_) async => h.directory.path);
    access = HydrostaticAccessAdapter(
      session: () => h.app.session,
      profile: () => h.app.profile,
      cabinetAuthorized: () => h.controller.allowed,
      sessions: h.sessions,
      changes: [h.app, h.controller],
    );
    hydro = createHydrostaticController(
      authorization: access,
      lookup: LocalHydrostaticCabinetLookup.fromStore(h.store),
      api: h.client,
      config: h.app.config,
      online: () => h.app.online,
    );
    routes = Routes();
  });
  tearDown(() async {
    hydro.dispose();
    access.dispose();
    await h.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(paths, null);
  });
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AppController>.value(value: h.app),
          ChangeNotifierProvider<CabinetController>.value(value: h.controller),
          ChangeNotifierProvider<HydrostaticController>.value(value: hydro),
        ],
        child: MaterialApp(
          navigatorObservers: [routes],
          home: const HomePage(),
        ),
      ),
    );
    await tester.ensureVisible(find.byKey(const Key('hydrostatic_action')));
    await tester.pumpAndSettle();
  }

  localWidgetTest(
    'resident menu and existing route initialize real controller offline',
    (tester) async {
      expect(h.app.online, isFalse);
      expect(hydro.ready, isFalse);
      await open(tester);
      expect(find.text('PRUEBAS HIDROSTÁTICAS'), findsOneWidget);
      for (final key in [
        'register_cabinet_action',
        'resident_review_action',
        'install_cabinet_action',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget);
      }
      await tester.tap(find.byKey(const Key('hydrostatic_action')));
      await settle(tester);
      expect(routes.last, 'hydrostatic-list');
      expect(find.byType(HydrostaticListPage), findsOneWidget);
      expect(hydro.ready, isTrue);
      expect(hydro.photos, isNotNull);
      expect(hydro.locations, isNotNull);
      expect(find.text('NUEVA PRUEBA'), findsOneWidget);
      await tester.tap(find.text('NUEVA PRUEBA'));
      await settle(tester);
      expect(find.byKey(const Key('hydro_uid')), findsOneWidget);
      expect(find.text('ESCANEAR QR'), findsOneWidget);
      expect(requests, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  localWidgetTest(
    'temporary API failure preserves cached permission and local module',
    (tester) async {
      await h.controller.refresh();
      expect(requests, 1);
      expect(h.controller.message, isNotNull);
      expect(h.controller.allowed, isTrue);
      await open(tester);
      await tester.tap(find.byKey(const Key('hydrostatic_action')));
      await settle(tester);
      expect(find.byType(HydrostaticListPage), findsOneWidget);
      expect(hydro.ready, isTrue);
      expect(requests, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final existing in [false, true]) {
    localWidgetTest(
      'historical resident opens offline from menu; existing=$existing; preserves session and stores',
      (tester) async {
        final saved = h.sessions.value!;
        final session = FieldSession(
          userId: legacyUser,
          sessionId: legacySession,
          installationId: installation,
          name: saved.name,
          email: saved.email,
          phone: saved.phone,
          accessToken: saved.accessToken,
          refreshToken: saved.refreshToken,
        );
        h.app.session = session;
        h.sessions.value = session;
        h.setRole(ConstructionRole.resident);
        await h.store.authorize(legacyUser, true);
        final sessionBefore = Map.of(session.toJson());
        final cabinetBefore = Map.of(h.store.box.toMap());
        final directory = Directory('${h.directory.path}/hydrostatic/db');
        const testId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
        Map<dynamic, dynamic>? documentsBefore;
        Map<dynamic, dynamic>? journalBefore;
        Map<dynamic, dynamic>? outboxBefore;
        if (existing) {
          final store = await HydrostaticStore.open(directory);
          final repo = HydrostaticRepository(
            store: store,
            clock: SystemHydrostaticClock(),
            access: access.current,
            files: LocalHydrostaticEvidenceFiles(h.directory),
          );
          await repo.prepare(
            operationId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            testId: testId,
            cabinet: HydrostaticCabinetSnapshot(
              uid: 'AQ26000017',
              model: 'A1',
              automated: false,
            ),
          );
          documentsBefore = Map.of(store.documents.toMap());
          journalBefore = Map.of(store.journal.toMap());
          final outbox = await HydrostaticSyncStore.open(directory);
          await outbox.save(testId, {
            'schemaVersion': 1,
            'pending': [
              {'operationId': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'},
            ],
          }, 'synthetic-pending');
          outboxBefore = Map.of(outbox.box.toMap());
          await outbox.close();
          await store.close();
        }
        await open(tester);
        expect(hydro.accessIssue, isNull);
        await tester.tap(find.byKey(const Key('hydrostatic_action')));
        await settle(tester);
        expect(find.byType(HydrostaticListPage), findsOneWidget);
        expect(hydro.ready, isTrue);
        expect(hydro.documents.length, existing ? 1 : 0);
        expect(identical(await h.sessions.read(), session), isTrue);
        expect(h.sessions.value!.toJson(), sessionBefore);
        expect(h.store.box.toMap(), cabinetBefore);
        if (existing) {
          expect(hydro.document(testId).actor.userId, legacyUser);
          expect(hydro.document(testId).actor.sessionId, legacySession);
          expect(
            Hive.box<String>(HydrostaticStore.names[0]).toMap(),
            documentsBefore,
          );
          expect(
            Hive.box<String>(HydrostaticStore.names[1]).toMap(),
            journalBefore,
          );
          final outbox = await HydrostaticSyncStore.open(directory);
          expect(outbox.box.toMap(), outboxBefore);
          await outbox.close();
        }
        expect(requests, 0);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final role in ConstructionRole.values) {
    if (role == ConstructionRole.resident) continue;
    localWidgetTest('visible entry denies unauthorized ${role.name}', (
      tester,
    ) async {
      h.setRole(role);
      await open(tester);
      expect(hydro.allowed, isFalse);
      expect(
        find.text('Acceso exclusivo para residentes autorizados.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('hydrostatic_action')));
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(HydrostaticListPage), findsNothing);
      expect(hydro.ready, isFalse);
      expect(requests, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }

  localWidgetTest(
    'missing cabinet permission explains block without opening storage',
    (tester) async {
      await h.store.authorize(h.app.session!.userId, false);
      await open(tester);
      expect(
        find.textContaining('No hay autorización vigente'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('hydrostatic_action')));
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.byType(HydrostaticListPage), findsNothing);
      expect(hydro.ready, isFalse);
      expect(requests, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
