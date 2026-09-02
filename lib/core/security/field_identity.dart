import 'package:dio/dio.dart';

class FieldIdentity {
  const FieldIdentity({
    required this.name,
    required this.email,
    required this.phone,
    required this.crew,
  });

  final String name;
  final String email;
  final String phone;
  final String crew;

  String get normalizedName => name.trim().replaceAll(RegExp(r'\s+'), ' ');
  String get normalizedEmail => email.trim().toLowerCase();
  String get normalizedPhone => phone.trim();
  String get normalizedCrew => crew.trim();

  String? validate() {
    if (normalizedName.length < 3) {
      return 'Ingresa un nombre válido.';
    }
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(normalizedEmail)) {
      return 'Ingresa un correo electrónico válido.';
    }
    if (!RegExp(r'^\d{10}$').hasMatch(normalizedPhone)) {
      return 'El teléfono debe contener exactamente 10 dígitos.';
    }
    if (!RegExp(r'^[0-9]$').hasMatch(normalizedCrew)) {
      return 'Ingresa una Empresa válida del 0 al 9.';
    }
    return null;
  }
}

String fieldLoginErrorMessage(DioException error) {
  final data = error.response?.data;
  if (data is Map &&
      const {
        'COMPANY_MISMATCH',
        'COMPANY_OWNERSHIP_CONFLICT',
        'INVALID_COMPANY',
        'COMPANY_NOT_CONFIGURED',
      }.contains(data['code'])) {
    return data['detail']?.toString() ?? 'No fue posible iniciar sesión.';
  }
  return switch (error.response?.statusCode) {
    401 => 'No fue posible validar tus datos.',
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
}
