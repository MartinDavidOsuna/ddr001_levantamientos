import 'dart:convert';
import 'package:ddr001_levantamientos/features/surveys/survey_photo_gallery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
  testWidgets(
    'starts at selected photo, swipes with finite bounds and loads on demand',
    (tester) async {
      final loads = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: SurveyPhotoGallery(
            title: 'Cimbrado',
            initialIndex: 1,
            photos: List.generate(
              3,
              (i) => SurveyGalleryPhoto(
                id: '$i',
                loadOriginal: () async {
                  loads.add(i);
                  return bytes;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 de 3'), findsOneWidget);
      expect(loads, [1]);
      final pager = find.byKey(const Key('survey_photo_pager'));
      await tester.drag(pager, const Offset(-650, 0));
      await tester.pumpAndSettle();
      expect(find.text('3 de 3'), findsOneWidget);
      expect(loads, [1, 2]);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('gallery_next')))
            .onPressed,
        isNull,
      );
      await tester.drag(pager, const Offset(-650, 0));
      await tester.pumpAndSettle();
      expect(find.text('3 de 3'), findsOneWidget);
      for (var i = 0; i < 2; i++) {
        await tester.drag(pager, const Offset(650, 0));
        await tester.pumpAndSettle();
      }
      expect(find.text('1 de 3'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('gallery_previous')))
            .onPressed,
        isNull,
      );
      await tester.drag(pager, const Offset(650, 0));
      await tester.pumpAndSettle();
      expect(find.text('1 de 3'), findsOneWidget);
      expect(find.text('Cimbrado'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('single image cannot move and failed download can retry', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SurveyPhotoGallery(
          title: 'Corrección 1',
          initialIndex: 0,
          photos: [
            SurveyGalleryPhoto(
              id: 'one',
              loadOriginal: () async {
                if (attempts++ == 0) throw Exception('offline');
                return bytes;
              },
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Imagen no disponible temporalmente'), findsOneWidget);
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(find.text('1 de 1'), findsOneWidget);
    expect(find.text('Imagen no disponible temporalmente'), findsNothing);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('gallery_next')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('gallery_previous')))
          .onPressed,
      isNull,
    );
  });
  testWidgets(
    'swipe up closes carousel; zoom gestures stay inside image until exiting',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => SurveyPhotoGallery(
                    title: 'Preparación del terreno',
                    initialIndex: 0,
                    photos: List.generate(
                      2,
                      (i) => SurveyGalleryPhoto(
                        id: '$i',
                        loadOriginal: () async => bytes,
                      ),
                    ),
                  ),
                ),
                child: const Text('Abrir'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      final title = tester.widget<Text>(find.text('Preparación del terreno'));
      expect(title.style!.fontSize, closeTo(16 * 1.15, .001));
      await tester.tap(find.byKey(const Key('gallery_enter_zoom')));
      await tester.pumpAndSettle();
      expect(find.text('Volver al carrusel'), findsOneWidget);
      await tester.tap(find.byKey(const Key('gallery_zoom_in')));
      await tester.pumpAndSettle();
      expect(find.text('150%'), findsOneWidget);
      final viewer = find.byKey(const Key('gallery_zoom_viewer'));
      final controller = tester
          .widget<InteractiveViewer>(viewer)
          .transformationController!;
      final before = controller.value.clone();
      await tester.drag(viewer, const Offset(-60, -60));
      await tester.pumpAndSettle();
      expect(controller.value, isNot(before));
      expect(find.text('1 de 2'), findsOneWidget);
      expect(find.byType(SurveyPhotoGallery), findsOneWidget);
      await tester.tap(find.byKey(const Key('gallery_zoom_out')));
      await tester.pumpAndSettle();
      expect(find.text('100%'), findsOneWidget);
      final center = tester.getCenter(viewer);
      final left = await tester.startGesture(
        center - const Offset(40, 0),
        pointer: 1,
      );
      final right = await tester.startGesture(
        center + const Offset(40, 0),
        pointer: 2,
      );
      await tester.pump();
      await left.moveTo(center - const Offset(60, 0));
      await right.moveTo(center + const Offset(60, 0));
      await tester.pump();
      await left.moveTo(center - const Offset(100, 0));
      await right.moveTo(center + const Offset(100, 0));
      await tester.pump();
      await left.up();
      await right.up();
      await tester.pumpAndSettle();
      expect(controller.value.getMaxScaleOnAxis(), greaterThan(1));
      await tester.tap(find.byKey(const Key('gallery_exit_zoom')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gallery_zoom_viewer')), findsNothing);
      await tester.drag(
        find.byKey(const Key('survey_photo_pager')),
        const Offset(-650, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 de 2'), findsOneWidget);
      await tester.drag(
        find.byKey(const Key('survey_photo_pager')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SurveyPhotoGallery), findsNothing);
      expect(find.text('Abrir'), findsOneWidget);
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('gallery_enter_zoom')));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const Key('gallery_header')),
        const Offset(0, -150),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SurveyPhotoGallery), findsNothing);
    },
  );
}
