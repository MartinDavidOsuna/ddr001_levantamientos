import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../../domain/cabinets/cabinet_models.dart';
import 'cabinet_controller.dart';
import 'cabinet_legacy_scope.dart';
import 'legacy_cabinet_recovery.dart';

class HistoricalBatchIssue implements Exception {
  const HistoricalBatchIssue(this.code, this.message, {this.global = false});
  final String code, message;
  final bool global;
}

typedef HistoricalExecutor = Future<bool> Function(String id, Object permit);

/// Only HomePage's explicit sync gesture invokes this coordinator. No timers.
class LegacyAutomaticSync {
  LegacyAutomaticSync(
    this.controller, {
    this.executor,
    this.ordinaryWaitTimeout = const Duration(seconds: 8),
  }) {
    if (controller.actor == null) return;
    final key = controller.store.box.get('legacy_auto_last_v1');
    final raw = key == null ? null : controller.store.box.get(key);
    if (raw is String) {
      try {
        result = object(jsonDecode(raw));
        if (result?['owner'] != controller.actor) {
          result = null;
          return;
        }
        if (result?['status'] == 'running') {
          result!['status'] = 'interrupted';
          result!['globalMessage'] =
              'Ejecución interrumpida. Sincronizar volverá a consultar los recibos antes de continuar.';
        }
      } catch (_) {
        /* A corrupt summary never authorizes transmission. */
      }
    }
  }
  static final _instances = Expando<LegacyAutomaticSync>();
  static LegacyAutomaticSync forController(CabinetController c) =>
      _instances[c] ??= LegacyAutomaticSync(c);
  final CabinetController controller;
  final HistoricalExecutor? executor;
  final Duration ordinaryWaitTimeout;
  bool get hasVisibleResult =>
      result != null && result!['owner'] == controller.actor;
  bool busy = false;
  Json? result;
  String? _runKey;

