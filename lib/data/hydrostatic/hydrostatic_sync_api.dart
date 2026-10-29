import 'package:dio/dio.dart';
import '../../core/network/api_client.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';

class HydrostaticSyncIdentity {
  const HydrostaticSyncIdentity(
    this.actorId,
    this.sessionId,
    this.installationId,
  );
  final String actorId, sessionId, installationId;
  String get key => '$actorId:$sessionId:$installationId';
}

class HydrostaticSyncFailure implements Exception {
  const HydrostaticSyncFailure(this.status, this.code);
  final int? status;
  final String code;
  @override
  String toString() => code;
}

abstract interface class HydrostaticSyncRemote {
  Future<HydroJson> capabilities(HydrostaticSyncIdentity identity);
  Future<HydroJson> command(
    String id,
    HydroJson command,
    HydrostaticSyncIdentity identity,
  );
  Future<HydroJson> receipt(
    String id,
    String operationId,
    HydrostaticSyncIdentity identity,
  );
  Future<HydroJson> status(
    String id,
    int revision,
    HydrostaticSyncIdentity identity,
  );
}

/// HAPI-2 only. No media transfer or fabricated reconciliation endpoint.
class HydrostaticSyncApi implements HydrostaticSyncRemote {
  HydrostaticSyncApi(this.client);
  final ApiClient client;
  static const root = '/construction/hydrostatic-tests';
  Options _options(HydrostaticSyncIdentity s, [HydroJson? command]) => Options(
    extra: {
      'expectedActor': s.actorId,
      'expectedSessionId': s.sessionId,
      'expectedInstallationId': s.installationId,
    },
    headers: command == null
        ? null
        : {
            'Idempotency-Key': command['operationId'],
            'If-Match': '"hydrostatic-${command['expectedVersion']}"',
          },
  );
  Future<HydroJson> _request(
    Future<Response<dynamic>> Function() action,
  ) async {
    try {
      final r = await action();
      if (r.data is! Map) {
        throw const HydrostaticSyncFailure(null, 'INVALID_RESPONSE');
      }
      return hydroObject(r.data);
    } on DioException catch (e) {
      final data = e.response?.data;
      // Never persist raw response bodies, URLs, tokens or error messages.
      final code = data is Map ? data['code'] : null;
      throw HydrostaticSyncFailure(
        e.response?.statusCode,
        code is String && RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(code)
            ? code
            : 'CONNECTION_OR_SESSION',
      );
    }
  }

  @override
  Future<HydroJson> capabilities(HydrostaticSyncIdentity s) => _request(
    () => client.dio.get('$root/capabilities', options: _options(s)),
  );
  @override
  Future<HydroJson> command(
    String id,
    HydroJson command,
    HydrostaticSyncIdentity s,
  ) => _request(
    () => client.dio.post(
      '$root/$id/commands',
      data: command,
      options: _options(s, command),
    ),
  );
  @override
  Future<HydroJson> receipt(String id, String op, HydrostaticSyncIdentity s) =>
      _request(
        () => client.dio.get('$root/$id/operations/$op', options: _options(s)),
      );
  @override
  Future<HydroJson> status(
    String id,
    int revision,
    HydrostaticSyncIdentity s,
  ) => _request(
    () => client.dio.get(
      '$root/$id/sync-status',
      queryParameters: {'sourceRevision': revision},
      options: _options(s),
    ),
  );
}
