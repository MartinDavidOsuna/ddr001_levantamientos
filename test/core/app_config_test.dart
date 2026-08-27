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
  test(
    'production requires HTTPS',
    () => expect(
      () => AppConfig.fromEnvironment(
        environment: 'production',
        baseUrl: 'http://api.example.com/api/v1',
      ),
      throwsStateError,
    ),
  );
}
