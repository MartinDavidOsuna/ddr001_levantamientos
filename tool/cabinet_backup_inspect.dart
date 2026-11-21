import 'dart:convert';
import 'dart:io';
import 'package:ddr001_levantamientos/recovery/cabinet_backup.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart'
    show cabinetUid;

/// Local-only verifier and SQL reference cross-check. Never transmits commands.
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 3) {
    stderr.writeln(
      'Uso: dart run tool/cabinet_backup_inspect.dart bundle.ddr.jsonl [sql-reference.json o -] [directorio-nuevo-de-extraccion]',
    );
    exitCode = 64;
    return;
  }
  final manifest = await verifyBundle(File(args.first));
  if (args.length == 3) {
    await extractBundle(File(args.first), Directory(args[2]));
  }
  final reference = <String, Map<String, dynamic>>{};
  if (args.length >= 2 && args[1] != '-') {
    final raw = await File(args[1]).readAsBytes();
    rejectSecrets(raw);
    final rows = jsonDecode(utf8.decode(raw));
    if (rows is! List) {
      throw FormatException('Referencia SQL debe ser una lista.');
    }
    for (final value in rows) {
      final row = map(value), uid = cabinetUid('${map(value)['uid']}');
      if (!RegExp(
            r'^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$',
          ).hasMatch('${row['cabinetId']}') ||
          row['version'] is! int ||
          reference.containsKey(uid)) {
        throw FormatException(
          'Referencia ambigua/inválida. No se genera identidad.',
        );
      }
      reference[uid] = row;
    }
  }
  final rows = maps(manifest['inventory']).map((row) {
    final remote = reference[cabinetUid('${row['uid']}')];
    return {
      ...row,
      'sqlReference': remote == null
          ? 'NO VERIFICADA'
          : {
              'sameCabinetId':
                  '${remote['cabinetId']}'.toLowerCase() ==
                  '${row['cabinetId']}'.toLowerCase(),
              'status': remote['status'],
              'version': remote['version'],
            },
      'recoveryAuthorized': false,
      'requiredOrder': [
        'identity/version',
        'evidence',
        'registration_close',
        'parts_save',
        'parts_validate',
      ],
    };
  }).toList();
  // Output is a private technical inventory, not a public report.
  stdout.writeln(
    jsonEncode({
      'complete': manifest['complete'],
      'issues': manifest['issues'],
      'inventory': rows,
      'sqlReferenceOnly': true,
      'networkWrites': 0,
    }),
  );
}
