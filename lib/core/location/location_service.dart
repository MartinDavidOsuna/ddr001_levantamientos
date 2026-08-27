import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import '../../domain/construction/construction_models.dart';

abstract final class LocationEvidencePolicy {
  static const preCaptureMaxAge = Duration(seconds: 60);
  static const postCaptureWindow = Duration(seconds: 120);
  static const preferredTemporalDelta = Duration(seconds: 30);
  static const maxHorizontalAccuracy = 100.0;
  static const excellentAccuracy = 10.0;
  static const goodAccuracy = 25.0;
  static const acceptableAccuracy = 50.0;
  static const minimumSiteRadius = 25.0;
  static const siteMargin = 15.0;
  static const bufferRetention = Duration(seconds: 180);
}

class LocationFix {
  const LocationFix({
    required this.latitude,
    required this.longitude,
    required this.horizontalAccuracy,
    required this.timestamp,
    required this.acquiredAt,
    this.altitude,
    this.altitudeAccuracy,
    this.heading,
    this.speed,
    this.source,
    this.isMocked = false,
  });
  final double latitude, longitude, horizontalAccuracy;
  final double? altitude, altitudeAccuracy, heading, speed;
  final DateTime timestamp, acquiredAt;
  final String? source;
  final bool isMocked;

  Duration ageAt(DateTime capturedAt) => timestamp.difference(capturedAt);
  bool get hasValidCoordinates =>
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;
  bool withinCaptureWindow(DateTime capturedAt) {
    final delta = ageAt(capturedAt);
    return delta >= -LocationEvidencePolicy.preCaptureMaxAge &&
        delta <= LocationEvidencePolicy.postCaptureWindow;
  }

  bool validFor(DateTime capturedAt) =>
      hasValidCoordinates &&
      horizontalAccuracy > 0 &&
      horizontalAccuracy <= LocationEvidencePolicy.maxHorizontalAccuracy &&
      withinCaptureWindow(capturedAt);
  GeoPoint toGeoPoint() => GeoPoint(
    latitude: latitude,
    longitude: longitude,
    accuracy: horizontalAccuracy,
    altitude: altitude,
    capturedAt: timestamp,
  );
}

LocationConfidence locationConfidence(double accuracy) {
  if (accuracy <= 0 ||
      accuracy > LocationEvidencePolicy.maxHorizontalAccuracy) {
    return LocationConfidence.invalid;
  }
  if (accuracy <= LocationEvidencePolicy.excellentAccuracy) {
    return LocationConfidence.excellent;
  }
  if (accuracy <= LocationEvidencePolicy.goodAccuracy) {
    return LocationConfidence.good;
  }
  if (accuracy <= LocationEvidencePolicy.acceptableAccuracy) {
    return LocationConfidence.acceptable;
  }
  return LocationConfidence.weak;
}

double distanceBetweenFixAndPoint(LocationFix fix, GeoPoint point) =>
    Geolocator.distanceBetween(
      fix.latitude,
      fix.longitude,
      point.latitude,
      point.longitude,
    );

LocationConsistency locationConsistency(LocationFix fix, GeoPoint? canonical) {
  if (canonical == null) return LocationConsistency.unknown;
  final distance = distanceBetweenFixAndPoint(fix, canonical);
  final radius = math.max(
    LocationEvidencePolicy.minimumSiteRadius,
    fix.horizontalAccuracy +
        canonical.accuracy +
        LocationEvidencePolicy.siteMargin,
  );
  if (distance <= radius) return LocationConsistency.consistent;
  if (distance <= radius * 2 || fix.horizontalAccuracy > 50) {
    return LocationConsistency.uncertain;
  }
  return LocationConsistency.outlier;
}

/// Lower is better: temporal distance and reported accuracy dominate; only
/// distance beyond the combined uncertainty radius and neighbor inconsistency
/// add secondary penalties. Source labels never override measured quality.
double scoreLocationFix(
  LocationFix fix,
  DateTime capturedAt, {
  GeoPoint? canonicalLocation,
  Iterable<GeoPoint> neighboringFixes = const [],
}) {
  if (!fix.validFor(capturedAt)) return double.infinity;
  final temporalSeconds = fix.ageAt(capturedAt).inMilliseconds.abs() / 1000;
  var score = temporalSeconds * 2 + fix.horizontalAccuracy * 1.5;
  if (canonicalLocation != null) {
    final distance = distanceBetweenFixAndPoint(fix, canonicalLocation);
    final radius = math.max(
      LocationEvidencePolicy.minimumSiteRadius,
      fix.horizontalAccuracy +
          canonicalLocation.accuracy +
          LocationEvidencePolicy.siteMargin,
    );
    if (distance > radius) score += (distance - radius) * 2;
  }
  if (neighboringFixes.isNotEmpty) {
    final nearest = neighboringFixes
        .map((point) => distanceBetweenFixAndPoint(fix, point))
        .reduce(math.min);
    final allowance = fix.horizontalAccuracy + 25;
    if (nearest > allowance) score += (nearest - allowance) * .5;
  }
  if (fix.isMocked) score += 25;
  return score;
}

