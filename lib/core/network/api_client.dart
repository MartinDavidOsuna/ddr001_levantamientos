import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../config/app_config.dart';
import '../security/session_store.dart';

class ApiClient {
  ApiClient({required AppConfig config, required this._sessions, Dio? dio})
    : dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: config.apiBaseUrl.toString().replaceFirst(
                RegExp(r'/$'),
                '',
              ),
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 30),
            ),
          ) {
    this.dio.interceptors.add(
      InterceptorsWrapper(onRequest: _request, onError: _error),
    );
  }
  final Dio dio;
  final SessionStore _sessions;
  Future<FieldSession?>? _refreshing;
  Future<void> _request(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    options.headers['X-Request-ID'] = const Uuid().v4();
    if (options.extra['skipAuth'] != true) {
      final session = await _sessions.read();
      if (session != null) {
        options.headers['Authorization'] = 'Bearer ${session.accessToken}';
      }
    }
    if (kDebugMode) {
      debugPrint(
        '[API] ${options.method} ${options.path.replaceAll(RegExp(r'[0-9a-f-]{36}', caseSensitive: false), ':id')}',
      );
    }
    handler.next(options);
  }

  Future<void> _error(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    final request = error.requestOptions;
    if (error.response?.statusCode != 401 ||
        request.extra['skipAuth'] == true ||
        request.extra['refreshed'] == true ||
        request.path == '/field-sessions/refresh' ||
        request.path == '/admin/auth/refresh') {
      handler.next(error);
      return;
    }
    try {
      final session = await refresh();
      if (session == null) {
        handler.next(error);
        return;
      }
      final response = await dio.fetch<dynamic>(
        request.copyWith(
          headers: {
            ...request.headers,
            'Authorization': 'Bearer ${session.accessToken}',
          },
          extra: {...request.extra, 'refreshed': true},
        ),
      );
      handler.resolve(response);
    } on DioException catch (next) {
      final code = next.response?.data is Map
          ? '${(next.response!.data as Map)['code']}'
          : '';
      if (const {
        'SESSION_REVOKED',
        'USER_INACTIVE',
        'DEVICE_BLOCKED',
        'DEVICE_BINDING_REVOKED',
      }.contains(code)) {
        await _sessions.clear();
      }
      handler.next(next);
    }
  }

  Future<FieldSession?> refresh() {
    if (_refreshing != null) return _refreshing!;
    final future = _refresh();
    _refreshing = future;
    return future.whenComplete(() => _refreshing = null);
  }

  Future<FieldSession?> _refresh() async {
    final current = await _sessions.read();
    if (current == null) return null;
    final response = await dio.post<Map<String, dynamic>>(
      current.kind == SessionKind.admin
          ? '/admin/auth/refresh'
          : '/field-sessions/refresh',
      data: {'refreshToken': current.refreshToken},
      options: Options(extra: {'skipAuth': true}),
    );
    final data = response.data ?? const {};
    final rotated = current.copyWith(
      accessToken: '${data['accessToken']}',
      refreshToken: '${data['refreshToken']}',
    );
    await _sessions.save(rotated);
    return rotated;
  }
}
