import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../core/hydrostatic/hydrostatic_contracts.dart';
import '../../data/hydrostatic/hydrostatic_repository.dart';
import '../../domain/cabinets/cabinet_models.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';

/// UI coordinator: no remote, GPS, camera, timer or execution commands.
class HydrostaticController extends ChangeNotifier {
  HydrostaticController({
    required this.openRepository,
    required this.access,
    required this.verifySession,
    required this.sessionChanges,
    required this.lookup,
  }) {
    sessionChanges.addListener(_sessionChanged);
  }
  final Future<HydrostaticRepository> Function() openRepository;
  final HydrostaticAccess Function() access;
  final Future<void> Function() verifySession;
  final Listenable sessionChanges;
  final HydrostaticCabinetLookup lookup;
  HydrostaticRepository? _repo;
  Future<void>? _initializing;
  Future<String>? _preparing;
  bool _disposed = false;
  String? error;
  bool busy = false;
  String? get identity {
    try {
      final a = access();
      a.requireUser(a.actor.userId);
      return '${a.actor.userId}:${a.actor.sessionId}';
    } catch (_) {
      return null;
    }
  }

  bool get allowed => identity != null;
  bool get ready => _repo != null && !_repo!.store.recoveryRequired;
  void requireIdentity(String? expected) => hydroRequire(
    expected != null && expected == identity,
    'SESSION_CHANGED',
    'La sesión cambió. Vuelve a Inicio.',
  );
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _sessionChanged() {
    error = null;
    _notify();
  }

  Future<void> initialize() =>
      _initializing ??= _initialize().whenComplete(() => _initializing = null);
  Future<void> _initialize() async {
    final key = identity;
    requireIdentity(key);
    await verifySession();
    requireIdentity(key);
    _repo ??= await openRepository();
    requireIdentity(key);
    if (_repo!.store.recoveryRequired) await _repo!.recover();
    requireIdentity(key);
    error = null;
    _notify();
  }

  List<HydrostaticTest> get documents {
    if (!allowed || !ready) return [];
    return _repo!.forUser()..sort(
      (a, b) => b.toJson()['createdAt'].compareTo(a.toJson()['createdAt']),
    );
  }

  List<HydrostaticTest> get preparations =>
      documents.where((t) => t.startedAt == null).toList();
  List<HydrostaticTest> get started =>
      documents.where((t) => t.startedAt != null).toList();
  List<HydrostaticTest> history(String uid) =>
      started.where((t) => t.cabinet.uid == uid).toList()
        ..sort((a, b) => b.attemptNumber!.compareTo(a.attemptNumber!));
  HydrostaticTest document(String id) =>
      _repo?.get(id) ??
      (throw const HydrostaticException(
        'NOT_FOUND',
        'Registro no disponible para esta sesión.',
      ));
  int provisional(String id) {
    final t = document(id);
    return _repo!.sequences.last(t.cabinet.uid) + 1;
  }

  Future<String> identify(String input) {
    // Single flight also prevents repeated scanner callbacks and double taps.
    return _preparing ??= _identify(
      input,
    ).whenComplete(() => _preparing = null);
  }

  Future<String> _identify(String input) async {
    final key = identity;
    requireIdentity(key);
    final uid = cabinetUid(input.trim());
    busy = true;
    error = null;
    _notify();
    try {
      await initialize();
      requireIdentity(key);
      final cabinet = await lookup.findLocal(uid, access());
      requireIdentity(key);
      hydroRequire(
        cabinet != null,
        'CABINET_NOT_LOCAL',
        'Este gabinete no está disponible en este dispositivo. Consulta el módulo de Gabinetes y vuelve a intentarlo.',
      );
      final existing = preparations.where((t) => t.cabinet.uid == uid).toList();
      if (existing.isNotEmpty) return existing.first.id;
      await verifySession();
      requireIdentity(key);
      final latest = await lookup.findLocal(uid, access());
      requireIdentity(key);
      hydroRequire(
        latest != null &&
            canonicalHydroJson(latest.toJson()) ==
                canonicalHydroJson(cabinet!.toJson()),
        'CABINET_CHANGED',
        'El gabinete cambió. Vuelve a identificarlo.',
      );
      final t = await _repo!.prepare(
        operationId: const Uuid().v4(),
        testId: const Uuid().v4(),
        cabinet: cabinet!,
      );
      requireIdentity(key);
      return t.id;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<String?> preparationWarning(String id) async {
    final key = identity;
    final t = document(id);
    final latest = await lookup.findLocal(t.cabinet.uid, access());
    requireIdentity(key);
    if (latest == null ||
        canonicalHydroJson(latest.toJson()) !=
            canonicalHydroJson(t.cabinet.toJson())) {
      return 'El gabinete cambió o ya no está disponible. Se conserva el snapshot original; revisa Gabinetes antes de continuar.';
    }
    return null;
  }

  bool canDelete(String id) {
    try {
      if (!ready || busy) return false;
      _repo!.development.requireDeletion();
      final t = document(id);
      return ![
            HydrostaticTestState.active,
            HydrostaticTestState.starting,
          ].contains(t.state) &&
          !_repo!.isCapturing(id);
    } catch (_) {
      return false;
    }
  }

  Future<void> delete(String id, String confirmedId) async {
    final key = identity;
    requireIdentity(key);
    await verifySession();
    requireIdentity(key);
    hydroRequire(
      canDelete(id),
      'DELETE_DISABLED',
      'Eliminación no habilitada.',
    );
    await _repo!.deleteLocal(
      id,
      const Uuid().v4(),
      confirmedTestId: confirmedId,
    );
    requireIdentity(key);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    sessionChanges.removeListener(_sessionChanged);
    super.dispose();
  }
}
