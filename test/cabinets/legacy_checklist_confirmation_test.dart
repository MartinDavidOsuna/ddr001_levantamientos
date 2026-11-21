import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_checklist_confirmation.dart';

void main() {
  test('actual API schema fixtures: key order and only contractual trims', () {
    final cases =
        jsonDecode(
              File(
                'test/cabinets/fixtures/legacy-checklist-api-normalization.json',
              ).readAsStringSync(),
            )
            as List;
    expect(
      jsonEncode(cases.first['input']) == jsonEncode(cases.first['output']),
      isFalse,
    ); // RC12 raw JSON hash rejects this legitimate API result.
    final before = jsonEncode(cases);
    for (final c in cases) {
      expect(legacyChecklistDifferences([c['input']], [c['output']]), isEmpty);
    }
    expect(jsonEncode(cases), before);
  });
  test(
    'real content and types remain protected; diagnostics contain no values',
    () {
      final p = <String, dynamic>{
        'code': 'PRIVATE-CODE',
        'present': true,
        'serial': 'SERIAL-PRIVATE',
        'serialException': null,
        'reason': 'motivo',
        'observations': ' intacto ',
        'evidence': [
          {'photoId': 'private-photo', 'confirmed': true},
        ],
        'quantity': 2,
      };
      for (final change in <Map<String, dynamic>>[
        {'present': false},
        {'present': 'true'},
        {'serial': 'OTHER'},
        {'serialException': 'unavailable'},
        {'observations': 'intacto'},
        {'reason': 'otro motivo'},
        {'quantity': 3},
        {'evidence': []},
        {'code': 'other'},
      ]) {
        final d = legacyChecklistDifferences(
          [p],
          [
            {...p, ...change},
          ],
        );
        expect(d, isNotEmpty);
        expect(d.join(), isNot(contains('PRIVATE')));
      }
      final missing = {...p}..remove('serialException');
      expect(legacyChecklistDifferences([p], [missing]), isNotEmpty);
      expect(legacyChecklistDifferences([p], [p, p]), isNotEmpty);
      expect(legacyChecklistDifferences([p, p], [p]), isNotEmpty);
      expect(legacyChecklistDifferences([null], [p]), isNotEmpty);
      expect(legacyChecklistDifferences(null, [p]), isNotEmpty);
    },
  );
  test('parts keyed by code, preserve evidence order and optional fields', () {
    final a = {
      'code': 'A',
      'present': true,
      'evidence': [
        {'photoId': '1', 'confirmed': true},
        {'photoId': '2', 'confirmed': true},
      ],
    };
    final b = {'code': 'B', 'present': null, 'evidence': []};
    expect(legacyChecklistDifferences([a, b], [b, a]), isEmpty);
    expect(
      legacyChecklistDifferences(
        [a],
        [
          {...a, 'evidence': (a['evidence'] as List).reversed.toList()},
        ],
      ),
      isNotEmpty,
    );
  });
}
