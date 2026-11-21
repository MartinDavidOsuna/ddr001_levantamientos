import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/features/surveys/survey_detail_page.dart';
import '../widgets/build_one_widgets_test.dart' as fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final detail in [true, false]) {
    for (final pending in [true, false]) {
      test(
        '${detail ? "detail" : "list"} refresh updates existing canonical location; pending=$pending',
        () async {
          final row = <String, dynamic>{
            'survey_id': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'contractor_user_id': 'u',
            'crew': '1',
            'status': 'executed',
            'current_step': 6,
            'canonical_latitude': 29.123,
            'canonical_longitude': -110.456,
            'canonical_accuracy': 5,
            'canonical_set_at': '2026-11-01T10:00:00Z',
            'updated_at': '2026-11-01T11:00:00Z',
          };
          final dio = Dio()
            ..interceptors.add(
              InterceptorsWrapper(
                onRequest: (options, handler) {
                  expect(options.method, 'GET');
                  handler.resolve(
                    Response(
                      requestOptions: options,
                      statusCode: 200,
                      data: options.path.endsWith('/base-surveys')
                          ? {
                              'items': [row],
                              'total': 1,
                            }
                          : row,
                    ),
                  );
                },
              ),
            );
          final (app, root) = await fixture.controller(
            ConstructionRole.resident,
            dio: dio,
          );
          try {
            final survey = fixture.reviewSurvey().copyWith(
              syncState: pending ? SyncState.pending : SyncState.synchronized,
            );
            app.surveys = [survey];
            final beforeSteps = survey.steps.map((s) => s.toJson()).toList();
            final queueBefore = app.queue.toList();
            if (detail) {
              await app.loadSurveyDetail(survey.id);
            } else {
              await app.refreshServer();
            }
            expect(
              app.survey(survey.id).canonicalLocation?.latitude,
              pending ? isNull : 29.123,
            );
            expect(
              app.survey(survey.id).steps.map((s) => s.toJson()).toList(),
              beforeSteps,
            );
            expect(app.queue, queueBefore);
            expect(
              app.local.surveysBox.values.join(),
              pending ? isNot(contains('29.123')) : contains('29.123'),
            );
            // Older payloads lacking location must not erase a known location.
            row.remove('canonical_latitude');
            row.remove('canonical_longitude');
            if (detail) {
              await app.loadSurveyDetail(survey.id);
            } else {
              await app.refreshServer();
            }
            expect(
              app.survey(survey.id).canonicalLocation?.latitude,
              pending ? isNull : 29.123,
            );
            row['canonical_latitude'] = null;
            row['canonical_longitude'] = null;
            if (detail) {
              await app.loadSurveyDetail(survey.id);
            } else {
              await app.refreshServer();
            }
            expect(
              app.survey(survey.id).canonicalLocation,
              isNull,
              reason:
                  'explicit remote absence differs from an older payload without fields',
            );
          } finally {
            app.dispose();
            await Hive.close();
            await root.delete(recursive: true);
          }
        },
      );
    }
  }

  testWidgets(
    'resident can refresh detail after opening offline without requesting GPS',
    (tester) async {
      var requests = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              expect(options.method, 'GET');
              handler.resolve(
                Response(
                  requestOptions: options,
                  data: {
                    'contractor_user_id': 'u',
                    'crew': '1',
                    'status': 'executed',
                    'current_step': 6,
                    'canonical_latitude': 29.123,
                    'canonical_longitude': -110.456,
                    'canonical_accuracy': 5,
                    'updated_at': '2026-11-01T10:00:00Z',
                  },
                ),
              );
            },
          ),
        );
      await tester.runAsync(() async {
        final (app, root) = await fixture.controller(
          ConstructionRole.resident,
          dio: dio,
        );
        try {
          final survey = fixture.reviewSurvey();
          app.surveys = [survey];
          app.online = false;
          await tester.pumpWidget(
            fixture.page(app, SurveyDetailPage(surveyId: survey.id)),
          );
          expect(find.text('Ubicación no disponible'), findsOneWidget);
          expect(requests, 0);
          app.online = true;
          await tester.pumpWidget(
            fixture.page(app, SurveyDetailPage(surveyId: survey.id)),
          );
          await tester.tap(find.byKey(const Key('survey_refresh_coordinates')));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
          expect(requests, 1);
          expect(find.textContaining('Latitud: 29.123000'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
        } finally {
          app.dispose();
          await Hive.close();
          await root.delete(recursive: true);
        }
      });
    },
  );
}
