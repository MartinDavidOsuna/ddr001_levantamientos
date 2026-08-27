import 'package:flutter/foundation.dart';

class AppConfig {
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
        !uri.path.endsWith('/api/v1')) {
      throw StateError('API_BASE_URL debe ser una URL /api/v1 válida.');
    }
    if (env == 'production' && uri.scheme != 'https') {
      throw StateError('Producción requiere HTTPS.');
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
