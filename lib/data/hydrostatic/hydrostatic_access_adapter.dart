import 'package:flutter/foundation.dart';
import '../../core/hydrostatic/hydrostatic_contracts.dart';
import '../../core/security/session_store.dart';
import '../../domain/construction/construction_models.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';

/// Reads the existing session; never refreshes, logs in or writes credentials.
class HydrostaticAccessAdapter extends ChangeNotifier {
  HydrostaticAccessAdapter({
    required this.session,
    required this.profile,
    required this.cabinetAuthorized,
    required this.sessions,
    required this.changes,
  }) {
    for (final change in changes) {
      change.addListener(_changed);
    }
  }
  final FieldSession? Function() session;
  final ConstructionProfile? Function() profile;
  final bool Function() cabinetAuthorized;
  final SessionStore sessions;
  final List<Listenable> changes;
  String? _rejectedIdentity;
  String? get identity {
    final s = session();
    return s == null ? null : '${s.userId}:${s.sessionId}:${s.installationId}';
  }

  HydrostaticAccess current() {
    final s = session(), p = profile();
    hydroRequire(
      s != null &&
          p != null &&
          s.kind == SessionKind.field &&
          p.role == ConstructionRole.resident &&
          p.userId.toLowerCase() == s.userId.toLowerCase() &&
          cabinetAuthorized() &&
          identity != _rejectedIdentity,
      'NOT_AUTHORIZED',
      'Acceso exclusivo para residentes con autorización vigente de gabinetes.',
    );
    return HydrostaticAccess(
      actor: HydrostaticActorSnapshot(
        userId: s!.userId.toLowerCase(),
        name: p!.displayName,
        sessionId: s.sessionId.toLowerCase(),
        deviceInstallationId: s.installationId.toLowerCase(),
      ),
      authorized: true,
      fieldSession: true,
    );
  }

  bool get allowed {
    try {
      current();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> verify() async {
    final expected = identity;
    current();
    final saved = await sessions.read();
    if (expected != identity ||
        saved == null ||
        '${saved.userId}:${saved.sessionId}:${saved.installationId}' !=
            expected ||
        saved.kind != SessionKind.field) {
      _rejectedIdentity = identity;
      notifyListeners();
      throw const HydrostaticException(
        'SESSION_CHANGED',
        'La sesión cambió. Vuelve a Inicio.',
      );
    }
    current();
  }

  void _changed() => notifyListeners();
  @override
  void dispose() {
    for (final change in changes) {
      change.removeListener(_changed);
    }
    super.dispose();
  }
}
