import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../core/network/api_client.dart';
import '../../core/security/session_store.dart';
import '../../domain/construction/construction_models.dart';

class ConstructionApi {
  ConstructionApi(this.client, this.sessions, this.packageInfo);
  final ApiClient client;
  final SessionStore sessions;
  final PackageInfo packageInfo;
  Future<FieldSession> login({
    required String name,
    required String email,
    required String phone,
    required String crew,
  }) async {
    final installation = await sessions.installationId();
    var manufacturer = 'Apple',
        model = 'unknown',
        os = Platform.operatingSystemVersion;
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      manufacturer = info.manufacturer;
      model = info.model;
      os = info.version.release;
    }
    if (Platform.isIOS) {
      final info = await DeviceInfoPlugin().iosInfo;
      model = info.utsname.machine;
      os = info.systemVersion;
    }
    final response = await client.dio.post<Map<String, dynamic>>(
      '/field-sessions/start',
      data: {
        'name': name.trim().replaceAll(RegExp(r'\s+'), ' '),
        'email': email.trim().toLowerCase(),
        'phone': phone.trim(),
        'crew': crew.trim().toUpperCase(),
        'device': {
          'installationId': installation,
          'platform': Platform.operatingSystem,
          'manufacturer': manufacturer,
          'model': model,
          'androidVersion': os,
          'appVersion': '${packageInfo.version}+${packageInfo.buildNumber}',
        },
      },
      options: Options(extra: {'skipAuth': true}),
    );
    final j = response.data ?? const {};
    final value = FieldSession(
      sessionId: '${j['sessionId']}',
      userId: '${j['userId']}',
      accessToken: '${j['accessToken']}',
      refreshToken: '${j['refreshToken']}',
      installationId: installation,
      name: name.trim(),
      email: email.trim().toLowerCase(),
      phone: phone.trim(),
      crew: crew.trim().toUpperCase(),
    );
    await sessions.save(value);
    return value;
  }

  Future<void> revokeExisting(String takeoverToken) => client.dio.post<void>(
    '/field-sessions/revoke-existing',
    data: {'takeoverToken': takeoverToken},
    options: Options(extra: {'skipAuth': true}),
  );

  Future<ConstructionProfile> profile() async => ConstructionProfile.fromJson(
    (await client.dio.get<Map<String, dynamic>>(
          '/construction/profile',
        )).data ??
        const {},
  );
  Future<void> logout(FieldSession session) async {
    try {
      await client.dio.post<void>(
        '/field-sessions/${session.sessionId}/end',
        options: Options(
          headers: {'Idempotency-Key': 'end-${session.sessionId}'},
        ),
      );
    } finally {
      await sessions.clear();
    }
  }

  Future<Map<String, dynamic>> createSurvey(BaseSurvey survey) async =>
      (await client.dio.post<Map<String, dynamic>>(
        '/construction/base-surveys',
        data: {
          'surveyId': survey.id,
          'displayIdentifier': survey.displayIdentifier,
          'accountNumber': survey.accountNumber,
        },
        options: Options(headers: {'Idempotency-Key': 'survey-${survey.id}'}),
      )).data ??
      const {};
  Future<void> openStep(String survey, int step) => client.dio.post<void>(
    '/construction/base-surveys/$survey/steps/$step/open',
    options: Options(headers: {'Idempotency-Key': 'open-$survey-$step'}),
  );
  Future<void> commentStep(String survey, int step, String? comment) =>
      client.dio.patch<void>(
        '/construction/base-surveys/$survey/steps/$step',
        data: {'comment': comment},
      );
  Future<void> completeStep(String survey, int step) => client.dio.post<void>(
    '/construction/base-surveys/$survey/steps/$step/complete',
    options: Options(headers: {'Idempotency-Key': 'complete-$survey-$step'}),
  );
  Future<void> upload(ConstructionPhoto photo) async {
    final location = photo.location!;
    final path = photo.correctionId == null
        ? '/construction/base-surveys/${photo.surveyId}/steps/${photo.stepNumber}/photos'
        : '/construction/base-surveys/${photo.surveyId}/corrections/${photo.correctionId}/photos';
    final form = FormData.fromMap({
      'photoId': photo.id,
      'clientSha256': photo.sha256,
      'capturedAt': photo.capturedAt.toUtc().toIso8601String(),
      'latitude': location.latitude,
      'longitude': location.longitude,
      'accuracy': location.accuracy,
      if (location.altitude != null) 'altitude': location.altitude,
      'photo': await MultipartFile.fromFile(
        photo.localPath,
        filename: '${photo.id}.jpg',
        contentType: DioMediaType('image', 'jpeg'),
      ),
    });
    await client.dio.post<void>(
      path,
      data: form,
      options: Options(headers: {'Idempotency-Key': 'photo-${photo.id}'}),
    );
  }

  Future<Map<String, dynamic>> verify(List<String> ids) async =>
      (await client.dio.post<Map<String, dynamic>>(
        '/construction/photos/verify-batch',
        data: {'photoIds': ids.take(100).toList()},
      )).data ??
      const {};
  Future<List<Map<String, dynamic>>> list({
    bool resident = false,
    String? search,
    String? status,
  }) async {
    final path = resident
        ? '/construction/resident/base-surveys'
        : '/construction/base-surveys';
    final data =
        (await client.dio.get<Map<String, dynamic>>(
          path,
          queryParameters: {
            if (search?.isNotEmpty == true) 'search': search,
            'status': ?status,
            'pageSize': 100,
          },
        )).data ??
        const {};
    return (data['items'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<List<Map<String, dynamic>>> mapPoints({required bool resident}) async {
    final data =
        (await client.dio.get<Map<String, dynamic>>(
          resident
              ? '/construction/resident/map'
              : '/construction/base-surveys/map',
        )).data ??
        const {};
    return (data['items'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<Map<String, dynamic>> detail(String surveyId) async =>
      (await client.dio.get<Map<String, dynamic>>(
        '/construction/base-surveys/$surveyId',
      )).data ??
      const {};

  Future<void> residentUpdate(String id, Map<String, dynamic> values) => client
      .dio
      .patch<void>('/construction/resident/base-surveys/$id', data: values);
  Future<void> residentAction(
    String id,
    String action, [
    Map<String, dynamic>? body,
  ]) => client.dio.post<void>(
    '/construction/resident/base-surveys/$id/$action',
    data: body,
    options: Options(headers: {'Idempotency-Key': '$action-$id'}),
  );
  Future<void> correctCanonicalLocation(
    String id,
    GeoPoint point,
    String reason,
  ) => client.dio.post<void>(
    '/construction/resident/base-surveys/$id/canonical-location',
    data: {
      'latitude': point.latitude,
      'longitude': point.longitude,
      'accuracy': point.accuracy,
      'altitude': point.altitude,
      'reason': reason,
    },
  );
  Future<void> correctionComment(
    String survey,
    String correction,
    String? comment,
  ) => client.dio.patch<void>(
    '/construction/base-surveys/$survey/corrections/$correction',
    data: {'comment': comment},
  );
  Future<void> completeCorrection(String survey, String correction) =>
      client.dio.post<void>(
        '/construction/base-surveys/$survey/corrections/$correction/complete',
        options: Options(
          headers: {'Idempotency-Key': 'correction-$correction'},
        ),
      );
}
