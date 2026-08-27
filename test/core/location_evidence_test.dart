import 'dart:io';

import 'package:ddr001_levantamientos/core/location/location_service.dart';
import 'package:ddr001_levantamientos/core/persistence/local_store.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

final capture = DateTime.utc(2026, 8, 27, 12);

LocationFix fix({
  double accuracy = 5,
  int deltaSeconds = 0,
  double latitude = 21.9159,
  double longitude = -102.3054,
  String source = 'gnss',
  bool mocked = false,
}) => LocationFix(
  latitude: latitude,
  longitude: longitude,
  horizontalAccuracy: accuracy,
  altitude: 1864,
  altitudeAccuracy: 3,
  heading: 20,
  speed: 0,
  timestamp: capture.add(Duration(seconds: deltaSeconds)),
  acquiredAt: capture.add(Duration(seconds: deltaSeconds + 1)),
  source: source,
  isMocked: mocked,
);

GeoPoint point({
  double latitude = 21.9159,
  double longitude = -102.3054,
  double accuracy = 5,
}) => GeoPoint(
  latitude: latitude,
  longitude: longitude,
  accuracy: accuracy,
  capturedAt: capture,
);

ConstructionPhoto photo({
  PhotoLocationState state = PhotoLocationState.pending,
  GeoPoint? location,
}) => ConstructionPhoto(
  id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  surveyId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  localPath: '/tmp/photo.jpg',
  thumbnailPath: '/tmp/photo_thumb.jpg',
  sha256: List.filled(64, 'a').join(),
  capturedAt: capture,
  stepNumber: 1,
  syncState: PhotoSyncState.localOnly,
  location: location,
  locationState: state,
);

