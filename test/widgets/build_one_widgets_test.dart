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
import 'package:ddr001_levantamientos/features/map/map_status_legend.dart';
import 'package:ddr001_levantamientos/features/profile/profile_page.dart';
import 'package:ddr001_levantamientos/features/resident/resident_review_page.dart';
import 'package:ddr001_levantamientos/features/surveys/new_survey_page.dart';
import 'package:ddr001_levantamientos/features/surveys/survey_detail_page.dart';
import 'package:ddr001_levantamientos/features/surveys/surveys_page.dart';
import 'package:ddr001_levantamientos/features/shell/main_shell.dart';
import 'package:ddr001_levantamientos/shared/widgets/optional_comment_field.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart' hide StepState;
import 'package:flutter/rendering.dart';
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
    crew: 'CUADRILLA NORTE',
  );
  app.profile = ConstructionProfile(
    userId: 'u',
    displayName: 'Usuario',
    email: 'u@example.com',
    phone: '1234567890',
    role: role,
  );
  return (app, root);
}

Widget page(AppController app, Widget child) => ChangeNotifierProvider.value(
  value: app,
  child: MaterialApp(home: child),
);

void ignoreComment(String _) {}

BaseSurvey reviewSurvey() => BaseSurvey(
  id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  displayIdentifier: 'Base Norte',
  accountNumber: '890',
  contractorName: 'Juan Pérez',
  createdAt: DateTime.utc(2026, 8, 1),
  updatedAt: DateTime.utc(2026, 8, 2),
  status: SurveyStatus.executed,
  localState: LocalSurveyState.executedLocal,
  syncState: SyncState.synchronized,
  currentStep: 6,
  steps: List.generate(
    6,
    (index) => SurveyStep(number: index + 1, state: StepState.completedServer),
  ),
);

