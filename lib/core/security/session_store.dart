import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import '../identity/uuid_identity.dart';

enum SessionKind { field, admin }

String refreshEndpoint(SessionKind kind) => kind == SessionKind.admin
    ? '/admin/auth/refresh'
    : '/field-sessions/refresh';

String logoutEndpoint(FieldSession session) => session.kind == SessionKind.admin
    ? '/admin/auth/logout'
    : '/field-sessions/${session.sessionId}/end';

class FieldSession {
  const FieldSession({
    required this.sessionId,
    required this.userId,
    required this.accessToken,
    required this.refreshToken,
    required this.installationId,
    required this.name,
    required this.email,
    required this.phone,
    this.crew = '',
    this.kind = SessionKind.field,
    this.adminRole,
  });
  final String sessionId,
      userId,
      accessToken,
      refreshToken,
      installationId,
      name,
      email,
      phone,
      crew;
  final SessionKind kind;
  final String? adminRole;
  FieldSession copyWith({
    String? accessToken,
    String? refreshToken,
    String? crew,
  }) => FieldSession(
    sessionId: sessionId,
    userId: userId,
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    installationId: installationId,
    name: name,
    email: email,
    phone: phone,
    crew: crew ?? this.crew,
    kind: kind,
    adminRole: adminRole,
  );
  Map<String, dynamic> toJson() => {
    'sessionId': sessionId,
    'userId': userId,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'installationId': installationId,
    'name': name,
    'email': email,
    'phone': phone,
    'crew': crew,
    'kind': kind.name,
    'adminRole': adminRole,
  };
  factory FieldSession.fromJson(Map<String, dynamic> j) => FieldSession(
    sessionId: canonicalUuid('${j['sessionId']}'),
    userId: canonicalUuid('${j['userId']}'),
    accessToken: '${j['accessToken']}',
    refreshToken: '${j['refreshToken']}',
    installationId: canonicalUuid('${j['installationId']}'),
    name: '${j['name']}',
    email: '${j['email']}',
    phone: '${j['phone']}',
    crew: '${j['crew'] ?? ''}',
    kind: SessionKind.values.byName('${j['kind'] ?? 'field'}'),
    adminRole: j['adminRole']?.toString(),
  );
}

abstract interface class SessionStore {
  Future<FieldSession?> read();
  Future<void> save(FieldSession value);
  Future<void> clear();
  Future<String> installationId();
}

class SecureSessionStore implements SessionStore {
  SecureSessionStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const _key = 'construction_field_session_v1',
      _installation = 'installation_id';
  @override
  Future<FieldSession?> read() async {
    final raw = await _storage.read(key: _key);
    return raw == null
        ? null
        : FieldSession.fromJson(
            Map<String, dynamic>.from(jsonDecode(raw) as Map),
          );
  }

  @override
  Future<void> save(FieldSession value) =>
      _storage.write(key: _key, value: jsonEncode(value.toJson()));
  @override
  Future<void> clear() => _storage.delete(key: _key);
  @override
  Future<String> installationId() async {
    final found = await _storage.read(key: _installation);
    if (found?.isNotEmpty == true) return canonicalUuid(found!);
    final id = canonicalUuid(const Uuid().v4());
    await _storage.write(key: _installation, value: id);
    return id;
  }
}
