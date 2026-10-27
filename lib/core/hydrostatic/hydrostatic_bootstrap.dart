import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../../data/hydrostatic/hydrostatic_access_adapter.dart';
import '../../data/hydrostatic/hydrostatic_repository.dart';
import '../../data/hydrostatic/hydrostatic_store.dart';
import '../../features/hydrostatic/hydrostatic_controller.dart';
import 'hydrostatic_contracts.dart';

/// Lazy isolated initialization: existing modules can boot even if this store
/// needs recovery. No cabinet stores are opened or migrated here.
HydrostaticController createHydrostaticController({
  required HydrostaticAccessAdapter authorization,
  required HydrostaticCabinetLookup lookup,
}) => HydrostaticController(
  access: authorization.current,
  verifySession: authorization.verify,
  sessionChanges: authorization,
  lookup: lookup,
  openRepository: () async {
    final support = await getApplicationSupportDirectory();
    final store = await HydrostaticStore.open(
      Directory('${support.path}/hydrostatic/db'),
    );
    return HydrostaticRepository(
      store: store,
      clock: SystemHydrostaticClock(),
      access: authorization.current,
      files: LocalHydrostaticEvidenceFiles(support),
    );
    // Development deletion intentionally defaults OFF, including release builds.
  },
);
