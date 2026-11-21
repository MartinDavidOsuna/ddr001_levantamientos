import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../../core/network/api_client.dart';
import '../../domain/cabinets/cabinet_models.dart';

/// Same multipart for upload and read-only size inspection. No HTTP is issued.
Future<FormData> cabinetPhotoMultipart(Json photo) async {
  final path = photo['localPath'] as String;
  if (!await File(path).exists()) {
    throw StateError('Archivo local faltante; conserva el expediente.');
  }
  return FormData.fromMap({
    ...object(photo['metadata']),
    'photo': await MultipartFile.fromFile(
      path,
      filename: '${photo['id']}.jpg',
      contentType: DioMediaType('image', 'jpeg'),
    ),
  });
}

abstract class CabinetRemote {
  Future<Json> deleteCabinet(String id, Json body);
  Future<Json> deletePhoto(String id, String photoId);
  Future<Json> get(String path, [Json? query]);
  Future<Json> command(String id, Json body);
  Future<Json> upload(String id, Json photo);
  Future<Json> verify(String id, List<String> ids);
  Future<Uint8List> content(String id, String photoId, {bool thumbnail = true});
}

class CabinetApi implements CabinetRemote {
  CabinetApi(this.client);
  final ApiClient client;
  String? operationActor;
  Object? recoveryPermit;
  String? recoverySessionId;
  Map<String, dynamic> get _extra => {
    'expectedActor': operationActor,
    if (recoveryPermit != null) 'cabinetRecoveryPermit': recoveryPermit,
    if (recoverySessionId != null) 'expectedSessionId': recoverySessionId,
  };
  static const root = '/construction/cabinets';
  @override
  Future<Json> get(String path, [Json? query]) async => object(
    (await client.dio.get<dynamic>(
      '$root$path',
      queryParameters: query,
      options: Options(extra: _extra),
    )).data,
  );
  @override
  Future<Json> deleteCabinet(String id, Json body) async => object(
    (await client.dio.delete<dynamic>(
      '$root/$id',
      data: body,
      options: Options(
        headers: {'Idempotency-Key': body['operationId']},
        extra: _extra,
      ),
    )).data,
  );
  @override
  Future<Json> deletePhoto(String id, String photoId) async => object(
    (await client.dio.delete<dynamic>(
      '$root/$id/photos/$photoId',
      options: Options(extra: _extra),
    )).data,
  );
  @override
  Future<Json> command(String id, Json body) async => object(
    (await client.dio.post<dynamic>(
      '$root/$id/commands',
      data: body,
      options: Options(
        headers: {'Idempotency-Key': body['operationId']},
        extra: _extra,
      ),
    )).data,
  );
  @override
  Future<Json> upload(String id, Json photo) async {
    return object(
      (await client.dio.post<dynamic>(
        '$root/$id/photos',
        data: await cabinetPhotoMultipart(photo),
        options: Options(extra: _extra),
      )).data,
    );
  }

  @override
  Future<Json> verify(String id, List<String> ids) async => object(
    (await client.dio.post<dynamic>(
      '$root/$id/photos/verify',
      data: {'photoIds': ids},
      options: Options(extra: _extra),
    )).data,
  );
  @override
  Future<Uint8List> content(
    String id,
    String photoId, {
    bool thumbnail = true,
  }) async => Uint8List.fromList(
    (await client.dio.get<List<int>>(
          '$root/$id/photos/$photoId/content',
          queryParameters: {'thumbnail': '$thumbnail'},
          options: Options(responseType: ResponseType.bytes),
        )).data ??
        [],
  );
}
