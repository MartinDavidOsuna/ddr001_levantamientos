import 'dart:convert';

typedef Json = Map<String, dynamic>;
Json object(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
List<Json> objects(Object? value) =>
    value is List ? value.map(object).toList() : [];
Json clone(Json value) => object(jsonDecode(jsonEncode(value)));

String cabinetUid(String input) {
  var uid = input;
  if (input.startsWith('https://')) {
    if (!RegExp(r'^https://id\.aquafim\.com/ddr001/AQ\d{8}$').hasMatch(input)) {
      throw const FormatException(
        'El QR no pertenece a un gabinete DDR001 válido.',
      );
    }
    uid = input.substring('https://id.aquafim.com/ddr001/'.length);
  }
  if (RegExp(r'^AQ\d{2}-\d{5}-\d$').hasMatch(uid)) {
    uid = uid.replaceAll('-', '');
  }
  if (!RegExp(r'^AQ\d{8}$').hasMatch(uid) ||
      int.parse(uid.substring(4, 9)) == 0) {
    throw const FormatException('UID inválido: revisa formato y consecutivo.');
  }
  var p = 10;
  for (final digit in uid.substring(2, 9).split('')) {
    var s = (p + int.parse(digit)) % 10;
    if (s == 0) s = 10;
    p = (s * 2) % 11;
  }
  if ((11 - p) % 10 != int.parse(uid[9])) {
    throw const FormatException('El dígito verificador del UID no coincide.');
  }
  return uid;
}

String displayUid(String uid) =>
    '${uid.substring(0, 4)}-${uid.substring(4, 9)}-${uid[9]}';
String cabinetStatus(String? status) =>
    const {
      'draft': 'Borrador',
      'registered': 'Registrado',
      'incomplete': 'Incompleto',
      'validated': 'Validado',
      'installed': 'Instalado',
      'deliverable': 'Entregable',
    }[status] ??
    'Borrador';
const cabinetGroups = {
  'identity': 'Identidad y ubicación',
  'anchoring': 'Base y anclaje',
  'cabinet': 'Gabinete y acceso',
  'hydraulics': 'Hidráulica',
  'wiring': 'Cableado y batería',
  'solar': 'Paneles solares',
  'automation': 'Actuadores y sensores',
  'function': 'Pruebas de funcionamiento',
  'environment': 'Entorno y limpieza',
  'evidence': 'Fotografías',
};
const answerLabels = {
  'yes': 'Sí',
  'no': 'No',
  'not_checked': 'No comprobado',
  'not_applicable': 'No aplica',
};
const pendingLabels = {
  'no_water': 'Falta de agua',
  'no_pressure': 'Falta de presión',
  'no_power': 'Falta de alimentación',
  'no_solar_conditions': 'Sin condiciones solares',
};

class CabinetCatalog {
  CabinetCatalog(this.json) {
    if (json['version'] is! String ||
        objects(json['models']).length != 8 ||
        questions.length != 84) {
      throw const FormatException(
        'API de gabinetes incompatible o catálogo incompleto.',
      );
    }
  }
  final Json json;
  String get version => json['version'] as String;
  String get policyVersion =>
      object(json['policy'])['closurePolicyVersion'] as String;
  List<Json> get questions => objects(object(json['policy'])['questions']);
  List<Json> parts(String model, bool automated) => objects(
    objects(json['models']).firstWhere(
      (m) => m['model'] == model && m['automated'] == automated,
    )['parts'],
  );
  List<Json> applicable(Json cabinet) => questions
      .where((q) => q['automatedOnly'] != true || cabinet['automated'] == true)
      .toList();
}

/// Advisory local checks interpret the downloaded policy. Server closure is authoritative.
List<Json> partsPending(Json cabinet) {
  final result = <Json>[];
  for (final p in objects(cabinet['partDefinitions'])) {
    final capture =
        objects(
          cabinet['parts'],
        ).where((c) => c['code'] == p['code']).firstOrNull ??
        {};
    void add(String reason) => result.add({
      'subject': p['code'],
      'classification': 'blocking',
      'reason': reason,
    });
    if (capture['present'] != true) {
      add('Pieza faltante o sin revisar');
      continue;
    }
    final evidence = objects(capture['evidence']);
    if (evidence.isEmpty) add('Falta evidencia confirmada');
    if (p['serial'] == 'required' &&
        ((capture['serial'] ?? '').toString().isEmpty ||
            capture['serialException'] != null)) {
      add('Serie obligatoria pendiente');
    }
    if ((capture['serial'] ?? '').toString().isNotEmpty &&
        !evidence.any((e) => e['legible'] == true)) {
      add('Confirma la legibilidad de la placa');
    }
  }
  return result;
}

List<Json> installationPending(Json cabinet, CabinetCatalog catalog) {
  final result = <Json>[];
  final installation = object(cabinet['installation']);
  for (final q in catalog.applicable(cabinet)) {
    final code = q['code'];
    final a =
        objects(
          installation['answers'],
        ).where((a) => a['code'] == code).firstOrNull ??
        {};
    String? reason;
    var classification = 'blocking';
    if (q['kind'] == 'evidence') {
      if (objects(object(installation['evidence'])[code]).isEmpty) {
        reason = 'Falta fotografía confirmada';
      }
    } else if (a.isEmpty) {
      reason = 'Sin comprobar';
    } else if (a['answer'] == 'yes') {
      if (code == 'CI031') {
        for (final p in objects(
          cabinet['parts'],
        ).where((p) => (p['serial'] ?? '').toString().isNotEmpty)) {
          if (!(a['serialComponents'] as List? ?? []).contains(p['code']) ||
              !objects(p['evidence']).any(
                (e) =>
                    e['legible'] == true &&
                    objects(a['evidence']).any(
                      (r) =>
                          r['photoId'] == e['photoId'] && r['legible'] == true,
                    ),
              )) {
            reason = 'Comprueba las placas de todas las series';
          }
        }
      }
    } else if ((a['reason'] ?? '').toString().trim().length < 3) {
      reason = 'Falta motivo';
    } else if (a['answer'] == 'not_applicable') {
      if (q['exceptionAllowed'] != true ||
          (code == 'CI034' && installation['accountNumber'] != null)) {
        reason = 'No aplica no admitido por catálogo';
      }
    } else if (a['answer'] == 'not_checked') {
      reason = a['reason'];
      if ((q['deferredReasons'] as List? ?? []).contains(a['pendingReason'])) {
        classification = 'mandatory_test';
      }
    } else {
      reason = a['reason'];
      final impact = object(a['impact']);
      if (q['failure'] == 'assessed' &&
          a['assessment'] == 'minor' &&
          [
            'safety',
            'protection',
            'function',
          ].every((k) => impact[k] == false)) {
        classification = 'minor';
      }
    }
    if (reason != null) {
      result.add({
        'subject': code,
        'classification': classification,
        'reason': reason,
      });
    }
  }
  return result;
}

bool canConfirmBlock(Json q) =>
    q['kind'] == 'check' &&
    ![
      'anchoring',
      'identity',
      'wiring',
      'function',
      'automation',
    ].contains(q['group']) &&
    q['code'] != 'CI016' &&
    (q['deferredReasons'] as List? ?? []).isEmpty;

class CabinetRecord {
  CabinetRecord(this.json);
  final Json json;
  String get id => json['id'] as String;
  Json get working => object(json['working']);
  Json get server => object(json['server']);
  List<Json> get operations => objects(json['operations']);
  List<Json> get pending => operations
      .where((o) => !['done', 'superseded'].contains(o['state']))
      .toList();
  List<Json> get photos => objects(json['photos']);
  bool get synchronized =>
      pending.isEmpty &&
      photos.every((p) => p['verified'] == true) &&
      json['dirty'] != true;
}

const cabinetOperationLabels = {
  'register': 'Crear borrador',
  'registration_close': 'Completar registro',
  'parts_save': 'Guardar piezas',
  'parts_validate': 'Validar piezas',
  'identity_correct': 'Corregir modelo',
  'installation_save': 'Guardar instalación',
  'installation_close': 'Completar instalación',
  'final_review': 'Revisión final',
};
const cabinetSyncLabels = {
  'queued': 'Pendiente',
  'sending': 'Confirmación pendiente',
  'done': 'Confirmado',
  'conflict': 'Requiere resolución',
  'superseded': 'Intento conservado',
};
