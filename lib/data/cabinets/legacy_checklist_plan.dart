import '../../domain/cabinets/cabinet_models.dart';
import 'legacy_checklist_confirmation.dart';

/// Pure inspection of durable bodies. Never creates or changes an operation.
class LegacyChecklistPlan {
  final List<String> blockers = [];
  final List<String> missingCodes = [];
  final List<Json> merged = [];
  int requiredCount = 0, firstCount = 0, secondCount = 0;

  LegacyChecklistPlan(
    Json server,
    Json policy,
    List<Json> bodies, {
    bool allowVariableSaves = false,
  }) {
    if (bodies.isEmpty || (!allowVariableSaves && bodies.length != 2)) {
      blockers.add('LEGACY_CHECKLIST_TWO_SAVES_REQUIRED');
      return;
    }
    final hasPolicy = bodies.any((b) => b['partsReviewPolicyVersion'] != null);
    if (hasPolicy &&
        (policy['version'] != 'ddr001-parts-20261019-v2' ||
            bodies.any(
              (b) => b['partsReviewPolicyVersion'] != policy['version'],
            ))) {
      blockers.add('LEGACY_CHECKLIST_POLICY_MISMATCH');
      return;
    }
    final definitions = hasPolicy
        ? cabinetReviewDefinitions(server, policy)
        : objects(server['partDefinitions']);
    final codes = definitions.map((d) => d['code']).toSet();
    requiredCount = codes.length;
    if (codes.isEmpty ||
        codes.length != definitions.length ||
        (hasPolicy &&
            codes.any((c) => !object(policy['parts']).containsKey(c)))) {
      blockers.add('LEGACY_CHECKLIST_CATALOG_INVALID');
      return;
    }
    final captures = <String, Json>{};
    const keys = {
      'code',
      'present',
      'serial',
      'serialException',
      'reason',
      'observations',
      'evidence',
    };
    for (var stage = 0; stage < bodies.length; stage++) {
      final raw = bodies[stage]['parts'];
      if (raw is! List || raw.length > 60 || raw.any((p) => p is! Map)) {
        blockers.add('LEGACY_CHECKLIST_STRUCTURE');
        continue;
      }
      if (stage == 0) firstCount = raw.length;
      if (stage == 1) secondCount = raw.length;
      final seen = <String>{};
      for (var index = 0; index < raw.length; index++) {
        final part = object(raw[index]);
        final code = part['code'];
        final location = 'save${stage + 1}.parts[$index]';
        void fail(String field) =>
            blockers.add('LEGACY_CHECKLIST_INVALID: $location.$field');
        if (code is! String || !codes.contains(code) || !seen.add(code)) {
          fail('code');
          continue;
        }
        if (part.keys.any((k) => !keys.contains(k))) fail('unknown_field');
        if (!part.containsKey('present') ||
            (part['present'] != null && part['present'] is! bool)) {
          fail('present');
        }
        for (final field in ['serial', 'reason', 'observations']) {
          if (!part.containsKey(field)) continue;
          final value = part[field];
          if (field == 'serial' && value == null) continue;
          if (value is! String) {
            fail(field);
            continue;
          }
          final normalized = field == 'observations' ? value : value.trim();
          final min = field == 'reason'
              ? 3
              : field == 'serial'
              ? 1
              : 0;
          if (normalized.length < min ||
              normalized.length > (field == 'serial' ? 180 : 2000)) {
            fail(field);
          }
        }
        final exception = part['serialException'];
        if (exception != null &&
            !['illegible', 'unavailable'].contains(exception)) {
          fail('serialException');
        }
        final definition = definitions.singleWhere((d) => d['code'] == code);
        final serial = part['serial'] is String
            ? (part['serial'] as String).trim()
            : null;
        if (definition['serial'] == 'none' &&
            ((serial?.isNotEmpty ?? false) || exception != null)) {
          fail('serial');
        }
        if (exception != null &&
            (part['reason'] == null || (serial?.isNotEmpty ?? false))) {
          fail('serialException');
        }
        final evidence = part['evidence'];
        if (evidence is! List || evidence.length > 100) {
          fail('evidence');
        } else {
          for (final item in evidence) {
            final e = object(item);
            if (item is! Map ||
                e.keys.any(
                  (k) => !{'photoId', 'confirmed', 'legible'}.contains(k),
                ) ||
                e['confirmed'] != true ||
                e['photoId'] is! String ||
                !RegExp(
                  r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
                ).hasMatch('${e['photoId']}') ||
                (e.containsKey('legible') && e['legible'] is! bool)) {
              fail('evidence');
            }
          }
        }
        final normalized = clone(part);
        for (final k in ['serial', 'reason']) {
          if (normalized[k] is String) {
            normalized[k] = (normalized[k] as String).trim();
          }
        }
        if (captures.containsKey(code) &&
            legacyChecklistDifferences(
              [captures[code]],
              [normalized],
            ).isNotEmpty) {
          fail('contradictory_overlap');
        }
        captures[code] = normalized;
      }
    }
    merged.addAll(captures.values.map(clone));
    missingCodes.addAll(
      codes.whereType<String>().where((c) => !captures.containsKey(c)),
    );
    if (missingCodes.isNotEmpty) {
      blockers.add('LEGACY_CHECKLIST_MISSING_CAPTURES');
    }
    final pending = partsPending({
      ...server,
      'partDefinitions': definitions,
      'parts': merged,
      if (hasPolicy) 'partsReviewPolicy': policy,
    });
    if (pending.isNotEmpty) {
      blockers.add('LEGACY_CHECKLIST_REQUIREMENTS_PENDING');
    }
  }
}
