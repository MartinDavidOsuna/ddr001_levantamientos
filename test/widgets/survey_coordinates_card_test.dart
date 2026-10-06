import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/features/surveys/survey_coordinates_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class RecordingMapLauncher extends UrlLauncherPlatform {
  @override
  Null get linkDelegate => null;

  final urls = <Uri>[];
  PreferredLaunchMode? mode;
  bool succeeds = true;
  bool throwsError = false;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    urls.add(Uri.parse(url));
    mode = options.mode;
    if (throwsError) throw PlatformException(code: 'unavailable');
    return succeeds;
  }
}

void main() {
  late RecordingMapLauncher launcher;
  setUp(() {
    final original = UrlLauncherPlatform.instance;
    launcher = RecordingMapLauncher();
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = original);
  });

  final point = GeoPoint(
    latitude: 22.2762084,
    longitude: -102.2492321,
    accuracy: 5,
    capturedAt: DateTime.utc(2026, 9, 25),
  );

  testWidgets('coordinate tap opens exact location externally in Google Maps', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SurveyCoordinatesCard(location: point)),
      ),
    );
    await tester.tap(find.text('Latitud: 22.276208\nLongitud: -102.249232'));
    await tester.pump();
    expect(launcher.urls.single.host, 'www.google.com');
    expect(launcher.urls.single.path, '/maps/search/');
    expect(launcher.urls.single.queryParameters, {
      'api': '1',
      'query': '22.2762084,-102.2492321',
    });
    expect(launcher.mode, PreferredLaunchMode.externalApplication);
  });

  testWidgets('missing location has no map action', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SurveyCoordinatesCard(location: null)),
      ),
    );
    expect(find.text('Sin coordenadas registradas'), findsOneWidget);
    expect(find.text('Abrir en Google Maps'), findsNothing);
    expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
    expect(launcher.urls, isEmpty);
  });

  for (final throwsError in [false, true]) {
    testWidgets('failed launch shows feedback (exception: $throwsError)', (
      tester,
    ) async {
      launcher.succeeds = false;
      launcher.throwsError = throwsError;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SurveyCoordinatesCard(location: point)),
        ),
      );
      await tester.tap(find.text('Abrir en Google Maps'));
      await tester.pump();
      expect(find.text('No fue posible abrir Google Maps.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
