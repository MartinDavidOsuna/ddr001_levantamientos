import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/data/cabinets/legacy_receipt_confirmation.dart';

void main() {
  test('GET replay flag and object order do not change durable content', () {
    final response = <String, dynamic>{
      'replayed': false,
      'operationId': 'original',
      'cabinet': {'version': 2, 'status': 'registered'},
    };
    final confirmed = <String, dynamic>{
      'cabinet': {'status': 'registered', 'version': 2},
      'operationId': 'original',
      'replayed': true,
    };
    final before = jsonEncode([response, confirmed]);
    expect(sameLegacyDurableReceipt(confirmed, response), isTrue);
    expect(jsonEncode([response, confirmed]), before);
  });
  test(
    'all durable fields, nested flags and list order remain significant',
    () {
      final receipt = <String, dynamic>{
        'operationId': 'original',
        'version': 2,
        'items': [1, 2],
        'nested': {'replayed': false},
      };
      for (final changed in <Map<String, dynamic>>[
        {...receipt, 'operationId': 'other'},
        {...receipt, 'version': 3},
        {
          ...receipt,
          'items': [2, 1],
        },
        {
          ...receipt,
          'nested': {'replayed': true},
        },
        {...receipt, 'extra': true},
        {...receipt, 'replayed': 'true'},
        {...receipt, 'replayed': null},
      ]) {
        expect(sameLegacyDurableReceipt(changed, receipt), isFalse);
      }
    },
  );
}
