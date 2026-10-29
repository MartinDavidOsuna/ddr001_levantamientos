import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/location/location_service.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_location.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'harness.dart';

class SyntheticLocationService extends LocationService {
  SyntheticLocationService(this.point);
  final GeoPoint point;
  Object? failure;
  @override
  Future<GeoPoint> capture() async {
    if (failure != null) throw failure!;
    return point;
  }
}

void main() {
  for (final scenario in [
    'valid',
    'max-accuracy',
    'bad-accuracy',
    'old',
    'future',
    'invalid-lat',
    'zero-accuracy',
  ]) {
    test('LocationService adapter $scenario without native GPS', () async {
      final clock = FakeHydroClock();
      final service = SyntheticLocationService(
        GeoPoint(
          latitude: scenario == 'invalid-lat' ? 91 : 20,
          longitude: -100,
          accuracy: scenario == 'zero-accuracy'
              ? 0
              : scenario == 'bad-accuracy'
              ? 101
              : scenario == 'max-accuracy'
              ? 100
              : 5,
          capturedAt: clock.utc.add(
            Duration(
              seconds: scenario == 'old'
                  ? -61
                  : scenario == 'future'
                  ? 2
                  : 0,
            ),
          ),
        ),
      );
      final adapter = DeviceHydrostaticLocation(service, clock);
      if (['valid', 'max-accuracy'].contains(scenario)) {
        final value = await adapter.capture();
        expect(value.validAt(clock.utc), isTrue);
        expect(value.acquiredAt, clock.utc);
        expect(value.fixAt, service.point.capturedAt);
      } else {
        await expectLater(
          adapter.capture(),
          throwsA(isA<HydrostaticException>()),
        );
      }
      await service.dispose();
    });
  }
  for (final error in [StateError('denied'), TimeoutException('timeout')]) {
    test(
      'LocationService adapter preserves failure ${error.runtimeType}',
      () async {
        final clock = FakeHydroClock();
        final service = SyntheticLocationService(
          GeoPoint(
            latitude: 20,
            longitude: -100,
            accuracy: 5,
            capturedAt: clock.utc,
          ),
        )..failure = error;
        await expectLater(
          DeviceHydrostaticLocation(service, clock).capture(),
          throwsA(same(error)),
        );
        await service.dispose();
      },
    );
  }
}