bool canEarlyAcceptLocationFix(LocationFix fix, DateTime capturedAt) =>
    fix.validFor(capturedAt) &&
    fix.horizontalAccuracy <= LocationEvidencePolicy.excellentAccuracy &&
    fix.ageAt(capturedAt).abs() <=
        LocationEvidencePolicy.preferredTemporalDelta;

bool locationWindowExpired(DateTime capturedAt, DateTime now) =>
    !now.isBefore(capturedAt.add(LocationEvidencePolicy.postCaptureWindow));

LocationFix? selectBestLocationFix(
  Iterable<LocationFix> fixes,
  DateTime capturedAt, {
  GeoPoint? canonicalLocation,
  Iterable<GeoPoint> neighboringFixes = const [],
}) {
  final valid = fixes
      .where((fix) => fix.validFor(capturedAt))
      .where(
        (fix) =>
            locationConsistency(fix, canonicalLocation) !=
            LocationConsistency.outlier,
      )
      .toList();
  if (valid.isEmpty) return null;
  valid.sort(
    (left, right) =>
        scoreLocationFix(
          left,
          capturedAt,
          canonicalLocation: canonicalLocation,
          neighboringFixes: neighboringFixes,
        ).compareTo(
          scoreLocationFix(
            right,
            capturedAt,
            canonicalLocation: canonicalLocation,
            neighboringFixes: neighboringFixes,
          ),
        ),
  );
  return valid.first;
}

class LocationService {
  final _buffer = <LocationFix>[];
  final _fixes = StreamController<LocationFix>.broadcast();
  StreamSubscription<Position>? _positionSubscription;

  Stream<LocationFix> get fixes => _fixes.stream;
  List<LocationFix> get bufferedFixes => List.unmodifiable(_buffer);

  Future<void> startPrewarm() async {
    if (_positionSubscription != null) return;
    try {
      if (!await _ensurePermission()) return;
      final cached = await Geolocator.getLastKnownPosition();
      if (cached != null) addFix(_fromPosition(cached, source: 'cached'));
      _positionSubscription =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.best,
              distanceFilter: 0,
            ),
          ).listen(
            (position) => addFix(_fromPosition(position, source: 'fused')),
            onError: (_) {},
          );
    } catch (_) {
      // Capture remains available; pending evidence retries on resume/reopen.
    }
  }

  Future<GeoPoint> capture() async {
    if (!await _ensurePermission()) {
      throw StateError('Se requiere ubicación habilitada.');
    }
    final position = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        timeLimit: Duration(seconds: 15),
      ),
    );
    final fix = _fromPosition(position, source: 'fused');
    addFix(fix);
    if (!fix.hasValidCoordinates ||
        fix.horizontalAccuracy > LocationEvidencePolicy.maxHorizontalAccuracy) {
      throw StateError('La precisión debe ser de 100 m o mejor.');
    }
    return fix.toGeoPoint();
  }

  Future<bool> _ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission != LocationPermission.denied &&
        permission != LocationPermission.deniedForever;
  }

  void addFix(LocationFix fix) {
    final cutoff = DateTime.now().toUtc().subtract(
      LocationEvidencePolicy.bufferRetention,
    );
    _buffer
      ..removeWhere((candidate) => candidate.timestamp.isBefore(cutoff))
      ..add(fix);
    _fixes.add(fix);
  }

  LocationFix? bestFix(
    DateTime capturedAt, {
    GeoPoint? canonicalLocation,
    Iterable<GeoPoint> neighboringFixes = const [],
  }) => selectBestLocationFix(
    _buffer,
    capturedAt,
    canonicalLocation: canonicalLocation,
    neighboringFixes: neighboringFixes,
  );

  Future<void> stopPrewarm() async {
    await _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  LocationFix _fromPosition(Position position, {required String source}) =>
      LocationFix(
        latitude: position.latitude,
        longitude: position.longitude,
        horizontalAccuracy: position.accuracy,
        altitude: position.altitude,
        altitudeAccuracy: position.altitudeAccuracy,
        heading: position.heading,
        speed: position.speed,
        timestamp: position.timestamp.toUtc(),
        acquiredAt: DateTime.now().toUtc(),
        source: source,
        isMocked: position.isMocked,
      );

  Future<void> dispose() async {
    await stopPrewarm();
    await _fixes.close();
  }
}
