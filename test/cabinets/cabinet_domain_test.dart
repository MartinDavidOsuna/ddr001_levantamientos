import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'harness.dart';

void main() {
  test(
    'QR canonical URL, UID and visible identity share checksum validation',
    () {
      for (final input in [
        'https://id.aquafim.com/ddr001/AQ26000017',
        'AQ26000017',
        'AQ26-00001-7',
      ]) {
        expect(cabinetUid(input), 'AQ26000017');
      }
      expect(displayUid('AQ26000017'), 'AQ26-00001-7');
      for (final bad in [
        'http://id.aquafim.com/ddr001/AQ26000017',
        'https://evil.test/ddr001/AQ26000017',
        'https://id.aquafim.com/ddr001/AQ26000017?x=1',
        'https://id.aquafim.com/x/../ddr001/AQ26000017',
        'AQ26000018',
        'AQ26000000',
        'aq26000017',
      ]) {
        expect(() => cabinetUid(bad), throwsFormatException);
      }
    },
  );
  test(
    'actual API fixture reconciles all eight variants and individual serials',
    () {
      final catalog = fixtureCatalog();
      final expected = [14, 32, 16, 35, 18, 38, 20, 41];
      var index = 0;
      for (final model in ['A1', 'A2', 'A3', 'A4']) {
        for (final automated in [false, true]) {
          final parts = catalog.parts(model, automated);
          expect(parts.length, expected[index++]);
          expect(parts.map((p) => p['code']).toSet().length, parts.length);
          expect(
            parts.where((p) => p['serial'] == 'required').length,
            automated ? 7 : 1,
          );
          expect(
            parts.where((p) => '${p['description']}'.contains('KELLER')).length,
            automated ? 2 : 0,
          );
          expect(
            parts
                .where(
                  (p) =>
                      '${p['description']}'.contains('SOLENOIDE') ||
                      '${p['description']}'.contains('KELLER'),
                )
                .every((p) => p['serial'] == 'none'),
            isTrue,
          );
        }
      }
      expect(
        catalog
            .parts('A4', true)
            .where(
              (p) =>
                  '${p['description']}'.contains('SOLENOIDE') &&
                  '${p['position']}'.startsWith('flushing'),
            )
            .length,
        2,
      );
      expect(catalog.questions.length, 84);
    },
  );
  test(
    'required serial exceptions remain incomplete; plate requires legibility',
    () {
      final part = fixtureCatalog()
          .parts('A1', false)
          .firstWhere((p) => p['serial'] == 'required');
      Json cabinet = {
        'partDefinitions': [part],
        'parts': [
          {
            'code': part['code'],
            'present': true,
            'serialException': 'illegible',
            'reason': 'Placa dañada',
            'evidence': [
              {'photoId': 'p', 'confirmed': true},
            ],
          },
        ],
      };
      expect(
        partsPending(cabinet).single['reason'],
        'Serie obligatoria pendiente',
      );
      cabinet['parts'] = [
        {
          'code': part['code'],
          'present': true,
          'serial': 'AB00001',
          'evidence': [
            {'photoId': 'p', 'confirmed': true},
          ],
        },
      ];
      expect(partsPending(cabinet), isNotEmpty);
      cabinet['parts'] = [
        {
          'code': part['code'],
          'present': true,
          'serial': 'AB00001',
          'evidence': [
            {'photoId': 'p', 'confirmed': true, 'legible': true},
          ],
        },
      ];
      expect(partsPending(cabinet), isEmpty);
    },
  );
  test('policy starts pending and bulk excludes critical checks', () {
    final catalog = fixtureCatalog(),
        cabinet = <String, dynamic>{
          'automated': true,
          'installation': {'answers': [], 'evidence': {}},
        };
    expect(installationPending(cabinet, catalog).length, 84);
    for (final code in [
      'CI001',
      'CI005',
      'CI016',
      'CI029',
      'CI033',
      'CI065',
      'CI073',
      'CI079',
    ]) {
      expect(
        canConfirmBlock(catalog.questions.firstWhere((q) => q['code'] == code)),
        isFalse,
      );
    }
    final manual = catalog.applicable({'automated': false});
    expect(manual.any((q) => q['code'] == 'CI084'), isFalse);
  });
  test(
    'policy distinguishes failed leaks, permitted deferred tests and minor observations',
    () {
      final catalog = fixtureCatalog();
      List<Json> pending(Json answer) => installationPending({
        'automated': true,
        'installation': {
          'answers': [answer],
        },
      }, catalog).where((p) => p['subject'] == answer['code']).toList();
      expect(
        pending({
          'code': 'CI016',
          'answer': 'no',
          'reason': 'Fuga visible',
        }).single['classification'],
        'blocking',
      );
      expect(
        pending({
          'code': 'CI016',
          'answer': 'not_checked',
          'reason': 'No hay agua',
          'pendingReason': 'no_water',
        }).single['classification'],
        'mandatory_test',
      );
      expect(
        pending({
          'code': 'CI007',
          'answer': 'no',
          'reason': 'Rayón menor',
          'assessment': 'minor',
          'impact': {'safety': false, 'protection': false, 'function': false},
        }).single['classification'],
        'minor',
      );
      expect(
        pending({
          'code': 'CI001',
          'answer': 'not_applicable',
          'reason': 'No revisado',
        }).single['classification'],
        'blocking',
      );
    },
  );
}
