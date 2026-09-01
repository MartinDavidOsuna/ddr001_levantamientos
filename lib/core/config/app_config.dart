import 'package:flutter/foundation.dart';

class AppConfig {
  static const productionHttpApiBaseUrl =
      'http://cifra.aquafim.com:3002/api/v1';

  const AppConfig({required this.environment, required this.apiBaseUrl});
  final String environment;
  final Uri apiBaseUrl;
  bool get isProduction => environment == 'production';
  factory AppConfig.fromEnvironment({String? environment, String? baseUrl}) {
    final env =
        (environment ??
                const String.fromEnvironment(
                  'APP_ENV',
                  defaultValue: 'development',
                ))
            .trim()
            .toLowerCase();
    if (!const {'development', 'test', 'production'}.contains(env)) {
      throw StateError('APP_ENV inválido.');
    }
    final raw = (baseUrl ?? const String.fromEnvironment('API_BASE_URL'))
        .trim();
    if (raw.isEmpty) throw StateError('API_BASE_URL es obligatorio.');
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !uri.hasScheme ||
        !uri.hasAuthority ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.path != '/api/v1' ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      throw StateError('API_BASE_URL debe ser una URL /api/v1 válida.');
    }
    if (env == 'production' &&
        uri.scheme == 'http' &&
        raw != productionHttpApiBaseUrl) {
      throw StateError(
        'Producción sólo permite HTTP para el endpoint oficial DDR001.',
      );
    }
    if (env != 'production' && uri.host == 'cifra.aquafim.com') {
      throw StateError(
        'Un build no productivo no puede usar la API productiva.',
      );
    }
    if (kDebugMode) {
      debugPrint('[STARTUP] environment=$env api=${uri.origin}${uri.path}');
    }
    return AppConfig(environment: env, apiBaseUrl: uri);
  }
}
