import '../../domain/cabinets/cabinet_models.dart';
import 'cabinet_controller.dart';

/// Read-only, deliberately bounded output. Never emits stored error text,
/// response bodies, paths, headers, user identities or arbitrary server codes.
class LegacyOperationDiagnostic {
  LegacyOperationDiagnostic(
    Json operation, {
    required String? actor,
    required int index,
    required List<Json> photos,
  }) {
    final body = object(operation['body']);
    final problem = CabinetController.problemData(operation['problem']);
    final diagnostic = object(operation['diagnostic']);
    const known = {
      'VERSION_CONFLICT',
      'CAUSAL_PHOTO_MISSING',
      'EVIDENCE_NOT_VERIFIED',
      'EVIDENCE_OUT_OF_SCOPE',
      'EVIDENCE_DUPLICATE',
      'INVALID_STATE',
      'CABINET_RESIDENT_REQUIRED',
      'COMPANY_CHANGED',
      'REGISTRATION_REQUIRED',
      'VALIDATION_ERROR',
      'INVALID_PAYLOAD',
      'OPERATION_ID_REUSED',
      'OPERATION_CONFLICT',
      'CATALOG_VERSION_UNSUPPORTED',
    };
    code = known.contains(problem['code'])
        ? '${problem['code']}'
        : problem['code'] == null
        ? 'no conservado'
        : 'no reconocido (conservado en respaldo)';
    responseSignature =
        problem['type'] == 'https://rvs.example/problems/payload-too-large' &&
            problem['status'] == 413
        ? 'Problem Details compatible con Multer API; origen efectivo requiere correlación de logs'
        : 'emisor no verificable con los campos conservados';
    final status = diagnostic['httpStatus'];
    http = status is int && status >= 100 && status <= 599
        ? '$status'
        : 'no conservado';
    final path = diagnostic['path'];
    historicalPhase = path is String && path.endsWith('/photos/verify')
        ? 'verificación fotográfica (antes del comando)'
        : path is String && path.endsWith('/photos')
        ? 'carga fotográfica (antes del comando)'
        : path is String && path.endsWith('/commands')
        ? 'envío del comando'
        : 'no conservada o no reconocida';
    final transport = diagnostic['type'];
    transient =
        (status is int && [408, 429, 500, 502, 503, 504].contains(status)) ||
        [
          'receiveTimeout',
          'sendTimeout',
          'connectionTimeout',
          'connectionError',
        ].contains(transport);
    actorMatches = operation['actor'] == actor && actor != null;
    category = status == 413 || problem['status'] == 413
        ? 'tamaño de solicitud/archivo (413); emisor no verificado'
        : !actorMatches
        ? 'actor distinto'
        : switch (code) {
            'VERSION_CONFLICT' => 'versión',
            'OPERATION_CONFLICT' ||
            'OPERATION_ID_REUSED' => 'idempotencia/actor/payload',
            'CAUSAL_PHOTO_MISSING' ||
            'EVIDENCE_NOT_VERIFIED' ||
            'EVIDENCE_OUT_OF_SCOPE' ||
            'EVIDENCE_DUPLICATE' => 'evidencia',
            'CABINET_RESIDENT_REQUIRED' => 'autorización',
            'COMPANY_CHANGED' => 'empresa',
            'CATALOG_VERSION_UNSUPPORTED' => 'catálogo',
            'VALIDATION_ERROR' || 'INVALID_PAYLOAD' => 'estructura',
            _ =>
              transient
                  ? 'indicio transitorio; no autoriza reintento'
                  : 'no determinado',
          };
    dependency = index == 0
        ? 'expediente y fotos antes del cierre'
        : 'operación anterior confirmada; no enviar fuera de orden';
    final evidence = body['evidence'];
    if (body['type'] == 'registration_close') {
      final issues = <String>[];
      final uuid = RegExp(
        r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$',
      );
      if (!uuid.hasMatch('${body['operationId']}')) issues.add('operationId');
      if (body['expectedVersion'] is! int ||
          (body['expectedVersion'] as int) < 0) {
        issues.add('expectedVersion');
      }
      final captured = body['capturedAt'];
      if (captured is! String ||
          !captured.endsWith('Z') ||
          DateTime.tryParse(captured) == null) {
        issues.add('capturedAt');
      }
      if (body.keys.any(
        (k) => !{
          'operationId',
          'expectedVersion',
          'capturedAt',
          'type',
          'evidence',
        }.contains(k),
      )) {
        issues.add('campos adicionales');
      }
      if (evidence is! List || evidence.isEmpty || evidence.length > 100) {
        issues.add('evidence');
      } else {
        for (final entry in evidence) {
          if (entry is! Map ||
              !uuid.hasMatch('${entry['photoId']}') ||
              entry['confirmed'] != true ||
              (entry.containsKey('legible') && entry['legible'] is! bool) ||
              entry.keys.any(
                (k) => !{'photoId', 'confirmed', 'legible'}.contains(k),
              )) {
            issues.add('descriptor de evidencia');
            break;
          }
        }
      }
      compatibility = issues.isEmpty
          ? 'prevalidación estructural compatible; contrato desplegado no certificado'
          : 'revisar estructura: ${issues.join(', ')}';
      final refs = objects(evidence).map((e) => e['photoId']).toSet();
      final found = photos.where((p) => refs.contains(p['id'])).toList();
      photoSummary =
          '${refs.length} referencias; ${found.length} descriptores locales; '
          '${found.where((p) => object(p['metadata'])['context'] == 'registration').length} con contexto registration. '
          'Integridad de archivos: consultar respaldo; verificación remota no ejecutada.';
    } else {
      compatibility =
          'dependiente del cierre; revisar catálogo y secuencia preparada';
      photoSummary = 'consultar inventario y respaldo del expediente';
    }
  }
  late final String code,
      http,
      category,
      dependency,
      compatibility,
      photoSummary;
  late final bool transient, actorMatches;
  late final String historicalPhase, responseSignature;
  String receipt = 'no consultado';
  String get recommendation => category.startsWith('tamaño')
      ? 'Comparar tamaños y límites API/proxy. No comprimir ni cambiar hashes históricos; no reintentar sin resolver el límite.'
      : !actorMatches
      ? 'Conservar; requiere actor legítimo. No transmitir.'
      : receipt == 'recibo válido pero discrepante con draft/v1'
      ? 'Detener: contrastar estado y recibo. No retransmitir ni aplicar un avance sobre draft/v1.'
      : compatibility.startsWith('revisar estructura')
      ? 'Conservar body original; diseñar continuación actual separada con revisión humana.'
      : category == 'evidencia'
      ? 'Revisar originales, photoId, contexto y hashes antes de proponer carga; no liberar conflicto.'
      : transient
      ? 'Consultar recibo y validar contrato/dependencias antes de proponer reintento idempotente; no liberado.'
      : 'Conservar conflicto; revisar error y recibo antes de decidir. No transmitir.';
  String get summary =>
      'Código histórico: $code · HTTP: $http\n'
      'Tipo: $category\nFirma de respuesta: $responseSignature\nFase histórica: $historicalPhase\nRecibo: $receipt\nDependencia: $dependency\n'
      'Payload: $compatibility\nFotos: $photoSummary\nAcción: $recommendation';
}
