import '../../domain/cabinets/cabinet_models.dart';

/// Contract check for a single-photo verify response. SQL GUID spelling is
/// case-insensitive; storage certification remains an explicit boolean true.
/// Errors expose only bounded technical states, never raw server content.
void requireLegacyPhotoConfirmation(String photoId, Json response) {
  final uuid = RegExp(r'^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$');
  final items = response['items'];
  if (!uuid.hasMatch(photoId) ||
      items is! List ||
      items.length != 1 ||
      items.single is! Map) {
    throw StateError(
      'PHOTO_VERIFY_RESPONSE_INVALID: respuesta incompleta o ambigua; no se confirmó almacenamiento.',
    );
  }
  final item = object(items.single);
  final receivedId = item['photoId'];
  if (receivedId is! String ||
      !uuid.hasMatch(receivedId) ||
      receivedId.toLowerCase() != photoId.toLowerCase()) {
    throw StateError(
      'PHOTO_VERIFY_ID_MISMATCH: respuesta para otra identidad; no se confirmó almacenamiento.',
    );
  }
  final contradiction = [
    'originalPresent',
    'thumbnailPresent',
    'hashMatches',
  ].any((key) => item.containsKey(key) && item[key] != true);
  if (item['storageVerified'] == true &&
      !contradiction &&
      (!item.containsKey('status') || item['status'] == 'confirmed')) {
    return;
  }
  const known = {
    'confirmed',
    'missing_original',
    'missing_thumbnail',
    'hash_mismatch',
    'missing_mapping',
    'mapping_conflict',
    'deleted',
    'not_verified',
    'not_found',
  };
  final status = known.contains(item['status'])
      ? item['status']
      : 'no informado';
  String flag(String key) =>
      item[key] is bool ? '${item[key]}' : 'no informado';
  throw StateError(
    'PHOTO_STORAGE_UNCONFIRMED: foto ${photoId.substring(0, 8)}; '
    'estado=$status; storageVerified=${flag('storageVerified')}; '
    'original=${flag('originalPresent')}; miniatura=${flag('thumbnailPresent')}; '
    'hash=${flag('hashMatches')}. No se enviaron comandos posteriores a esta comprobación; '
    'conservar la foto recibida y revisar almacenamiento.',
  );
}
