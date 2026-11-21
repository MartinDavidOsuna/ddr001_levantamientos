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
      InterceptorsWrapper(
        onRequest: _request,
        onError: _error,
        onResponse: (response, handler) {
          _finishCabinetRequest(response.requestOptions);
          handler.next(response);
        },
      ),
    );
  }
  Object? _cabinetRecoveryPermit;
  int _cabinetRequests = 0;
  bool get cabinetRequestsInFlight => _cabinetRequests != 0;
  Set<String> _recoveryCabinets = {},
      _recoveryOperations = {},
      _recoveryPhotos = {};
  void authorizeCabinetRecovery(
    Object permit, {
    required Set<String> operations,
    required Set<String> photos,
  }) {
    if (!identical(permit, _cabinetRecoveryPermit)) {
      throw StateError('Permiso de soporte no vigente.');
    }
    _recoveryOperations = Set.of(operations);
    _recoveryPhotos = Set.of(photos);
  }

  bool _recoveryRequestAllowed(RequestOptions options) {
    final path = Uri.parse(options.path).path;
    final prefix = '/construction/cabinets';
    final index = path.indexOf(prefix);
    final suffix = index < 0 ? '' : path.substring(index + prefix.length);
    if (options.method == 'GET' && ['/catalog', '/resolve'].contains(suffix)) {
      return true;
    }
    final segments = suffix.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty || !_recoveryCabinets.contains(segments.first)) {
      return false;
    }
    if (options.method == 'GET') return true;
    if (options.method != 'POST') return false;
    final data = options.data;
    if (segments.length == 2 && segments[1] == 'commands' && data is Map) {
      return data['type'] != 'register' &&
          _recoveryOperations.contains(data['operationId']);
    }
    if (segments.length == 2 && segments[1] == 'photos' && data is FormData) {
      final ids = data.fields
          .where((f) => f.key == 'photoId')
          .map((f) => f.value)
          .toList();
      return ids.length == 1 && _recoveryPhotos.contains(ids.single);
    }
    if (segments.length == 3 &&
        segments[1] == 'photos' &&
        segments[2] == 'verify' &&
        data is Map) {
      final ids = data['photoIds'];
      return ids is List &&
          ids.isNotEmpty &&
          ids.every(_recoveryPhotos.contains);
    }
    return false;
  }

  bool get cabinetRecoveryHeld => _cabinetRecoveryPermit != null;

  Object beginCabinetRecovery({required Set<String> cabinetIds}) {
    if (_cabinetRecoveryPermit != null) {
      throw StateError('SUPPORT_HTTP_LOCK_OWNED');
    }
    if (_cabinetRequests != 0) throw StateError('SUPPORT_HTTP_IN_FLIGHT');
    if (cabinetIds.length != 1) {
      throw StateError('Soporte limitado a un expediente.');
    }
    _recoveryCabinets = Set.of(cabinetIds);
    _recoveryOperations = {};
    _recoveryPhotos = {};
    return _cabinetRecoveryPermit = Object();
  }

  void endCabinetRecovery(Object permit) {
    if (!identical(permit, _cabinetRecoveryPermit)) {
      throw StateError('SUPPORT_HTTP_LOCK_OWNED');
    }
    if (_cabinetRequests != 0) throw StateError('SUPPORT_HTTP_IN_FLIGHT');
    _cabinetRecoveryPermit = null;
    _recoveryCabinets = {};
    _recoveryOperations = {};
    _recoveryPhotos = {};
  }

  void _finishCabinetRequest(RequestOptions request) {
    if (request.extra.remove('_cabinetInFlight') == true) _cabinetRequests--;
  }

  final Dio dio;
  final SessionStore _sessions;
  Future<FieldSession?>? _refreshing;
  Future<void> _request(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.path.contains('/construction/cabinets')) {
      if (_cabinetRecoveryPermit != null &&
          (!identical(
                options.extra['cabinetRecoveryPermit'],
                _cabinetRecoveryPermit,
              ) ||
              !_recoveryRequestAllowed(options))) {
        _finishCabinetRequest(options);
        handler.reject(
          DioException(
            requestOptions: options,
            error: 'Gabinetes en soporte selectivo.',
          ),
        );
        return;
      }
      _cabinetRequests++;
      options.extra['_cabinetInFlight'] = true;
    }
    options.headers['X-Request-ID'] = const Uuid().v4();
    if (options.extra['skipAuth'] != true) {
      final session = await _sessions.read();
      final actor = options.extra['expectedActor'];
      if (actor != null &&
          (session?.kind != SessionKind.field ||
              session?.userId.toLowerCase() != actor)) {
        _finishCabinetRequest(options);
        handler.reject(
          DioException(
            requestOptions: options,
            error: 'La sesión cambió; operación conservada.',
          ),
        );
        return;
      }
      final expectedSession = options.extra['expectedSessionId'];
      final expectedInstallation = options.extra['expectedInstallationId'];
      if ((expectedSession != null &&
              session?.sessionId.toLowerCase() != expectedSession) ||
          (expectedInstallation != null &&
              session?.installationId.toLowerCase() != expectedInstallation)) {
        _finishCabinetRequest(options);
        handler.reject(
          DioException(
            requestOptions: options,
            error: 'La sesión o instalación cambió; operación conservada.',
          ),
        );
        return;
      }
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
    _finishCabinetRequest(request);
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
      refreshEndpoint(current.kind),
      data: {'refreshToken': current.refreshToken},
      options: Options(extra: {'skipAuth': true}),
    );
    final data = response.data ?? const {};
    final rotated = current.copyWith(
      accessToken: '${data['accessToken']}',
      refreshToken: '${data['refreshToken']}',
    );
    final latest = await _sessions.read();
    if (latest?.sessionId != current.sessionId ||
        latest?.userId != current.userId) {
      return null;
    }
    await _sessions.save(rotated);
    return rotated;
  }
}
