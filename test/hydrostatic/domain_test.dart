import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'harness.dart';

void main() {
  test('catalog codes and exact names are versioned and immutable', () {
    expect(HydrostaticJoint.version, 'hydrostatic-joints-v1');
    expect(HydrostaticJoint.catalog.map((j) => j.name), [
      'Conexión en bee principal',
      'Juntas vitaulic',
      'Conexiones v. angular',
      'Conexión bee usuario',
      'Manómetros',
      'Filtro',
      'Abrazadera venturi',
      'Venturi',
      'Accesorios',
      'Válvulas parcelarias',
      'Otro',
    ]);
    expect(
      HydrostaticJoint.catalog.map((j) => j.code),
      List.generate(11, (i) => 'J${(i + 1).toString().padLeft(2, '0')}'),
    );
  });
  for (final entry in {
    '1': 1000,
    '2,125': 2125,
    '3.001': 3001,
    '4.999': 4999,
    '5.000': 5000,
  }.entries) {
    test(
      'pressure ${entry.key}',
      () => expect(parseHydrostaticBar(entry.key), entry.value),
    );
  }
  for (final input in [
    '0',
    '0.999',
    '5.001',
    '6',
    '-1',
    'NaN',
    'Infinity',
    '1e3',
    '1.2345',
    '1,2.3',
    '',
  ]) {
    test(
      'reject pressure $input',
      () => expect(
        () => parseHydrostaticBar(input),
        throwsA(isA<HydrostaticException>()),
      ),
    );
  }
  for (final from in HydrostaticTestState.values) {
    for (final to in HydrostaticTestState.values) {
      test('transition ${from.name} to ${to.name}', () {
        final allowed =
            HydrostaticStateMachine.transitions[from]?.contains(to) == true;
        if (allowed) {
          HydrostaticStateMachine.requireTransition(from, to);
        } else {
          expect(
            () => HydrostaticStateMachine.requireTransition(from, to),
            throwsA(isA<HydrostaticException>()),
          );
        }
      });
    }
  }
  test('Other may be drafted but cannot be completed without description', () {
    expect(
      HydrostaticLeak(
        id: uuid(),
        jointCode: 'J11',
        pressureMilliBar: 1200,
      ).complete,
      false,
    );
    expect(
      HydrostaticLeak(
        id: uuid(),
        jointCode: 'J11',
        pressureMilliBar: 1200,
        description: 'Unión de ensayo',
      ).complete,
      true,
    );
  });
  for (final accuracy in [0.0, -1.0, 101.0, double.nan, double.infinity]) {
    test('invalid GPS accuracy $accuracy', () {
      final now = DateTime.utc(2026);
      expect(
        HydrostaticLocation(
          latitude: 1,
          longitude: 2,
          accuracy: accuracy,
          fixAt: now,
          acquiredAt: now,
          source: 'synthetic',
        ).validAt(now),
        false,
      );
    });
  }
  test('GPS coordinate and temporal boundaries', () {
    final now = DateTime.utc(2026);
    HydrostaticLocation gps(double lat, double lng, DateTime fix) =>
        HydrostaticLocation(
          latitude: lat,
          longitude: lng,
          accuracy: 10,
          fixAt: fix,
          acquiredAt: fix,
          source: 'synthetic',
        );
    expect(gps(91, 0, now).validAt(now), false);
    expect(gps(0, -181, now).validAt(now), false);
    expect(
      gps(1, 2, now.subtract(const Duration(seconds: 61))).validAt(now),
      false,
    );
    expect(gps(1, 2, now.add(const Duration(seconds: 1))).validAt(now), false);
    expect(
      gps(
        1,
        2,
        now.add(const Duration(seconds: 120)),
      ).validAt(now, photo: true),
      true,
    );
  });
  test(
    'clock monotonic, reboot, negative duration, forward/backward wall changes',
    () {
      final c = FakeHydroClock();
      final start = c.now();
      c.advance(3601000);
      expect(HydrostaticElapsed.between(start, c.now()).display, '01:00:01');
      c.utc = c.utc.add(const Duration(hours: 1));
      expect(
        HydrostaticElapsed.between(start, c.now()).state,
        HydrostaticTimeState.needsReview,
      );
      c.utc = start.utc.subtract(const Duration(hours: 1));
      expect(
        HydrostaticElapsed.between(start, c.now()).anomalies,
        contains('NEGATIVE_DURATION'),
      );
      c.utc = start.utc.add(const Duration(days: 2));
      c.reboot();
      expect(
        HydrostaticElapsed.between(start, c.now()).state,
        HydrostaticTimeState.reconstructed,
      );
      expect(HydrostaticElapsed.between(start, c.now()).display, '48:00:00');
    },
  );
  test('timezone representations produce same UTC duration', () {
    final a = HydrostaticClockReading(
      DateTime.parse('2026-10-27T10:00:00-07:00'),
      'a',
      null,
    );
    final b = HydrostaticClockReading(
      DateTime.parse('2026-10-27T18:00:00Z'),
      'b',
      null,
    );
    expect(HydrostaticElapsed.between(a, b).milliseconds, 3600000);
  });
}
