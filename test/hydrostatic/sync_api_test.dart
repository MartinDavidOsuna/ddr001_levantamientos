import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync_api.dart';
import '../core/api_client_resilience_test.dart' as transport;

void main() {
  const scope = HydrostaticSyncIdentity('user', 'session', 'installation');
  test(
    'HAPI-2 paths headers exact payload and reads use bound session',
    () async {
      final sessions = transport.MemorySessions();
      final seen = <RequestOptions>[];
      final api = HydrostaticSyncApi(
        transport.client(
          sessions,
          transport.ScriptedAdapter((o) async {
            seen.add(o);
            return transport.jsonResponse(200, {'ok': true});
          }),
        ),
      );
      final c = <String, dynamic>{
        'operationId': 'stable-op',
        'expectedVersion': 3,
        'payloadJson': '{"original": "bytes"}',
      };
      await api.capabilities(scope);
      await api.command('test-id', c, scope);
      await api.receipt('test-id', 'stable-op', scope);
      await api.status('test-id', 4, scope);
      expect(seen.map((o) => o.path), [
        '/construction/hydrostatic-tests/capabilities',
        '/construction/hydrostatic-tests/test-id/commands',
        '/construction/hydrostatic-tests/test-id/operations/stable-op',
        '/construction/hydrostatic-tests/test-id/sync-status',
      ]);
      expect(seen[1].headers['Idempotency-Key'], 'stable-op');
      expect(seen[1].headers['If-Match'], '"hydrostatic-3"');
      expect(seen[1].data, c);
      expect(seen[3].queryParameters, {'sourceRevision': 4});
      for (final o in seen) {
        expect(o.extra['expectedSessionId'], 'session');
        expect(o.extra['expectedInstallationId'], 'installation');
      }
    },
  );
  for (final changed in ['user', 'session', 'installation']) {
    test('transport blocks $changed change before network', () async {
      final sessions = transport.MemorySessions();
      int calls = 0;
      final api = HydrostaticSyncApi(
        transport.client(
          sessions,
          transport.ScriptedAdapter((o) async {
            calls++;
            return transport.jsonResponse(200, {});
          }),
        ),
      );
      sessions.value = FieldSession(
        sessionId: changed == 'session' ? 'new-session' : 'session',
        userId: changed == 'user' ? 'new-user' : 'user',
        installationId: changed == 'installation'
            ? 'new-installation'
            : 'installation',
        accessToken: 'synthetic',
        refreshToken: 'synthetic',
        name: 'TEST',
        email: 'test@example.invalid',
        phone: '',
      );
      await expectLater(
        api.command('id', {'operationId': 'op', 'expectedVersion': 0}, scope),
        throwsA(isA<HydrostaticSyncFailure>()),
      );
      expect(calls, 0);
    });
  }
  test('401 refresh replays exact command only under same session', () async {
    final sessions = transport.MemorySessions();
    final commands = <dynamic>[];
    final api = HydrostaticSyncApi(
      transport.client(
        sessions,
        transport.ScriptedAdapter((o) async {
          if (o.path == '/field-sessions/refresh') {
            return transport.jsonResponse(200, {
              'accessToken': 'test-rotated',
              'refreshToken': 'test-refresh',
            });
          }
          commands.add(o.data);
          return commands.length == 1
              ? transport.jsonResponse(401, {'code': 'ACCESS_EXPIRED'})
              : transport.jsonResponse(200, {'receiptState': 'COMMITTED'});
        }),
      ),
    );
    await api.command('id', {
      'operationId': 'op',
      'expectedVersion': 0,
      'payloadJson': '{"exact":true}',
    }, scope);
    expect(commands, hasLength(2));
    expect(commands[0], commands[1]);
  });
  test(
    'same-user session swap during refresh never replays into new session',
    () async {
      final sessions = transport.MemorySessions();
      int calls = 0;
      final api = HydrostaticSyncApi(
        transport.client(
          sessions,
          transport.ScriptedAdapter((o) async {
            if (o.path == '/field-sessions/refresh') {
              sessions.value = const FieldSession(
                sessionId: 'other',
                userId: 'user',
                installationId: 'installation',
                accessToken: 'new-test',
                refreshToken: 'new-test',
                name: 'TEST',
                email: 'test@example.invalid',
                phone: '',
              );
              return transport.jsonResponse(200, {
                'accessToken': 'old-test-rotation',
                'refreshToken': 'old-test-rotation',
              });
            }
            calls++;
            return transport.jsonResponse(401, {'code': 'ACCESS_EXPIRED'});
          }),
        ),
      );
      await expectLater(
        api.command('id', {'operationId': 'op', 'expectedVersion': 0}, scope),
        throwsA(isA<HydrostaticSyncFailure>()),
      );
      expect(calls, 1);
      expect(sessions.value!.sessionId, 'other');
    },
  );
  test(
    'network errors are sanitized instead of persisting arbitrary response',
    () async {
      final api = HydrostaticSyncApi(
        transport.client(
          transport.MemorySessions(),
          transport.ScriptedAdapter(
            (o) async => transport.jsonResponse(409, {
              'code': 'REVISION_CONFLICT',
              'message': 'PRIVATE_NOT_FOR_STORAGE',
            }),
          ),
        ),
      );
      await expectLater(
        api.command('id', {'operationId': 'op', 'expectedVersion': 0}, scope),
        throwsA(
          isA<HydrostaticSyncFailure>().having(
            (e) => e.toString(),
            'safe code',
            'REVISION_CONFLICT',
          ),
        ),
      );
    },
  );
}