  static HistoricalBatchIssue classify(Object error) {
    if (error is HistoricalBatchIssue) return error;
    if (error is DioException) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) {
        return const HistoricalBatchIssue(
          'AUTHENTICATION',
          'La sesión requiere atención. No se enviaron más expedientes.',
          global: true,
        );
      }
      if (status == null || status == 408 || status == 429 || status >= 500) {
        return const HistoricalBatchIssue(
          'SERVICE_UNAVAILABLE',
          'Conexión o servicio no disponible. Vuelve a sincronizar cuando se restablezca.',
          global: true,
        );
      }
      return HistoricalBatchIssue(
        'HTTP_$status',
        'El servidor no pudo confirmar este expediente. Datos conservados.',
      );
    }
    if (error is FileSystemException &&
        [28, 112].contains(error.osError?.errorCode)) {
      return const HistoricalBatchIssue(
        'STORAGE_FULL',
        'No hay espacio suficiente para preservar los datos.',
        global: true,
      );
    }
    final text = error is StateError ? error.message : '';
    const causes = <String, String>{
      'SUPPORT_SESSION_CHANGED':
          'La sesión cambió; vuelve a iniciar con la sesión legítima antes de intentar otra vez.',
      'SUPPORT_ROLE_DENIED':
          'La sesión no tiene autorización vigente de residente para recuperar.',
      'SUPPORT_CONTROLLER_BUSY':
          'El controlador de Gabinetes sigue ocupado. No se forzó ni interrumpió su trabajo.',
      'SUPPORT_HTTP_IN_FLIGHT':
          'Hay una solicitud HTTP de Gabinetes en curso. Espera su finalización.',
      'SUPPORT_MEDIA_BUSY':
          'El sistema de fotografías tiene una operación durable en curso.',
      'SUPPORT_LOCK_OWNED':
          'Otra preparación mantiene el lock de soporte. No se liberó su acceso.',
      'SUPPORT_HTTP_LOCK_OWNED':
          'Otra operación conserva el lock HTTP de soporte.',
      'SUPPORT_MEDIA_LOCK_OWNED':
          'Otro respaldo conserva el lock del broker fotográfico.',
      'SUPPORT_LOCK_LOST':
          'El permiso de soporte ya no pertenece a esta ejecución.',
      'SUPPORT_SCOPE_DENIED':
          'La selección no pertenece al alcance autorizado.',
      'SUPPORT_ORDINARY_BUSY':
          'La sincronización ordinaria todavía no terminó. La recuperación no comenzó.',
      'AUTO_BATCH_UNAVAILABLE':
          'No se pudo reservar el lote con la autorización y versión actuales.',
      'AUTO_BATCH_LOCK_OWNED':
          'Ya existe otro lote activo. Espera a que finalice.',
      'AUTO_BATCH_OWNER_MISMATCH':
          'El lote pertenece a otra ejecución; no se liberó su reserva.',
      'AUTO_BATCH_PERMIT_REQUIRED':
          'Esta ejecución no tiene un permiso de lote vigente.',
    };
    final code = text.split(':').first;
    if (causes.containsKey(code)) {
      return HistoricalBatchIssue(code, causes[code]!, global: true);
    }
    if (text.contains('Sesión o selección cambió')) {
      return const HistoricalBatchIssue(
        'SUPPORT_LEGACY_AMBIGUOUS',
        'El diagnóstico anterior no distingue sesión de permiso. Los datos se conservaron.',
        global: true,
      );
    }
    if (text.startsWith('SUPPORT_ACTOR') ||
        text.contains('residente original') ||
        text.contains('otro actor')) {
      return const HistoricalBatchIssue(
        'ACTOR_MISMATCH',
        'El expediente pertenece a otro residente. Datos conservados.',
      );
    }
    if (error is FileSystemException ||
        text.contains('HASH') ||
        text.contains('PHOTO') ||
        text.contains('DERIVATIVE') ||
        text.contains('respaldo')) {
      return const HistoricalBatchIssue(
        'EVIDENCE_OR_BACKUP',
        'No se pudo certificar el respaldo o las fotografías. Datos conservados.',
      );
    }
    if (text.contains('CHECKLIST') ||
        text.contains('Checklist') ||
        text.contains('checklist')) {
      return const HistoricalBatchIssue(
        'CHECKLIST',
        'El checklist original requiere revisión. Datos conservados.',
      );
    }
    if (error is! StateError) {
      return const HistoricalBatchIssue(
        'UNEXPECTED_EXCEPTION',
        'Ocurrió un error no identificado. No se iniciaron más transmisiones.',
        global: true,
      );
    }
    return const HistoricalBatchIssue(
      'DOSSIER_INCOMPATIBLE',
      'El expediente requiere revisión de soporte. Datos conservados.',
    );
  }

  Future<void> _persist() async {
    try {
      await controller.store.box.put(_runKey!, jsonEncode(result));
      await controller.store.box.put('legacy_auto_last_v1', _runKey!);
      await controller.store.box.flush();
    } catch (_) {
      throw const HistoricalBatchIssue(
        'JOURNAL_UNAVAILABLE',
        'No se pudo guardar el avance de forma segura.',
        global: true,
      );
    }
    controller.notifyHistoricalProgress();
  }

  Future<bool> _recover(String id, Object permit) async {
    final recovery = LegacyCabinetRecovery(
      controller,
      id,
      cabinetAllowlist: {id},
      automaticBatchPermit: permit,
    );
    final row = (result!['rows'] as List).cast<Json>().singleWhere(
      (r) => r['uid'] == controller.store.read(id)!.working['uid'],
    );
    try {
      row['phase'] = 'preparation';
      await _persist();
      await recovery.prepare(prepareDerivatives: true);
      if (!recovery.canExecute) {
        throw StateError(recovery.blockers.join('; '));
      }
      final already =
          recovery.server?['status'] == 'validated' &&
          recovery.confirmedVersions.length == recovery.sequence.length;
      row['phase'] = 'receipt_reconciliation_and_execution';
      result!['phase'] = 'historical_execution';
      await _persist();
      await recovery.execute(
        operationAllowlist: recovery.operationAllowlist,
        explicitlyConfirmed: true,
      );
      if (!recovery.completed) throw StateError('LEGACY_RESULT_UNCONFIRMED');
      return already;
    } catch (e) {
      row['failureCode'] = classify(e).code;
      rethrow;
    } finally {
      try {
        await recovery.close();
      } catch (e) {
        final issue = classify(e);
        row['phase'] = 'support_release';
        throw HistoricalBatchIssue(
          issue.code,
          'No se pudo cerrar el soporte: ${issue.message}',
          global: true,
        );
      }
    }
  }

  Future<void> runFromHome(Future<void> Function() ordinary) async {
    if (busy) return;
    busy = true;
    _runKey = null;
    controller.notifyHistoricalProgress();
    Object? permit;
    final actor = controller.actor, session = controller.app.session?.sessionId;
    void sessionCheck() {
      if (actor != controller.actor ||
          session != controller.app.session?.sessionId) {
        throw const HistoricalBatchIssue(
          'SESSION_CHANGED',
          'La sesión cambió. No se iniciaron más transmisiones.',
          global: true,
        );
      }
      if (!controller.allowed) {
        throw StateError('SUPPORT_ROLE_DENIED');
      }
    }

    try {
      if (!controller.automaticHistoricalAvailable) {
        await ordinary();
        return;
      }
      final rows = [
        for (final uid in legacyAutomaticUids)
          <String, dynamic>{
            'uid': uid,
            'status': 'not_processed',
            'message': 'No procesado',
          },
      ];
      _runKey = 'legacy_auto_runs_v1:${const Uuid().v4()}';
      result = {
        'owner': actor,
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'status': 'running',
        'phase': 'batch_reservation',
        'rows': rows,
      };
      await _persist();
      permit = controller.beginAutomaticHistoricalBatch();
      result!['phase'] = 'ordinary_sync';
      await _persist();
      await ordinary();
      result!['phase'] = 'ordinary_drain';
      await _persist();
      final wait = Stopwatch()..start();
      while (controller.app.syncing) {
        sessionCheck();
        if (wait.elapsed >= ordinaryWaitTimeout) {
          throw StateError('SUPPORT_ORDINARY_BUSY');
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      sessionCheck();
      result!['phase'] = 'historical_preparation';
      if (!controller.app.online) {
        throw const HistoricalBatchIssue(
          'OFFLINE',
          'Sin conexión. Datos conservados.',
          global: true,
        );
      }
      for (final row in rows) {
        sessionCheck();
        final uid = cabinetUid('${row['uid']}');
        if (!legacyAutomaticUids.contains(uid) || uid == legacyPilotUid) {
          throw StateError('AUTO_BATCH_SCOPE');
        }
        row['status'] = 'processing';
        row['message'] = 'Comprobando expediente';
        await _persist();
        try {
          final matches = controller.store
              .all()
              .where((r) => r.working['uid'] == uid)
              .toList();
          if (matches.length != 1) {
            throw const HistoricalBatchIssue(
              'LOCAL_IDENTITY',
              'No se encontró un único expediente original en este teléfono.',
            );
          }
          final record = matches.single;
          if (record.json['actor'] != actor ||
              (record.json['draftActor'] != null &&
                  record.json['draftActor'] != actor)) {
            throw const HistoricalBatchIssue(
              'ACTOR_MISMATCH',
              'El expediente pertenece a otro residente. Datos conservados.',
            );
          }
          final already = await (executor ?? _recover)(record.id, permit);
          sessionCheck();
          row['status'] = already ? 'already_complete' : 'recovered';
          row['message'] = already
              ? 'Ya recuperado; comprobado sin reenviar comandos'
              : 'Recuperado y confirmado';
        } catch (e) {
          final issue = classify(e);
          row['status'] = 'blocked';
          row['code'] = issue.code;
          row['message'] = issue.message;
          if (issue.global) rethrow;
        }
        await _persist();
      }
      result!['status'] = rows.any((r) => r['status'] == 'blocked')
          ? 'partial'
          : 'complete';
    } catch (e) {
      if (result != null && _runKey != null) {
        final issue = classify(e);
        result!['status'] = 'stopped';
        result!['globalCode'] = issue.code;
        result!['globalMessage'] = issue.message;
        result!['diagnosticCode'] = issue.code;
        for (final row in (result!['rows'] as List)) {
          if (row['status'] == 'processing') {
            row['status'] = 'blocked';
            row['message'] = issue.message;
            row['code'] = issue.code;
          }
        }
      }
    } finally {
      if (result != null && _runKey != null) {
        result!['endedAt'] = DateTime.now().toUtc().toIso8601String();
        try {
          await _persist();
        } catch (_) {
          result!['status'] = 'stopped';
          result!['globalMessage'] =
              'No se pudo guardar el resumen. Los recibos del expediente se conservan.';
        }
      }
      try {
        if (permit != null) controller.endAutomaticHistoricalBatch(permit);
      } catch (e) {
        final issue = classify(e);
        if (result != null && _runKey != null) {
          result!['status'] = 'stopped';
          result!['phase'] = 'batch_release';
          result!['globalCode'] = issue.code;
          result!['globalMessage'] = issue.message;
          try {
            await _persist();
          } catch (_) {
            /* Keep the failure visible in memory. */
          }
        }
      } finally {
        busy = false;
        controller.notifyHistoricalProgress();
      }
    }
  }

  String get summary {
    final rows = objects(result?['rows']);
    int count(String state) => rows.where((r) => r['status'] == state).length;
    final complete = result?['status'] == 'complete';
    final notStarted =
        !busy &&
        result?['status'] == 'stopped' &&
        result?['phase'] != 'historical_execution' &&
        rows.every(
          (r) => !['recovered', 'already_complete'].contains(r['status']),
        );
    return '${complete
            ? 'Sincronización terminada'
            : busy
            ? 'Sincronización en curso'
            : notStarted
            ? 'Recuperación histórica no iniciada'
            : 'Sincronización con pendientes'}\n'
        'Históricos procesados: ${rows.where((r) => !['not_processed', 'processing'].contains(r['status'])).length} de 10\n'
        'Recuperados: ${count('recovered')} · Ya recuperados: ${count('already_complete')}\n'
        'Pendientes por error: ${count('blocked')} · No procesados: ${count('not_processed')}\n'
        'Gabinetes pendientes: ${rows.where((r) => !['recovered', 'already_complete'].contains(r['status'])).length}\n'
        '${result?['globalMessage'] ?? ''}\n'
        '${result?['globalCode'] ?? ''}\n'
        'Resultado guardado: ${result?['startedAt'] ?? ''}';
  }
}
