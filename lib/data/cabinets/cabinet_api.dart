import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import '../../core/network/api_client.dart';
import '../../domain/cabinets/cabinet_models.dart';

abstract class CabinetRemote {
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
  static const root = '/construction/cabinets';
  @override
  Future<Json> get(String path, [Json? query]) async => object(
    (await client.dio.get<dynamic>('$root$path', queryParameters: query)).data,
  );
  @override
  Future<Json> command(String id, Json body) async => object(
    (await client.dio.post<dynamic>(
      '$root/$id/commands',
      data: body,
      options: Options(
        headers: {'Idempotency-Key': body['operationId']},
        extra: {'expectedActor': operationActor},
      ),
    )).data,
  );
  @override
  Future<Json> upload(String id, Json photo) async {
    final path = photo['localPath'] as String;
    if (!await File(path).exists()) {
      throw StateError(
        'Archivo local faltante. Conserva el expediente y recupera el archivo original.',
      );
    }
    return object(
      (await client.dio.post<dynamic>(
        '$root/$id/photos',
        data: FormData.fromMap({
          ...object(photo['metadata']),
          'photo': await MultipartFile.fromFile(
            path,
            filename: '${photo['id']}.jpg',
            contentType: DioMediaType('image', 'jpeg'),
          ),
        }),
        options: Options(extra: {'expectedActor': operationActor}),
      )).data,
    );
  }

  @override
  Future<Json> verify(String id, List<String> ids) async => object(
    (await client.dio.post<dynamic>(
      '$root/$id/photos/verify',
      data: {'photoIds': ids},
      options: Options(extra: {'expectedActor': operationActor}),
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
