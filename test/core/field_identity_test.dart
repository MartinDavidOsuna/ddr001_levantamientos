import 'package:ddr001_levantamientos/core/security/field_identity.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

DioException responseFailure(int status) => DioException(
  requestOptions: RequestOptions(path: '/field-sessions/start'),
  response: Response<void>(
    requestOptions: RequestOptions(path: '/field-sessions/start'),
    statusCode: status,
  ),
  type: DioExceptionType.badResponse,
);

void main() {
  test('normalizes Field name, email and phone without losing Unicode', () {
    const identity = FieldIdentity(
      name: '  María   José  Ñúñez  ',
      email: '  USER@Example.COM ',
      phone: '6621234567',
    );
    expect(identity.normalizedName, 'María José Ñúñez');
    expect(identity.normalizedEmail, 'user@example.com');
    expect(identity.normalizedPhone, '6621234567');
    expect(identity.validate(), isNull);
  });

  test('rejects an empty or whitespace-only name', () {
    expect(
      const FieldIdentity(
        name: '   ',
        email: 'user@example.com',
        phone: '6621234567',
      ).validate(),
      'Ingresa un nombre válido.',
    );
  });

  test('rejects an invalid email', () {
    expect(
      const FieldIdentity(
        name: 'Usuario Test',
        email: 'correo-invalido',
        phone: '6621234567',
      ).validate(),
      'Ingresa un correo electrónico válido.',
    );
  });

  test('requires exactly ten phone digits', () {
    for (final phone in ['662123456', '66212345678', '66212A4567']) {
      expect(
        FieldIdentity(
          name: 'Usuario Test',
          email: 'user@example.com',
          phone: phone,
        ).validate(),
        'El teléfono debe contener exactamente 10 dígitos.',
      );
    }
  });

  test('legacy persisted Admin and Field sessions keep technical routing', () {
    const field = FieldSession(
      sessionId: '00000000-0000-4000-8000-000000000001',
      userId: '00000000-0000-4000-8000-000000000002',
      accessToken: 'access',
      refreshToken: 'refresh',
      installationId: '00000000-0000-4000-8000-000000000003',
      name: 'Field User',
      email: 'field@example.com',
      phone: '6621234567',
    );
    final legacyField = field.toJson()..['crew'] = 'LEGACY';
    expect(FieldSession.fromJson(legacyField).kind, SessionKind.field);
    expect(refreshEndpoint(SessionKind.field), '/field-sessions/refresh');

    final admin = FieldSession.fromJson({
      ...field.toJson(),
      'kind': 'admin',
      'adminRole': 'admin',
    });
    expect(refreshEndpoint(admin.kind), '/admin/auth/refresh');
    expect(logoutEndpoint(admin), '/admin/auth/logout');
  });

  test('Field errors are generic and localized', () {
    expect(
      fieldLoginErrorMessage(responseFailure(429)),
      'Demasiados intentos. Espera un momento.',
    );
    expect(
      fieldLoginErrorMessage(responseFailure(500)),
      'No fue posible iniciar sesión.',
    );
  });
}
