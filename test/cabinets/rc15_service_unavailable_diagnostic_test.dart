// Characterization of shipped RC15, not acceptance of its ambiguous taxonomy.
// No real network: adapters and synthetic temporary Hive only.
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/core/network/api_client.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_legacy_scope.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_automatic_sync.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'cabinet_api_test.dart' show Adapter, response;
import 'harness.dart';
import 'legacy_automatic_sync_test.dart' show seed;
import 'legacy_recovery_test.dart' show LegacyRemote;

DioException httpFailure(int status) {
  final request = RequestOptions(path: '/construction/cabinets/resolve');
  return DioException(
    requestOptions: request,
    type: DioExceptionType.badResponse,
    response: Response(requestOptions: request, statusCode: status),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final type in DioExceptionType.values) {
    test('RC15 no-response $type collapses to SERVICE_UNAVAILABLE', () {
      final issue = LegacyAutomaticSync.classify(
        DioException(
          requestOptions: RequestOptions(
            path: '/construction/cabinets/resolve',
          ),
          type: type,
          error: type == DioExceptionType.connectionError
              ? const SocketException('synthetic connection failure')
              : null,
        ),
      );
      expect(issue.code, 'SERVICE_UNAVAILABLE');
      expect(issue.global, isTrue);
    });
  }
  for (final status in [408, 429, 500, 502, 503, 504]) {
    test('RC15 HTTP $status is a shared service stop', () {
      final issue = LegacyAutomaticSync.classify(httpFailure(status));
      expect(issue.code, 'SERVICE_UNAVAILABLE');
      expect(issue.global, isTrue);
    });
  }
  for (final status in [401, 403]) {
    test('HTTP $status is authentication, not service', () {
      final issue = LegacyAutomaticSync.classify(httpFailure(status));
      expect(issue.code, 'AUTHENTICATION');
      expect(issue.global, isTrue);
    });
  }
  for (final status in [404, 409, 413, 422]) {
    test('HTTP $status remains individual', () {
      final issue = LegacyAutomaticSync.classify(httpFailure(status));
      expect(issue.code, 'HTTP_$status');
      expect(issue.global, isFalse);
    });
  }
  for (final mode in ['permit', 'actor', 'session', 'installation']) {
    test(
      'real interceptor rejects $mode locally but reports unavailable',
      () async {
        final sessions = Sessions()..value = testSession();
        var calls = 0;
        final dio = Dio()
          ..httpClientAdapter = Adapter((r) async {
            calls++;
            return response(200, {});
          });
        final api = ApiClient(
          config: AppConfig(
            environment: 'test',
            apiBaseUrl: Uri.parse('http://localhost:3003/api/v1'),
          ),
          sessions: sessions,
          dio: dio,
        );
        final permit = api.beginCabinetRecovery(cabinetIds: {'synthetic'});
        try {
          await dio.get<dynamic>(
            '/construction/cabinets/resolve',
            options: Options(
              extra: {
                if (mode != 'permit') 'cabinetRecoveryPermit': permit,
                'expectedActor': mode == 'actor'
                    ? 'other-actor'
                    : sessions.value!.userId,
                'expectedSessionId': mode == 'session'
                    ? 'other-session'
                    : sessions.value!.sessionId,
                if (mode == 'installation')
                  'expectedInstallationId': 'other-installation',
              },
            ),
          );
          fail('Expected a local guard rejection');
        } on DioException catch (e) {
          expect(e.response, isNull);
          expect(e.type, DioExceptionType.unknown);
          expect(LegacyAutomaticSync.classify(e).code, 'SERVICE_UNAVAILABLE');
        } finally {
          expect(calls, 0);
          expect(api.cabinetRequestsInFlight, isFalse);
          api.endCabinetRecovery(permit);
          dio.close();
        }
      },
    );
  }
  test('malformed JSON response is not evidence of server outage', () async {
    final dio = Dio()
      ..httpClientAdapter = Adapter(
        (r) async => ResponseBody.fromString(
          '{invalid',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        ),
      );
    try {
      await dio.get<dynamic>('/construction/cabinets/resolve');
      fail('Expected decoding error');
    } on DioException catch (e) {
      expect(e.error, isA<FormatException>());
      expect(LegacyAutomaticSync.classify(e).code, 'SERVICE_UNAVAILABLE');
    } finally {
      dio.close();
    }
  });
  for (final status in [404, 503]) {
    test(
      'batch HTTP $status preserves documents and explains 1/9 versus continue',
      () async {
        final h = Harness();
        final remote = LegacyRemote();
        await h.open(remote: remote);
        try {
          h.app.online = true;
          final before = <String, String>{};
          for (var i = 0; i < legacyAutomaticUids.length; i++) {
            final id = await seed(
              h,
              remote,
              legacyAutomaticUids.elementAt(i),
              i + 1,
            );
            before[id] = jsonEncode(h.store.read(id)!.json);
          }
          var calls = 0;
          final batch = LegacyAutomaticSync(
            h.controller,
            executor: (id, permit) async {
              calls++;
              if (calls == 1) throw httpFailure(status);
              throw const HistoricalBatchIssue(
                'SYNTHETIC_ONLY',
                'No transmission',
              );
            },
          );
          await batch.runFromHome(() async {});
          final rows = objects(batch.result!['rows']);
          expect(calls, status == 503 ? 1 : 10);
          expect(
            rows.where((r) => r['status'] == 'not_processed').length,
            status == 503 ? 9 : 0,
          );
          if (status == 503) {
            expect(
              batch.summary,
              contains('Recuperación histórica no iniciada'),
            );
            expect(batch.summary, contains('Históricos procesados: 1 de 10'));
          }
          for (final entry in before.entries) {
            expect(jsonEncode(h.store.read(entry.key)!.json), entry.value);
          }
          expect(remote.calls, isEmpty);
        } finally {
          await h.close();
        }
      },
    );
  }
  test('configured production host and finite timeouts, no request', () {
    final config = AppConfig.fromEnvironment(
      environment: 'production',
      baseUrl: AppConfig.productionHttpApiBaseUrl,
    );
    final api = ApiClient(config: config, sessions: Sessions());
    expect(api.dio.options.baseUrl, 'http://cifra.aquafim.com:3002/api/v1');
    expect(api.dio.options.connectTimeout, const Duration(seconds: 20));
    expect(api.dio.options.sendTimeout, const Duration(seconds: 30));
    expect(api.dio.options.receiveTimeout, const Duration(seconds: 30));
    api.dio.close();
  });
}
