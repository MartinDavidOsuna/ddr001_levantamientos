import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_checklist_plan.dart';

void main() {
  late Json server, policy;
  late List<Json> bodies;
  setUp(() {
    final c = object(
      jsonDecode(
        File('test/cabinets/fixtures/rc13-a3-contract.json').readAsStringSync(),
      ),
    );
    policy = object(c['policy']);
    server = {
      'model': 'A3',
      'automated': false,
      'catalogVersion': c['version'],
      'partDefinitions': c['definitions'],
      'partsReviewPolicy': policy,
    };
    final captures = objects(c['definitions'])
        .map(
          (d) => <String, dynamic>{
            'code': d['code'],
            'present': true,
            if (d['serial'] == 'required') 'serial': '  SYNTHETIC-123  ',
            'evidence': <Json>[],
          },
        )
        .toList();
    bodies = [
      for (final side in ['district', 'producer'])
        {
          'partsReviewPolicyVersion': policy['version'],
          'parts': captures
              .where(
                (p) =>
                    object(object(policy['parts'])[p['code']])['side'] == side,
              )
              .toList(),
        },
    ];
  });
  test('9 + 15 exact contract codes cover 24 without modifying bodies', () {
    final before = jsonEncode(bodies);
    final plan = LegacyChecklistPlan(server, policy, bodies);
    expect(plan.blockers, isEmpty);
    expect(plan.requiredCount, 24);
    expect(plan.merged.length, 24);
    expect(plan.firstCount, 9);
    expect(plan.secondCount, 15);
    expect(jsonEncode(bodies), before);
  });
  for (final scenario in [
    'missing',
    'duplicate',
    'unknown',
    'present',
    'serial',
    'null',
    'type',
    'optional',
    'evidence',
    'policy',
    'catalog',
    'overlap',
  ]) {
    test('unsafe second command or prerequisites blocked: $scenario', () {
      final second = bodies[1]['parts'] as List;
      final first = (bodies[0]['parts'] as List).first as Json;
      switch (scenario) {
        case 'missing':
          second.removeLast();
        case 'duplicate':
          second.add(clone(second.first));
        case 'unknown':
          second.first['code'] = 'NOT-IN-CATALOG';
        case 'present':
          second.first['present'] = false;
        case 'serial':
          first['serial'] = '   ';
        case 'null':
          second.first['present'] = null;
        case 'type':
          second.first['present'] = 'true';
        case 'optional':
          second.first['observations'] = null;
        case 'evidence':
          second.first['evidence'] = [
            {'photoId': 'invalid', 'confirmed': true},
          ];
        case 'catalog':
          (policy['parts'] as Map).remove(first['code']);
        case 'policy':
          bodies[1]['partsReviewPolicyVersion'] = 'unrecognized';
        case 'overlap':
          second.add({...first, 'serial': 'CHANGED'});
      }
      final before = jsonEncode(bodies);
      expect(LegacyChecklistPlan(server, policy, bodies).blockers, isNotEmpty);
      expect(jsonEncode(bodies), before);
    });
  }
}
