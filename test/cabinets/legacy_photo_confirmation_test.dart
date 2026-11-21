import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_photo_confirmation.dart';

void main() {
  const id = '7b233347-8b2d-448f-8ebb-0f4fb41af98d';
  Map<String, dynamic> item() => {
    'photoId': id.toUpperCase(),
    'storageVerified': true,
    'status': 'confirmed',
    'originalPresent': true,
    'thumbnailPresent': true,
    'hashMatches': true,
  };
  test(
    'RC11 rejects uppercase SQL GUID; corrected comparison preserves certification',
    () {
      final row = item();
      expect(row['photoId'] == id && row['storageVerified'] == true, false);
      requireLegacyPhotoConfirmation(id, {
        'items': [row],
      });
      row['photoId'] = id;
      requireLegacyPhotoConfirmation(id, {
        'items': [row],
      });
    },
  );
  for (final status in [
    'missing_original',
    'missing_thumbnail',
    'hash_mismatch',
    'not_verified',
  ]) {
    test('visible row with $status never certifies storage', () {
      final row = item()
        ..['storageVerified'] = false
        ..['status'] = status;
      expect(
        () => requireLegacyPhotoConfirmation(id, {
          'items': [row],
        }),
        throwsStateError,
      );
    });
  }
  test(
    'missing, duplicate, other identity, nonboolean and contradictory responses fail closed',
    () {
      for (final response in <Map<String, dynamic>>[
        {},
        {'items': []},
        {
          'items': [item(), item()],
        },
        {
          'items': [
            {...item(), 'photoId': '00000000-0000-4000-8000-000000000000'},
          ],
        },
        {
          'items': [
            {...item(), 'storageVerified': 'true'},
          ],
        },
        {
          'items': [
            {...item(), 'hashMatches': false},
          ],
        },
        {
          'items': [
            {...item(), 'photoId': ' $id'},
          ],
        },
      ]) {
        expect(
          () => requireLegacyPhotoConfirmation(id, response),
          throwsStateError,
        );
      }
    },
  );
  test('diagnostic excludes arbitrary server text and unknown fields', () {
    final row = {
      ...item(),
      'storageVerified': false,
      'status': 'SECRET_URL',
      'details': ['SECRET_TOKEN'],
    };
    try {
      requireLegacyPhotoConfirmation(id, {
        'items': [row],
      });
      fail('must block');
    } on StateError catch (e) {
      expect(e.message, contains('PHOTO_STORAGE_UNCONFIRMED'));
      expect(e.message, isNot(contains('SECRET')));
    }
  });
}
