import 'dart:convert';

// API partCaptureSchema rebuilds object keys and trims only serial and reason.
// Compare a projection; never change the original command or receipt.
List<String> legacyChecklistDifferences(Object? original, Object? remote) {
  if (original is! List ||
      remote is! List ||
      original.any((p) => p is! Map<String, dynamic>) ||
      remote.any((p) => p is! Map<String, dynamic>)) {
    return ['parts:invalid_structure'];
  }
  Object? canonical(Object? value) {
    if (value is Map<String, dynamic>) {
      final keys = value.keys.toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    if (value is List) return value.map(canonical).toList();
    return value;
  }

  const fields = {
    'code',
    'present',
    'serial',
    'serialException',
    'reason',
    'observations',
    'evidence',
  };
  final differences = <String>[];
  final seen = <String>{};
  for (var index = 0; index < original.length; index++) {
    final part = original[index] as Map<String, dynamic>;
    final code = part['code'];
    if (code is! String || code.isEmpty || !seen.add(code)) {
      differences.add('parts[$index].code:invalid_or_duplicate');
      continue;
    }
    final matches = remote
        .cast<Map<String, dynamic>>()
        .where((p) => p['code'] == code)
        .toList();
    if (matches.length != 1) {
      differences.add('parts[$index].code:missing_or_duplicate');
      continue;
    }
    final confirmed = matches.single;
    for (final key in {...part.keys, ...confirmed.keys}) {
      var expected = part[key];
      if ((key == 'serial' || key == 'reason') && expected is String) {
        expected = expected.trim();
      }
      if (part.containsKey(key) != confirmed.containsKey(key) ||
          jsonEncode(canonical(expected)) !=
              jsonEncode(canonical(confirmed[key]))) {
        differences.add(
          'parts[$index].${fields.contains(key) ? key : 'other_field'}:different',
        );
      }
    }
  }
  return differences;
}
