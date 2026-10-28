import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/qa/hydrostatic_test_guard.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';

void main() {
  for (final item in [
    (true, 'test', true, 'com.aquafim.ddr001levantamientos.hydrotest', true),
    (false, 'test', true, 'com.aquafim.ddr001levantamientos.hydrotest', false),
    (
      true,
      'production',
      true,
      'com.aquafim.ddr001levantamientos.hydrotest',
      false,
    ),
    (true, 'test', false, 'com.aquafim.ddr001levantamientos.hydrotest', false),
    (true, 'test', true, 'com.aquafim.ddr001levantamientos', false),
    (true, 'test', true, 'com.aquafim.ddr001levantamientos.test', false),
  ]) {
    test('isolated certification guard $item', () {
      void run() => requireHydrostaticTestBuild(
        debug: item.$1,
        environment: item.$2,
        enabled: item.$3,
        packageName: item.$4,
      );
      if (item.$5) {
        expect(run, returnsNormally);
      } else {
        expect(run, throwsA(isA<HydrostaticException>()));
      }
    });
  }
}
