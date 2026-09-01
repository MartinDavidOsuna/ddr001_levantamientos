import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:ddr001_levantamientos/core/network/api_client.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class MemorySessions implements SessionStore {
  FieldSession? value = const FieldSession(
    sessionId: 'session',
    userId: 'user',
    accessToken: 'expired',
    refreshToken: 'refresh',
    installationId: 'installation',
    name: 'Field',
    email: 'field@example.com',
    phone: '1234567890',
  );

  @override
  Future<void> clear() async => value = null;
  @override
  Future<String> installationId() async => 'installation';
  @override
  Future<FieldSession?> read() async => value;
  @override
  Future<void> save(FieldSession value) async => this.value = value;
}

class ScriptedAdapter implements HttpClientAdapter {
  ScriptedAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(int status, Map<String, dynamic> value) =>
    ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );

ApiClient client(MemorySessions sessions, ScriptedAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return ApiClient(
    config: AppConfig.fromEnvironment(
      environment: 'test',
      baseUrl: 'http://127.0.0.1:3003/api/v1',
    ),
    sessions: sessions,
    dio: dio,
  );
}

void main() {
  test('401 refreshes once and replays the original request', () async {
    final sessions = MemorySessions();
    var resourceCalls = 0;
    var refreshCalls = 0;
    final api = client(
      sessions,
      ScriptedAdapter((options) async {
        if (options.path.endsWith('/field-sessions/refresh')) {
          refreshCalls++;
          return jsonResponse(200, {
            'accessToken': 'rotated-access',
            'refreshToken': 'rotated-refresh',
          });
        }
        resourceCalls++;
        return resourceCalls == 1
            ? jsonResponse(401, {'code': 'ACCESS_EXPIRED'})
            : jsonResponse(200, {'ok': true});
      }),
    );

    final response = await api.dio.get<Map<String, dynamic>>('/resource');

    expect(response.data?['ok'], isTrue);
    expect(resourceCalls, 2);
    expect(refreshCalls, 1);
    expect(sessions.value?.accessToken, 'rotated-access');
  });

  test(
    'refresh timeout preserves the session and offline work authority',
    () async {
      final sessions = MemorySessions();
      final original = sessions.value;
      final api = client(
        sessions,
        ScriptedAdapter((options) async {
          if (options.path.endsWith('/field-sessions/refresh')) {
            throw DioException(
              requestOptions: options,
              type: DioExceptionType.receiveTimeout,
            );
          }
          return jsonResponse(401, {'code': 'ACCESS_EXPIRED'});
        }),
      );

      await expectLater(
        api.dio.get<void>('/resource'),
        throwsA(isA<DioException>()),
      );

      expect(sessions.value, same(original));
    },
  );

  test('definitive refresh revocation clears only the session', () async {
    final sessions = MemorySessions();
    final api = client(
      sessions,
      ScriptedAdapter(
        (options) async => options.path.endsWith('/field-sessions/refresh')
            ? jsonResponse(401, {'code': 'SESSION_REVOKED'})
            : jsonResponse(401, {'code': 'ACCESS_EXPIRED'}),
      ),
    );

    await expectLater(
      api.dio.get<void>('/resource'),
      throwsA(isA<DioException>()),
    );

    expect(sessions.value, isNull);
  });
}