void main() {
  testWidgets('login is Field-only, ordered and includes crew', (tester) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(page(app, const LoginPage()));
    expect(
      find.byKey(const ValueKey('app-brand-logo-horizontal')),
      findsOneWidget,
    );
    expect(find.text('DDR001 Levantamientos'), findsOneWidget);
    expect(find.byKey(const Key('login_name')), findsOneWidget);
    expect(find.byKey(const Key('login_email')), findsOneWidget);
    expect(find.byKey(const Key('login_phone')), findsOneWidget);
    expect(find.byKey(const Key('login_crew')), findsOneWidget);
    expect(find.byKey(const Key('login_submit')), findsOneWidget);
    expect(find.byKey(const Key('login_version')), findsOneWidget);
    expect(find.text('v0.1.0'), findsOneWidget);
    expect(find.text('Nombre'), findsOneWidget);
    expect(find.text('Correo'), findsOneWidget);
    expect(find.text('Teléfono'), findsOneWidget);
    expect(find.text('Cuadrilla'), findsOneWidget);
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields, hasLength(4));
    expect(fields[0].key, const Key('login_name'));
    expect(fields[1].key, const Key('login_email'));
    expect(fields[2].key, const Key('login_phone'));
    expect(fields[3].key, const Key('login_crew'));
    expect(fields[2].keyboardType, TextInputType.phone);
    expect(find.text('Contraseña'), findsNothing);
    expect(find.text('Acceso seguro'), findsNothing);
    expect(find.text('Campo'), findsNothing);
    expect(find.text('Administración'), findsNothing);
    expect(find.textContaining('Field'), findsNothing);
    expect(find.textContaining('Admin'), findsNothing);
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
      Colors.white,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('login_email')))
          .style
          ?.color,
      const Color(0xffcbd1dd),
    );
    final submit = tester.widget<FilledButton>(
      find.byKey(const Key('login_submit')),
    );
    expect(submit.style?.backgroundColor?.resolve(const {}), Colors.white);
    expect(
      submit.style?.foregroundColor?.resolve(const {}),
      const Color(0xff2848b8),
    );
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
  testWidgets('home Mis levantamientos selects shared surveys tab', (
    tester,
  ) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(page(app, const MainShell()));
    await tester.tap(find.byKey(const Key('my_surveys_action')));
    await tester.pumpAndSettle();
    expect(find.text('Mis levantamientos'), findsOneWidget);
  });
  testWidgets('bottom navigation labels stay on one line responsively', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 700),
          textScaler: TextScaler.linear(2),
        ),
        child: page(app, const MainShell()),
      ),
    );
    await tester.pumpAndSettle();
    for (final label in const ['INICIO', 'LEVANTAMIENTOS', 'MAPA', 'PERFIL']) {
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: label.length),
      );
      expect(
        boxes.map((box) => (box.top, box.bottom)).toSet(),
        hasLength(1),
        reason: label,
      );
    }
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
    expect(find.byKey(const Key('account_number')), findsOneWidget);
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
  testWidgets('survey thumbnails cap decoded dimensions', (tester) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    final survey = (await tester.runAsync(() => app.createSurvey('Thumb')))!;
    const photoId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    final photo = ConstructionPhoto(
      id: photoId,
      surveyId: survey.id,
      localPath: 'assets/branding/logo_symbol.png',
      thumbnailPath: 'assets/branding/logo_symbol.png',
      sha256: 'a' * 64,
      capturedAt: DateTime.utc(2026, 8, 30),
      stepNumber: 1,
      location: GeoPoint(
        latitude: 29,
        longitude: -110,
        accuracy: 5,
        capturedAt: DateTime.utc(2026, 8, 30),
      ),
      syncState: PhotoSyncState.confirmed,
    );
    app.photos = [photo];
    app.surveys = [
      survey.copyWith(
        steps: [
          survey.steps.first.copyWith(photoIds: const [photoId]),
          ...survey.steps.skip(1),
        ],
      ),
    ];

    await tester.pumpWidget(page(app, SurveyDetailPage(surveyId: survey.id)));

    final thumbnail = tester.widget<Image>(
      find.descendant(
        of: find.byKey(const Key('photo_$photoId')),
        matching: find.byType(Image),
      ),
    );
    final provider = thumbnail.image as ResizeImage;
    expect(provider.width, 264);
    expect(provider.height, 264);
    expect(thumbnail.filterQuality, FilterQuality.low);
  });
  testWidgets('survey gallery reveals thumbnails in bounded pages', (
    tester,
  ) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    final survey = (await tester.runAsync(() => app.createSurvey('Paged')))!;
    final capturedAt = DateTime.utc(2026, 8, 30);
    final photos = List.generate(30, (index) {
      final id = 'bbbbbbbb-bbbb-4bbb-8bbb-${index.toString().padLeft(12, '0')}';
      return ConstructionPhoto(
        id: id,
        surveyId: survey.id,
        localPath: 'assets/branding/logo_symbol.png',
        thumbnailPath: 'assets/branding/logo_symbol.png',
        sha256: 'a' * 64,
        capturedAt: capturedAt.add(Duration(milliseconds: index)),
        stepNumber: 1,
        location: GeoPoint(
          latitude: 29,
          longitude: -110,
          accuracy: 5,
          capturedAt: capturedAt,
        ),
        syncState: PhotoSyncState.confirmed,
      );
    });
    app.photos = photos;
    app.surveys = [
      survey.copyWith(
        steps: [
          survey.steps.first.copyWith(
            photoIds: photos.map((photo) => photo.id).toList(),
          ),
          ...survey.steps.skip(1),
        ],
      ),
    ];

    await tester.pumpWidget(page(app, SurveyDetailPage(surveyId: survey.id)));

    expect(
      find.byKey(const Key('photo_bbbbbbbb-bbbb-4bbb-8bbb-000000000023')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('photo_bbbbbbbb-bbbb-4bbb-8bbb-000000000024')),
      findsNothing,
    );
    expect(find.text('Mostrar más fotos (6 restantes)'), findsOneWidget);
    tester
        .widget<TextButton>(find.byKey(const Key('more_photos_1')))
        .onPressed!();
    await tester.pump();
    expect(
      find.byKey(const Key('photo_bbbbbbbb-bbbb-4bbb-8bbb-000000000029')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('more_photos_1')), findsNothing);
  });
  testWidgets('step 6 requests cardinal directions before additional photos', (
    tester,
  ) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    final survey = (await tester.runAsync(() => app.createSurvey('Final')))!;
    app.surveys = [
      survey.copyWith(
        currentStep: 5,
        steps: List.generate(
          6,
          (index) => SurveyStep(
            number: index + 1,
            state: index == 5 ? StepState.open : StepState.completedLocal,
          ),
        ),
      ),
    ];
    await tester.pumpWidget(page(app, SurveyDetailPage(surveyId: survey.id)));
    await tester.scrollUntilVisible(
      find.byKey(const Key('step6_next_photo')),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Foto requerida: NORTE'), findsOneWidget);
    expect(find.text('NORTE'), findsOneWidget);
    expect(find.text('ESTE'), findsOneWidget);
    expect(find.text('SUR'), findsOneWidget);
    expect(find.text('OESTE'), findsOneWidget);
  });
  testWidgets('surveys offers search, filters and update action', (tester) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    await tester.pumpWidget(page(app, const SurveysPage()));
    expect(find.byKey(const Key('survey_search')), findsOneWidget);
    expect(find.byKey(const Key('survey_refresh')), findsOneWidget);
    expect(find.text('Actualizar'), findsOneWidget);
    expect(find.text('Todos'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'En proceso'), findsOneWidget);
  });
  testWidgets('survey account is rendered instead of Sin cuenta', (
    tester,
  ) async {
    final (app, root) = (await tester.runAsync(
      () => controller(ConstructionRole.contractor),
    ))!;
    addTearDown(() async {
      await Hive.close();
      await root.delete(recursive: true);
    });
    await tester.runAsync(
      () => app.createSurvey('Losa cuenta', accountNumber: '890'),
    );
    await tester.pumpWidget(page(app, const SurveysPage()));
    expect(find.textContaining('890 ·'), findsOneWidget);
    expect(find.textContaining('Sin cuenta'), findsNothing);
  });
  testWidgets('completion feedback supports continue and home choices', (
    tester,
  ) async {
    StepSavedAction? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                result = await showStepSavedDialog(context, step: 1),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Información guardada'), findsOneWidget);
    expect(find.textContaining('guardada en el dispositivo'), findsOneWidget);
    await tester.tap(find.byKey(const Key('saved_continue')));
    await tester.pumpAndSettle();
    expect(result, StepSavedAction.continueSurvey);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('saved_home')));
    await tester.pumpAndSettle();
    expect(result, StepSavedAction.home);
  });
  testWidgets('optional comment label remains visible while focused', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: OptionalCommentField(
            initialValue: null,
            enabled: true,
            onChanged: ignoreComment,
          ),
        ),
      ),
    );
    expect(find.text('Comentario opcional'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('optional_comment_field')),
      'Comentario',
    );
    await tester.pump();
    expect(find.text('Comentario opcional'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('map legend is visible, collapses and reopens', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Stack(children: [MapStatusLegend()])),
      ),
    );
    expect(find.text('Entregable'), findsOneWidget);
    await tester.tap(find.byKey(const Key('collapse_map_legend')));
    await tester.pump();
    expect(find.text('Ejecutado'), findsNothing);
    await tester.tap(find.byKey(const Key('expand_map_legend')));
    await tester.pump();
    expect(find.text('En proceso'), findsOneWidget);
    expect(find.text('Entregado'), findsOneWidget);
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
    expect(find.byKey(const ValueKey('app-brand-logo-symbol')), findsOneWidget);
    expect(find.text('Contratista'), findsWidgets);
    expect(find.text('Nombre'), findsOneWidget);
    expect(find.text('Correo'), findsOneWidget);
    expect(find.text('Teléfono'), findsOneWidget);
    expect(find.text('Cuadrilla'), findsOneWidget);
    expect(find.text('CUADRILLA NORTE'), findsOneWidget);
    expect(find.text('Rol'), findsOneWidget);
    expect(find.text('Dispositivo'), findsOneWidget);
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

  testWidgets(
    'reviewer list and detail identify contractor and survey fields',
    (tester) async {
      final (app, root) = (await tester.runAsync(
        () => controller(ConstructionRole.resident),
      ))!;
      addTearDown(() async {
        await Hive.close();
        await root.delete(recursive: true);
      });
      app.surveys = [reviewSurvey()];
      await tester.pumpWidget(page(app, const ResidentReviewPage()));
      expect(find.textContaining('Contratista: Juan Pérez'), findsOneWidget);
      await tester.tap(find.text('Base Norte'));
      await tester.pumpAndSettle();
      for (final label in const [
        'IDENTIFICADOR DE LA BASE',
        'NÚMERO DE CUENTA',
        'CONTRATISTA',
        'ESTADO',
        'ETAPA',
        'FECHA DE CREACIÓN',
        'ÚLTIMA ACTUALIZACIÓN',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Ejecutado'), findsOneWidget);
      expect(find.text('6/6'), findsOneWidget);

      await tester.tap(find.text('Rechazar'));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField).last);
      expect(field.minLines, 4);
      expect(field.maxLines, 8);
      expect(
        find.text('Describe qué debe corregir el contratista.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'reviewer survey title is global and contractor title remains own',
    (tester) async {
      final (reviewer, reviewerRoot) = (await tester.runAsync(
        () => controller(ConstructionRole.superadmin),
      ))!;
      addTearDown(() async {
        await Hive.close();
        await reviewerRoot.delete(recursive: true);
      });
      reviewer.surveys = [reviewSurvey()];
      await tester.pumpWidget(page(reviewer, const SurveysPage()));
      expect(find.text('Levantamientos'), findsOneWidget);
      expect(find.textContaining('Contratista: Juan Pérez'), findsOneWidget);
      expect(find.byKey(const Key('survey_refresh')), findsOneWidget);
    },
  );
}
