import 'dart:convert';
import 'dart:math' as math;
import 'cabinet_models.dart';

String? reasonError(Object? value) {
  final text = (value ?? '').toString().trim();
  if (text.length < 3) return 'Escribe un motivo de al menos 3 caracteres.';
  if (text.length > 2000) {
    return 'El motivo debe tener como máximo 2000 caracteres.';
  }
  return null;
}

String normalizeSerial(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');
String partIdentity(Json p) =>
    jsonEncode([p['key'], p['description'], p['position'], p['serial']]);

/// Remap only unambiguous physical components. Photos and history are retained separately.
List<Json> compatibleParts(Json current, List<Json> next) {
  final old = objects(current['partDefinitions']);
  final captures = objects(current['parts']);
  final result = <Json>[];
  for (final definition in next) {
    final key = partIdentity(definition);
    final matches = old.where((p) => partIdentity(p) == key).toList();
    if (matches.length != 1 ||
        next.where((p) => partIdentity(p) == key).length != 1) {
      continue;
    }
    final capture = captures
        .where((p) => p['code'] == matches.single['code'])
        .firstOrNull;
    if (capture != null) {
      result.add({...clone(capture), 'code': definition['code']});
    }
  }
  return result;
}

List<String> duplicateSerialWarnings(Json cabinet) {
  final serials = <String, List<String>>{};
  for (final p in objects(cabinet['parts'])) {
    final serial = normalizeSerial('${p['serial'] ?? ''}').toUpperCase();
    if (serial.isNotEmpty) (serials[serial] ??= []).add('${p['code']}');
  }
  return serials.entries
      .where((e) => e.value.length > 1)
      .map(
        (e) =>
            'Serie ${e.key} repetida en ${e.value.join(', ')}. Comprueba las placas.',
      )
      .toList();
}

const installationGpsMaxAge = Duration(minutes: 15);
bool freshInstallationGps(Object? capturedAt, DateTime now) {
  final at = DateTime.tryParse('$capturedAt');
  if (at == null) return false;
  final age = now.toUtc().difference(at.toUtc());
  return age >= const Duration(seconds: -30) && age <= installationGpsMaxAge;
}

double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  double rad(double x) => x * math.pi / 180;
  final a =
      math.pow(math.sin(rad(lat2 - lat1) / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(rad(lon2 - lon1) / 2), 2);
  return 6371000 * 2 * math.asin(math.sqrt(a.clamp(0, 1)));
}

Json checkedCabinetPayload(String type, Json input) {
  final result = clone(input);
  void clean(Json value) {
    for (final key in ['reason', 'observations']) {
      if (value[key] == null) continue;
      final text = '${value[key]}'.trim();
      if (text.isEmpty) {
        value.remove(key);
        continue;
      }
      if (text.length > 2000 || (key == 'reason' && text.length < 3)) {
        throw StateError(
          key == 'reason'
              ? reasonError(text)!
              : 'La observación debe tener como máximo 2000 caracteres.',
        );
      }
      value[key] = text;
    }
  }

  clean(result);
  if (type == 'parts_save') {
    final parts = objects(result['parts']);
    for (final p in parts) {
      clean(p);
      if (p['serial'] != null) {
        final serial = normalizeSerial('${p['serial']}');
        if (serial.length > 180) {
          throw StateError('La serie de ${p['code']} supera 180 caracteres.');
        }
        p['serial'] = serial.isEmpty ? null : serial;
      }
      if (p['serialException'] != null && reasonError(p['reason']) != null) {
        throw StateError(
          'Explica por qué falta la serie de ${p['code']} (3 a 2000 caracteres).',
        );
      }
    }
    result['parts'] = parts;
  }
  if (type == 'installation_save') {
    final i = object(result['installation']);
    clean(i);
    final answers = objects(i['answers']);
    for (final a in answers) {
      clean(a);
      if (a['answer'] != 'yes' && reasonError(a['reason']) != null) {
        throw StateError(
          '${a['code']}: explica la respuesta (3 a 2000 caracteres).',
        );
      }
    }
    i['answers'] = answers;
    if (i['accountResolution'] != null) {
      final resolution = object(i['accountResolution']);
      clean(resolution);
      if (reasonError(resolution['reason']) != null) {
        throw StateError(
          'Explica la discrepancia de cuenta (3 a 2000 caracteres).',
        );
      }
      i['accountResolution'] = resolution;
    }
    result['installation'] = i;
  }
  return result;
}

String partGroupLabel(String group) {
  if (group.startsWith('outlet_')) return 'Salida ${group.substring(7)}';
  return const {
        'cabinet': 'Gabinete',
        'district': 'Distrito',
        'producer': 'Productor',
        'venturi': 'Venturi',
        'flushing': 'Lavado',
        'principal': 'Principal',
        'automation': 'Automatización',
      }[group] ??
      group.replaceAll('_', ' ');
}