void main() {
  test('excellent fix five seconds before capture is selected', () {
    final selected = selectBestLocationFix([
      fix(accuracy: 6, deltaSeconds: -5),
    ], capture);
    expect(selected?.ageAt(capture), const Duration(seconds: -5));
  });

  test('excellent posterior fix replaces mediocre pre-capture fix', () {
    final selected = selectBestLocationFix([
      fix(accuracy: 45, deltaSeconds: -8),
      fix(accuracy: 5, deltaSeconds: 7),
    ], capture);
    expect(selected?.horizontalAccuracy, 5);
  });

  test('temporally close excellent fix beats marginally better late fix', () {
    final selected = selectBestLocationFix([
      fix(accuracy: 4, deltaSeconds: 10),
      fix(accuracy: 2, deltaSeconds: 115),
    ], capture);
    expect(selected?.horizontalAccuracy, 4);
  });

  test('Internet or network source never overrides better GNSS quality', () {
    final selected = selectBestLocationFix([
      fix(accuracy: 35, source: 'network'),
      fix(accuracy: 6, deltaSeconds: 2, source: 'gnss'),
    ], capture);
    expect(selected?.source, 'gnss');
  });

  test('airplane-mode GNSS fix is valid without connectivity metadata', () {
    final gnss = fix(accuracy: 8, source: 'gnss');
    expect(gnss.validFor(capture), isTrue);
    expect(canEarlyAcceptLocationFix(gnss, capture), isTrue);
  });

  test('late GNSS fix inside post-capture window remains associable', () {
    expect(fix(deltaSeconds: 119).validFor(capture), isTrue);
  });

  test('fix outside post-capture window is rejected', () {
    expect(selectBestLocationFix([fix(deltaSeconds: 121)], capture), isNull);
  });

  test('pre-capture fix older than sixty seconds is rejected', () {
    expect(fix(deltaSeconds: -61).validFor(capture), isFalse);
  });

  test('accuracy above 100 meters is invalid', () {
    expect(fix(accuracy: 100.1).validFor(capture), isFalse);
    expect(locationConfidence(100.1), LocationConfidence.invalid);
  });

  test('accuracy bands are deterministic', () {
    expect(locationConfidence(10), LocationConfidence.excellent);
    expect(locationConfidence(25), LocationConfidence.good);
    expect(locationConfidence(50), LocationConfidence.acceptable);
    expect(locationConfidence(100), LocationConfidence.weak);
  });

  test('early acceptance accepts good or excellent temporally close fix', () {
    expect(
      canEarlyAcceptLocationFix(fix(accuracy: 10, deltaSeconds: 30), capture),
      isTrue,
    );
    expect(
      canEarlyAcceptLocationFix(fix(accuracy: 25, deltaSeconds: 30), capture),
      isTrue,
    );
    expect(
      canEarlyAcceptLocationFix(fix(accuracy: 26, deltaSeconds: 5), capture),
      isFalse,
    );
    expect(
      canEarlyAcceptLocationFix(fix(accuracy: 5, deltaSeconds: 31), capture),
      isFalse,
    );
  });

  test('canonical consistency uses combined uncertainty radius', () {
    expect(
      locationConsistency(
        fix(latitude: 21.9160, accuracy: 20),
        point(accuracy: 20),
      ),
      LocationConsistency.consistent,
    );
  });

  test('clearly remote location is an outlier and cannot be selected', () {
    final remote = fix(latitude: 21.9359, longitude: -102.3054);
    expect(locationConsistency(remote, point()), LocationConsistency.outlier);
    expect(
      selectBestLocationFix([remote], capture, canonicalLocation: point()),
      isNull,
    );
  });

  test(
    'neighbor clustering penalizes isolated fixes without inventing GPS',
    () {
      final clustered = fix(accuracy: 12, longitude: -102.30541);
      final isolated = fix(accuracy: 10, deltaSeconds: 1, longitude: -102.3154);
      expect(
        scoreLocationFix(clustered, capture, neighboringFixes: [point()]),
        lessThan(
          scoreLocationFix(isolated, capture, neighboringFixes: [point()]),
        ),
      );
    },
  );

  test('pending, provisional, confirmed and unresolved remain distinct', () {
    expect(photo().locationPending, isTrue);
    expect(
      photo(
        state: PhotoLocationState.provisional,
        location: point(),
      ).locationPending,
      isTrue,
    );
    expect(
      photo(
        state: PhotoLocationState.confirmed,
        location: point(),
      ).locationConfirmed,
      isTrue,
    );
    expect(
      photo(state: PhotoLocationState.unresolved).locationUnresolved,
      isTrue,
    );
  });

  test(
    'capture time and fix timestamp persist separately with integrity metadata',
    () {
      final original =
          photo(
            state: PhotoLocationState.confirmed,
            location: point(),
          ).copyWith(
            locationFixAt: capture.add(const Duration(seconds: 12)),
            locationAcquiredAt: capture.add(const Duration(seconds: 13)),
            locationTemporalDeltaMs: 12000,
            locationConfidence: LocationConfidence.excellent,
            locationIntegrityFlag: LocationIntegrityFlag.mocked,
          );
      final restored = ConstructionPhoto.fromJson(original.toJson());
      expect(restored.capturedAt, capture);
      expect(restored.locationFixAt, capture.add(const Duration(seconds: 12)));
      expect(restored.locationTemporalDeltaMs, 12000);
      expect(restored.locationIntegrityFlag, LocationIntegrityFlag.mocked);
    },
  );

  test('legacy photo with location migrates as confirmed', () {
    final json = photo(location: point()).toJson()..remove('locationState');
    expect(
      ConstructionPhoto.fromJson(json).locationState,
      PhotoLocationState.confirmed,
    );
  });

  test('expiration is deterministic and does not use a later current fix', () {
    expect(
      locationWindowExpired(capture, capture.add(const Duration(seconds: 119))),
      isFalse,
    );
    expect(
      locationWindowExpired(capture, capture.add(const Duration(seconds: 120))),
      isTrue,
    );
  });

  test(
    'force-stop style Hive reopen preserves pending photo and UUID',
    () async {
      final root = await Directory.systemTemp.createTemp('location-pending-');
      Hive.init(root.path);
      var store = await LocalStore.open();
      await store.savePhoto(photo());
      await Hive.close();
      Hive.init(root.path);
      store = await LocalStore.open();
      expect(store.photos().single.locationState, PhotoLocationState.pending);
      expect(store.photos().single.id, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
      await Hive.close();
      await root.delete(recursive: true);
    },
  );
}
