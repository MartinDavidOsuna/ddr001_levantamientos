import '../../core/hydrostatic/hydrostatic_contracts.dart';
import '../../domain/cabinets/cabinet_models.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';
import '../cabinets/cabinet_store.dart';

class LocalHydrostaticCabinetLookup implements HydrostaticCabinetLookup {
  LocalHydrostaticCabinetLookup({
    required this.records,
    required this.authorized,
  });
  factory LocalHydrostaticCabinetLookup.fromStore(CabinetStore store) =>
      LocalHydrostaticCabinetLookup(
        records: store.all,
        authorized: store.authorized,
      );
  final List<CabinetRecord> Function() records;
  final bool Function(String) authorized;
  @override
  Future<HydrostaticCabinetSnapshot?> findLocal(
    String canonicalUid,
    HydrostaticAccess access,
  ) async {
    access.requireUser(access.actor.userId);
    hydroRequire(
      authorized(access.actor.userId),
      'NOT_AUTHORIZED',
      'Gabinetes no autorizado.',
    );
    final uid = cabinetUid(canonicalUid);
    final matches = records()
        .where(
          (r) =>
              r.working['uid'] == uid &&
              (r.server.isNotEmpty || r.json['actor'] == access.actor.userId),
        )
        .toList();
    hydroRequire(
      matches.length <= 1,
      'CABINET_CONFLICT',
      'Hay dos expedientes locales con este número. Resuelve el conflicto en Gabinetes.',
    );
    if (matches.isEmpty) return null;
    final r = matches.single, w = r.working;
    hydroRequire(
      r.json['archived'] != true &&
          r.json['deletion'] == null &&
          ['registered', 'incomplete', 'validated'].contains(w['status']),
      'CABINET_NOT_ELIGIBLE',
      'Sólo se permiten gabinetes registrados, incompletos o validados. Los instalados, borradores, archivados y eliminados no son admisibles.',
    );
    return HydrostaticCabinetSnapshot(
      uid: uid,
      cabinetId: r.id,
      model: w['model'],
      automated: w['automated'] == true,
      sourceVersion: (r.server['version'] as num?)?.toInt(),
    );
  }
}
