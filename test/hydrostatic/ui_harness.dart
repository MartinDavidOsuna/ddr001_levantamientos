import 'package:flutter/foundation.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_cabinet_lookup.dart';
import 'package:ddr001_levantamientos/features/hydrostatic/hydrostatic_controller.dart';
import 'harness.dart';

class UiHarness extends Harness {
  final changes = ChangeNotifier();
  late HydrostaticController controller;
  late LocalHydrostaticCabinetLookup lookup;
  late List<CabinetRecord> records;
  Future<void> Function()? verify;
  CabinetRecord record({
    String status = 'registered',
    String model = 'A1',
    bool automated = false,
    bool archived = false,
    bool deleted = false,
    bool shared = true,
    String? actor,
    String? id,
  }) => CabinetRecord({
    'id': id ?? uuid(),
    'actor': actor ?? access.actor.userId,
    'archived': archived,
    if (deleted) 'deletion': {'state': 'requested'},
    'working': {
      'uid': 'AQ26000017',
      'model': model,
      'automated': automated,
      'status': status,
    },
    'server': shared ? {'version': 1} : {},
  });
  @override
  Future<void> open() async {
    await super.open();
    records = [record()];
    lookup = LocalHydrostaticCabinetLookup(
      records: () => records,
      authorized: (_) => access.authorized,
    );
    makeController();
  }

  void makeController() {
    controller = HydrostaticController(
      openRepository: () async => repo,
      access: () => access,
      verifySession: () async {
        access.requireUser(access.actor.userId);
        await verify?.call();
      },
      sessionChanges: changes,
      lookup: lookup,
    );
  }

  @override
  Future<void> close() async {
    controller.dispose();
    changes.dispose();
    await super.close();
  }
}
