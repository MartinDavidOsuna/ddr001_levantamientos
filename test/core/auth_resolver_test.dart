import 'package:ddr001_levantamientos/core/security/auth_resolver.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const fieldSession = FieldSession(
  sessionId: '00000000-0000-4000-8000-000000000001',
  userId: '00000000-0000-4000-8000-000000000002',
  accessToken: 'field-access',
  refreshToken: 'field-refresh',
  installationId: '00000000-0000-4000-8000-000000000003',
  name: 'Field User',
  email: 'same@example.com',
  phone: '1234567890',
  crew: 'C1',
);

const adminSession = FieldSession(
  sessionId: '00000000-0000-4000-8000-000000000011',
  userId: '00000000-0000-4000-8000-000000000012',
  accessToken: 'admin-access',
  refreshToken: 'admin-refresh',
  installationId: '00000000-0000-4000-8000-000000000013',
  name: 'Admin User',
  email: 'same@example.com',
  phone: '',
  crew: '',
  kind: SessionKind.admin,
  adminRole: 'admin',
);

class RecordingGateway implements AuthGateway {
  int fieldAttempts = 0;
  int adminAttempts = 0;
  Object? fieldFailure;
  Object? adminFailure;

  @override
  Future<FieldSession> fieldLogin({
    required String name,
    required String email,
    required String phone,
    required String crew,
  }) async {
    fieldAttempts++;
    if (fieldFailure case final failure?) throw failure;
    return fieldSession;
  }

  @override
  Future<FieldSession> adminLogin({
    required String email,
    required String password,
  }) async {
    adminAttempts++;
    if (adminFailure case final failure?) throw failure;
    return adminSession;
  }
}

UnifiedLoginCredentials credentials({String password = ''}) =>
    UnifiedLoginCredentials(
      name: 'Field User',
      email: 'same@example.com',
      phone: '1234567890',
      crew: 'C1',
      password: password,
    );

DioException responseFailure(int status) => DioException(
  requestOptions: RequestOptions(path: '/auth'),
  response: Response<void>(
    requestOptions: RequestOptions(path: '/auth'),
    statusCode: status,
  ),
  type: DioExceptionType.badResponse,
);

void main() {
  const resolver = AuthResolver();

  test(
    'complete credential without password uses Field exactly once',
    () async {
      final gateway = RecordingGateway();
      expect(
        (await resolver.authenticate(gateway, credentials())).kind,
        SessionKind.field,
      );
      expect(gateway.fieldAttempts, 1);
      expect(gateway.adminAttempts, 0);
    },
  );

  test('password credential uses Admin exactly once', () async {
    final gateway = RecordingGateway();
    expect(
      (await resolver.authenticate(
        gateway,
        credentials(password: 'secret'),
      )).kind,
      SessionKind.admin,
    );
    expect(gateway.adminAttempts, 1);
    expect(gateway.fieldAttempts, 0);
  });

  test(
    'same email in both domains resolves deterministically by credential',
    () async {
      final passwordGateway = RecordingGateway();
      final fieldGateway = RecordingGateway();
      expect(
        (await resolver.authenticate(
          passwordGateway,
          credentials(password: 'valid-admin-password'),
        )).kind,
        SessionKind.admin,
      );
      expect(
        (await resolver.authenticate(fieldGateway, credentials())).kind,
        SessionKind.field,
      );
    },
  );

  for (final testCase in <(String, DioException)>[
    ('bad credentials', responseFailure(401)),
    ('rate limit', responseFailure(429)),
    (
      'network error',
      DioException(
        requestOptions: RequestOptions(path: '/auth'),
        type: DioExceptionType.connectionError,
        error: const SocketExceptionForTest(),
      ),
    ),
  ]) {
    test('Admin ${testCase.$1} never falls back to Field', () async {
      final failure = testCase.$2;
      final gateway = RecordingGateway()..adminFailure = failure;
      await expectLater(
        resolver.authenticate(gateway, credentials(password: 'bad')),
        throwsA(same(failure)),
      );
      expect(gateway.adminAttempts, 1);
      expect(gateway.fieldAttempts, 0);
    });
  }

  test('Field technical error never triggers Admin', () async {
    final failure = responseFailure(500);
    final gateway = RecordingGateway()..fieldFailure = failure;
    await expectLater(
      resolver.authenticate(gateway, credentials()),
      throwsA(same(failure)),
    );
    expect(gateway.fieldAttempts, 1);
    expect(gateway.adminAttempts, 0);
  });

  test('invalid incomplete credential performs no request', () async {
    final gateway = RecordingGateway();
    await expectLater(
      resolver.authenticate(
        gateway,
        const UnifiedLoginCredentials(
          name: '',
          email: 'same@example.com',
          phone: '',
          crew: '',
          password: '',
        ),
      ),
      throwsA(isA<AuthValidationException>()),
    );
    expect(gateway.fieldAttempts, 0);
    expect(gateway.adminAttempts, 0);
  });

  test('persisted domain restores correct refresh and logout routing', () {
    final restoredAdmin = FieldSession.fromJson(adminSession.toJson());
    final restoredField = FieldSession.fromJson(fieldSession.toJson());
    expect(restoredAdmin.kind, SessionKind.admin);
    expect(refreshEndpoint(restoredAdmin.kind), '/admin/auth/refresh');
    expect(logoutEndpoint(restoredAdmin), '/admin/auth/logout');
    expect(restoredField.kind, SessionKind.field);
    expect(refreshEndpoint(restoredField.kind), '/field-sessions/refresh');
    expect(
      logoutEndpoint(restoredField),
      '/field-sessions/${fieldSession.sessionId}/end',
    );
  });

  test('legacy persisted session without domain restores as Field', () {
    final legacy = fieldSession.toJson()..remove('kind');
    expect(FieldSession.fromJson(legacy).kind, SessionKind.field);
  });

  test('login errors are generic and never expose an auth domain', () {
    expect(
      loginErrorMessage(responseFailure(401)),
      'Credenciales incorrectas.',
    );
    expect(
      loginErrorMessage(responseFailure(403)),
      'No tienes acceso a DDR001 Levantamientos.',
    );
    expect(
      loginErrorMessage(responseFailure(429)),
      'Demasiados intentos. Espera un momento.',
    );
    expect(
      loginErrorMessage(
        DioException(
          requestOptions: RequestOptions(path: '/auth'),
          type: DioExceptionType.connectionTimeout,
        ),
      ),
      'Sin conexión.',
    );
    final generic = loginErrorMessage(responseFailure(500));
    expect(generic, 'No fue posible iniciar sesión.');
    expect(generic, isNot(contains('Field')));
    expect(generic, isNot(contains('Admin')));
  });
}

class SocketExceptionForTest implements Exception {
  const SocketExceptionForTest();
}
