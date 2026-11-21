import 'dart:convert';

/// Compare durable content without rewriting either receipt. The API sets the
/// transport-only replayed flag to true when reading a persisted receipt.
bool sameLegacyDurableReceipt(
  Map<String, dynamic> confirmed,
  Map<String, dynamic> response,
) {
  for (final receipt in [confirmed, response]) {
    if (receipt.containsKey('replayed') && receipt['replayed'] is! bool) {
      return false;
    }
  }
  Object? canonical(Object? value) {
    if (value is Map<String, dynamic>) {
      final keys = value.keys.toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    if (value is List) return value.map(canonical).toList();
    return value;
  }

  String content(Map<String, dynamic> receipt) => jsonEncode(
    canonical({
      for (final entry in receipt.entries)
        if (entry.key != 'replayed') entry.key: entry.value,
    }),
  );
  return content(confirmed) == content(response);
}
