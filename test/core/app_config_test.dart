import 'package:ddr001_levantamientos/core/config/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('test environment accepts configurable LAN API', () {
    final c = AppConfig.fromEnvironment(
      environment: 'test',
      baseUrl: 'http://192.168.1.5:3003/api/v1',
    );
    expect(c.apiBaseUrl.host, '192.168.1.5');
  });
  test(
    'missing API URL is rejected',
    () => expect(
      () => AppConfig.fromEnvironment(environment: 'test', baseUrl: ''),
      throwsStateError,
    ),
  );
  test(
    'non-production cannot target known production API host',
    () => expect(
      () => AppConfig.fromEnvironment(
        environment: 'test',
        baseUrl: 'https://cifra.aquafim.com/api/v1',
      ),
      throwsStateError,
    ),
  );
  test('production accepts only the official HTTP endpoint', () {
    final config = AppConfig.fromEnvironment(
      environment: 'production',
      baseUrl: AppConfig.productionHttpApiBaseUrl,
    );
    expect(config.apiBaseUrl.toString(), AppConfig.productionHttpApiBaseUrl);
  });

  for (final endpoint in const [
    'http://otrohost.com/api/v1',
    'http://cifra.aquafim.com:3000/api/v1',
    'http://cifra.aquafim.com/api/v1',
    'http://192.168.1.10:3002/api/v1',
    'http://localhost:3002/api/v1',
  ]) {
    test('production rejects non-official HTTP endpoint $endpoint', () {
      expect(
        () => AppConfig.fromEnvironment(
          environment: 'production',
          baseUrl: endpoint,
        ),
        throwsStateError,
      );
    });
  }

  test('production keeps HTTPS available for a future endpoint', () {
    final config = AppConfig.fromEnvironment(
      environment: 'production',
      baseUrl: 'https://api.example.com/api/v1',
    );
    expect(config.apiBaseUrl.scheme, 'https');
  });
}
