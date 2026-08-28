import 'package:dio/dio.dart';

import 'session_store.dart';

class UnifiedLoginCredentials {
  const UnifiedLoginCredentials({
    required this.name,
    required this.email,
    required this.phone,
    required this.crew,
    required this.password,
  });

  final String name;
  final String email;
  final String phone;
  final String crew;
  final String password;

  bool get usesPasswordCredential => password.isNotEmpty;
}

abstract interface class AuthGateway {
  Future<FieldSession> fieldLogin({
    required String name,
    required String email,
    required String phone,
    required String crew,
  });

  Future<FieldSession> adminLogin({
    required String email,
    required String password,
  });
}

class AuthValidationException implements Exception {
  const AuthValidationException(this.message);

  final String message;
}

/// Resolves the existing credential shapes without exposing either auth domain
/// to the UI. A password credential is never retried as Field authentication.
class AuthResolver {
  const AuthResolver();

  Future<FieldSession> authenticate(
    AuthGateway gateway,
    UnifiedLoginCredentials credentials,
  ) async {
    final email = credentials.email.trim().toLowerCase();
    if (!email.contains('@')) {
      throw const AuthValidationException('Captura un correo válido.');
    }
    if (credentials.usesPasswordCredential) {
      return await gateway.adminLogin(
        email: email,
        password: credentials.password,
      );
    }

    final name = credentials.name.trim().replaceAll(RegExp(r'\s+'), ' ');
    final phone = credentials.phone.trim();
    final crew = credentials.crew.trim().toUpperCase();
    if (name.length < 3 ||
        !RegExp(r'^\d{10}$').hasMatch(phone) ||
        crew.isEmpty) {
      throw const AuthValidationException(
        'Captura contraseña o completa nombre, teléfono y cuadrilla.',
      );
    }
    return await gateway.fieldLogin(
      name: name,
      email: email,
      phone: phone,
      crew: crew,
    );
  }
}

String loginErrorMessage(DioException error) =>
    switch (error.response?.statusCode) {
      401 => 'Credenciales incorrectas.',
      403 => 'No tienes acceso a DDR001 Levantamientos.',
      429 => 'Demasiados intentos. Espera un momento.',
      _
          when const {
            DioExceptionType.connectionError,
            DioExceptionType.connectionTimeout,
            DioExceptionType.receiveTimeout,
            DioExceptionType.sendTimeout,
          }.contains(error.type) =>
        'Sin conexión.',
      _ => 'No fue posible iniciar sesión.',
    };
