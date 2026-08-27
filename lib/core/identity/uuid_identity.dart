String canonicalUuid(String value) => value.trim().toLowerCase();

String? canonicalUuidOrNull(String? value) =>
    value == null ? null : canonicalUuid(value);

bool uuidEquals(String? left, String? right) =>
    left != null &&
    right != null &&
    canonicalUuid(left) == canonicalUuid(right);

List<String> canonicalUuidList(Iterable<String> values) =>
    values.map(canonicalUuid).toSet().toList(growable: false);
