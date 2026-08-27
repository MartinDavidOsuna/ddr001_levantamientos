import 'package:geolocator/geolocator.dart';
import '../../domain/construction/construction_models.dart';

class LocationService {
  GeoPoint? _lastGood;
  Future<GeoPoint> capture() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Activa la ubicación para georreferenciar la foto.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('Se requiere permiso de ubicación.');
    }
    try {
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      final point = GeoPoint(
        latitude: p.latitude,
        longitude: p.longitude,
        accuracy: p.accuracy,
        altitude: p.altitude,
        capturedAt: p.timestamp,
      );
      if (point.isValid) _lastGood = point;
      if (!point.isValid) {
        throw StateError('La precisión GPS debe ser de 100 m o mejor.');
      }
      return point;
    } on Object {
      final cached = _lastGood;
      if (cached != null &&
          DateTime.now().difference(cached.capturedAt) <
              const Duration(minutes: 2) &&
          cached.isValid) {
        return cached;
      }
      rethrow;
    }
  }
}
