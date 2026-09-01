import 'package:ddr001_levantamientos/core/security/field_identity.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/data/remote/construction_api.dart';
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
  test('normalizes Field identity including crew without losing Unicode', () {
    const identity = FieldIdentity(
      name: '  María   José  Ñúñez  ',
      email: '  USER@Example.COM ',
      phone: '6621234567',
      crew: '  cuadrilla   norte  ',
    );
    expect(identity.normalizedName, 'María José Ñúñez');
    expect(identity.normalizedEmail, 'user@example.com');
    expect(identity.normalizedPhone, '6621234567');
    expect(identity.normalizedCrew, 'CUADRILLA NORTE');
    expect(identity.validate(), isNull);
  });

  test('rejects an empty or whitespace-only name', () {
    expect(
      const FieldIdentity(
        name: '   ',
        email: 'user@example.com',
        phone: '6621234567',
        crew: 'CUADRILLA A',
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
        crew: 'CUADRILLA A',
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
          crew: 'CUADRILLA A',
        ).validate(),
        'El teléfono debe contener exactamente 10 dígitos.',
      );
    }
  });

  test('requires a non-empty crew', () {
    expect(
      const FieldIdentity(
        name: 'Usuario Test',
        email: 'user@example.com',
        phone: '6621234567',
        crew: '   ',
      ).validate(),
      'Ingresa una cuadrilla válida.',
    );
  });

  test('persisted sessions preserve crew and legacy JSON remains readable', () {
    const field = FieldSession(
      sessionId: '00000000-0000-4000-8000-000000000001',
      userId: '00000000-0000-4000-8000-000000000002',
      accessToken: 'access',
      refreshToken: 'refresh',
      installationId: '00000000-0000-4000-8000-000000000003',
      name: 'Field User',
      email: 'field@example.com',
      phone: '6621234567',
      crew: 'CUADRILLA A',
    );
    expect(FieldSession.fromJson(field.toJson()).crew, 'CUADRILLA A');

    final legacyFieldJson = Map<String, dynamic>.from(field.toJson())
      ..remove('crew');
    final legacyField = FieldSession.fromJson(legacyFieldJson);
    expect(legacyField.kind, SessionKind.field);
    expect(legacyField.crew, isEmpty);
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

  test('Field login payload identifies app, installation and crew', () {
    final payload = fieldSessionStartPayload(
      name: ' Usuario  Test ',
      email: ' USER@EXAMPLE.COM ',
      phone: '6621234567',
      crew: ' cuadrilla   norte ',
      installationId: 'installation-a',
      platform: 'android',
      manufacturer: 'Motorola',
      model: 'moto g14',
      osVersion: '14',
      appVersion: '1.0.0+1',
    );
    expect(payload['client_app'], fieldClientApp);
    expect(fieldClientApp, 'ddr001_levantamientos');
    expect(payload['name'], 'Usuario Test');
    expect(payload['email'], 'user@example.com');
    expect(payload['crew'], 'CUADRILLA NORTE');
    expect(
      (payload['device'] as Map<String, dynamic>)['installationId'],
      'installation-a',
    );
  });
}
