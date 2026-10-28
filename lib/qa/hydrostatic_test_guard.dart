import '../domain/hydrostatic/hydrostatic_models.dart';

void requireHydrostaticTestBuild({
  required bool debug,
  required String environment,
  required bool enabled,
  required String packageName,
}) {
  hydroRequire(
    debug &&
        environment == 'test' &&
        enabled &&
        packageName == 'com.aquafim.ddr001levantamientos.hydrotest',
    'UNSAFE_TEST_BUILD',
    'La certificación requiere el paquete aislado debug TEST.',
  );
}
