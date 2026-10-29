import '../location/location_service.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';
import 'hydrostatic_contracts.dart';

class DeviceHydrostaticLocation implements HydrostaticLocationProvider {
  DeviceHydrostaticLocation(this.service, this.clock);
  final LocationService service;
  final HydrostaticClock clock;
  @override
  Future<HydrostaticLocation> capture() async {
    final point = await service.capture();
    final acquired = clock.now().utc;
    final location = HydrostaticLocation(
      latitude: point.latitude,
      longitude: point.longitude,
      accuracy: point.accuracy,
      fixAt: point.capturedAt.toUtc(),
      acquiredAt: acquired,
      source: 'device-location-service',
    );
    hydroRequire(
      location.validAt(acquired),
      'GPS_REQUIRED',
      'GPS inválido: requiere precisión de hasta 100 m y fix de los últimos 60 segundos.',
    );
    return location;
  }
}
