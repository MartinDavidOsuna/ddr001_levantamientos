import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_operation_diagnostic.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';

void main() {
  final operations = <Json>[
    for (final entry in [
      [
        'registration_close',
        '37ad7f83-cfb9-4c88-a65b-cbe677034351',
        1,
        'conflict',
      ],
      ['parts_save', 'e021bff6-edd1-452a-a4ac-a2772adb019b', 2, 'queued'],
      ['parts_save', '33718abb-9fb0-44ea-ba9b-609b10222e64', 3, 'queued'],
      ['parts_validate', '3b078e96-2ea5-4405-b516-bf8fc5b04e89', 4, 'queued'],
    ])
      {
        'actor': 'synthetic-actor',
        'state': entry[3],
        'body': {
          'type': entry[0],
          'operationId': entry[1],
          'expectedVersion': entry[2],
          'capturedAt': '2026-10-22T18:44:29.718Z',
          if (entry[0] == 'registration_close')
            'evidence': [
              for (var i = 0; i < 5; i++)
                {
                  'photoId': 'b1000000-0000-4000-8000-00000000000$i',
                  'confirmed': true,
                },
            ],
        },
      },
  ];
  final photos = <Json>[
    for (var i = 0; i < 5; i++)
      {
        'id': 'b1000000-0000-4000-8000-00000000000$i',
        'metadata': {'context': 'registration'},
      },
  ];
  test(
    'exact four historical operations and five photos: read-only unknown cause',
    () {
      final historical = <String, dynamic>{
        'server': {'status': 'draft', 'version': 1},
        'working': {
          'status': 'validated',
          'parts': [
            for (var n = 0; n < 24; n++)
              {'code': 'historical-synthetic-$n', 'present': true},
          ],
        },
        'photos': photos,
        'operations': operations,
      };
      final before = jsonEncode(historical);
      expect(objects(object(historical['working'])['parts']), hasLength(24));
      for (var i = 0; i < operations.length; i++) {
        final d = LegacyOperationDiagnostic(
          operations[i],
          actor: 'synthetic-actor',
          index: i,
          photos: photos,
        );
        expect(d.code, 'no conservado');
        expect(d.http, 'no conservado');
        expect(d.receipt, 'no consultado');
        if (i == 0) {
          expect(
            d.photoSummary,
            contains('5 referencias; 5 descriptores locales; 5'),
          );
          expect(d.compatibility, startsWith('prevalidación'));
        } else {
          expect(d.dependency, contains('anterior confirmada'));
        }
      }
      expect(jsonEncode(historical), before);
    },
  );
  for (final code in [
    'VERSION_CONFLICT',
    'CAUSAL_PHOTO_MISSING',
    'EVIDENCE_NOT_VERIFIED',
    'EVIDENCE_OUT_OF_SCOPE',
    'COMPANY_CHANGED',
    'CABINET_RESIDENT_REQUIRED',
  ]) {
    test(
      'classifies $code without releasing conflict or revealing response',
      () {
        final op = clone(operations.first)
          ..['problem'] = {'code': code, 'detail': 'SECRET_SENTINEL'};
        op['diagnostic'] = {'httpStatus': 409, 'headers': 'SECRET_SENTINEL'};
        final before = jsonEncode(op);
        final d = LegacyOperationDiagnostic(
          op,
          actor: 'synthetic-actor',
          index: 0,
          photos: photos,
        );
        expect(d.code, code);
        expect(d.http, '409');
        expect(d.summary, isNot(contains('SECRET_SENTINEL')));
        expect(jsonEncode(op), before);
      },
    );
  }
  test('transient evidence is a proposal, never authorization', () {
    final op = clone(operations.first)..['diagnostic'] = {'httpStatus': 503};
    final d = LegacyOperationDiagnostic(
      op,
      actor: 'synthetic-actor',
      index: 0,
      photos: photos,
    );
    d.receipt = 'inexistente: 404 OPERATION_NOT_FOUND';
    expect(d.transient, true);
    expect(d.recommendation, contains('no liberado'));
    expect(op['state'], 'conflict');
  });
  test('old payload and actor conflict remain explicit', () {
    final op = clone(operations.first);
    object(op['body']);
    (op['body'] as Map)['oldField'] = 'SECRET_SENTINEL';
    final d = LegacyOperationDiagnostic(
      op,
      actor: 'different',
      index: 0,
      photos: photos,
    );
    expect(d.category, 'actor distinto');
    expect(d.compatibility, contains('campos adicionales'));
    expect(d.recommendation, contains('No transmitir'));
    expect(d.summary, isNot(contains('SECRET_SENTINEL')));
  });
  test('unknown error codes and free text are not exposed', () {
    final op = clone(operations.first)
      ..['problem'] = {'code': 'SECRET_SENTINEL'};
    op['error'] = 'Bearer SECRET_SENTINEL';
    final d = LegacyOperationDiagnostic(
      op,
      actor: 'synthetic-actor',
      index: 0,
      photos: photos,
    );
    expect(d.summary, isNot(contains('SECRET_SENTINEL')));
  });
}
