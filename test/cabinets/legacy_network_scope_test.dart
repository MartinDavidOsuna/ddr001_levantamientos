import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/core/network/api_client.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_api.dart';
import 'cabinet_api_test.dart' show Adapter, response;
import 'harness.dart' show Sessions, testSession;

void main() {
  late ApiClient api;
  late Dio dio;
  late Sessions sessions;
  late List<String> calls;
  setUp(() {
    calls = [];
    sessions = Sessions()..value = testSession();
    dio = Dio()
      ..httpClientAdapter = Adapter((r) async {
        calls.add('${r.method} ${r.path}');
        return response(200, {});
      });
    api = ApiClient(
      config: AppConfig(
        environment: 'test',
        apiBaseUrl: Uri.parse('http://127.0.0.1:3003/api/v1'),
      ),
      sessions: sessions,
      dio: dio,
    );
  });
  tearDown(() => dio.close(force: true));
  test(
    'network gate rejects automatic, foreign IDs and unapproved operation even with permit',
    () async {
      final permit = api.beginCabinetRecovery(cabinetIds: {'pilot'});
      final ordinary = CabinetApi(api);
      final scoped = CabinetApi(api)
        ..recoveryPermit = permit
        ..operationActor = sessions.value!.userId
        ..recoverySessionId = sessions.value!.sessionId;
      await expectLater(ordinary.get('/pilot'), throwsA(isA<DioException>()));
      await expectLater(
        scoped.command('pilot', {
          'operationId': 'close',
          'type': 'registration_close',
        }),
        throwsA(isA<DioException>()),
      );
      api.authorizeCabinetRecovery(
        permit,
        operations: {'close'},
        photos: {'photo'},
      );
      await expectLater(
        scoped.command('other', {
          'operationId': 'close',
          'type': 'registration_close',
        }),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        scoped.command('pilot', {
          'operationId': 'not-approved',
          'type': 'parts_validate',
        }),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        scoped.command('pilot', {'operationId': 'close', 'type': 'register'}),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        scoped.verify('pilot', ['foreign-photo']),
        throwsA(isA<DioException>()),
      );
      await expectLater(
        scoped.deleteCabinet('pilot', {}),
        throwsA(isA<DioException>()),
      );
      expect(calls, isEmpty);
      await scoped.get('/pilot');
      await scoped.command('pilot', {
        'operationId': 'close',
        'type': 'registration_close',
      });
      await scoped.verify('pilot', ['photo']);
      expect(calls.length, 3);
      // Other modules remain operational, without cabinet access.
      await dio.get('/construction/base-surveys');
      expect(calls.length, 4);
      api.endCabinetRecovery(permit);
      await ordinary.get('/other');
      expect(calls.length, 5);
    },
  );
  test(
    'in-flight cabinet request prevents entry; completed/error requests release accounting',
    () async {
      final started = Completer<void>(), finish = Completer<void>();
      dio.httpClientAdapter = Adapter((r) async {
        started.complete();
        await finish.future;
        return response(503, {});
      });
      final pending = CabinetApi(api).get('/pilot');
      final failure = expectLater(pending, throwsA(isA<DioException>()));
      await started.future;
      expect(
        () => api.beginCabinetRecovery(cabinetIds: {'pilot'}),
        throwsStateError,
      );
      finish.complete();
      await failure;
      final permit = api.beginCabinetRecovery(cabinetIds: {'pilot'});
      api.endCabinetRecovery(permit);
    },
  );
  test(
    'same actor in a different session cannot reuse the recovery permit',
    () async {
      final permit = api.beginCabinetRecovery(cabinetIds: {'pilot'});
      final scoped = CabinetApi(api)
        ..recoveryPermit = permit
        ..operationActor = sessions.value!.userId
        ..recoverySessionId = sessions.value!.sessionId;
      api.authorizeCabinetRecovery(permit, operations: {'close'}, photos: {});
      sessions.value = testSession();
      await expectLater(
        scoped.command('pilot', {
          'operationId': 'close',
          'type': 'registration_close',
        }),
        throwsA(isA<DioException>()),
      );
      expect(calls, isEmpty);
      api.endCabinetRecovery(permit);
    },
  );
}
