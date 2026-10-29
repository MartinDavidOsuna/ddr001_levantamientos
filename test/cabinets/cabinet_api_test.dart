import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:ddr001_levantamientos/core/network/api_client.dart';
import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/data/remote/construction_api.dart';
import 'harness.dart';

class Adapter implements HttpClientAdapter {
  Adapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody response(int code, Object json) => ResponseBody.fromString(
  jsonEncode(json),
  code,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);
void main() {
  test(
    'base search paginates past first hundred and preserves query',
    () async {
      final sessions = Sessions()..value = testSession();
      final pages = <int>[];
      final dio = Dio()
        ..httpClientAdapter = Adapter((r) async {
          expect(r.queryParameters['search'], 'BASE');
          final page = r.queryParameters['page'] as int;
          pages.add(page);
          return response(200, {
            'total': 205,
            'items': List.generate(
              page == 3 ? 5 : 100,
              (i) => {'survey_id': '${(page - 1) * 100 + i}'},
            ),
          });
        });
      final api = ApiClient(
        config: AppConfig(
          environment: 'test',
          apiBaseUrl: Uri.parse('http://localhost:3003/api/v1'),
        ),
        sessions: sessions,
        dio: dio,
      );
      final remote = ConstructionApi(
        api,
        sessions,
        PackageInfo(
          appName: 'TEST',
          packageName: 'TEST',
          version: '1',
          buildNumber: '1',
        ),
      );
      expect(await remote.list(resident: true, search: 'BASE'), hasLength(205));
      expect(pages, [1, 2, 3]);
    },
  );
  test(
    'actor binding refuses sending a queued command under a different session',
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
      await expectLater(
        api.dio.post(
          '/construction/cabinets/test/commands',
          options: Options(extra: {'expectedActor': 'someone-else'}),
        ),
        throwsA(isA<DioException>()),
      );
      expect(calls, 0);
    },
  );
}
