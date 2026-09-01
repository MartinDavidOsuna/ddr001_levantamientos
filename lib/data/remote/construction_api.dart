import 'dart:io';
// ConstructionApi intentionally keeps its compact one-line endpoint methods.
// ignore_for_file: annotate_overrides
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../../core/network/api_client.dart';
import '../../core/security/session_store.dart';
import '../../domain/construction/construction_models.dart';
import '../../core/identity/uuid_identity.dart';

Map<String, dynamic> surveyCreatePayload(BaseSurvey survey) => {
  'surveyId': canonicalUuid(survey.id),
  'displayIdentifier': survey.displayIdentifier,
  'accountNumber': survey.accountNumber,
};

const constructionCausalIdempotencyVersion = 'causal-v1';
const fieldClientApp = 'ddr001_levantamientos';

Map<String, dynamic> fieldSessionStartPayload({
  required String name,
  required String email,
  required String phone,
  required String crew,
  required String installationId,
  required String platform,
  required String manufacturer,
  required String model,
  required String osVersion,
  required String appVersion,
}) => {
  'name': name.trim().replaceAll(RegExp(r'\s+'), ' '),
  'email': email.trim().toLowerCase(),
  'phone': phone.trim(),
  'crew': crew.trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase(),
  'client_app': fieldClientApp,
  'device': {
    'installationId': installationId,
    'platform': platform,
    'manufacturer': manufacturer,
    'model': model,
    'androidVersion': osVersion,
    'appVersion': appVersion,
  },
};

abstract interface class ConstructionRemote {
  Future<FieldSession> fieldLogin({
    required String name,
    required String email,
    required String phone,
    required String crew,
  });
  Future<void> revokeExisting(String takeoverToken);
  Future<ConstructionProfile> profile();
  Future<void> logout(FieldSession session);
  Future<Map<String, dynamic>> createSurvey(BaseSurvey survey);
  Future<void> openStep(String survey, int step);
  Future<void> commentStep(String survey, int step, String? comment);
  Future<void> completeStep(String survey, int step);
  Future<void> upload(ConstructionPhoto photo);
  Future<void> deletePhoto(String surveyId, String photoId);
  Future<Map<String, dynamic>> verify(List<String> ids);
  Future<List<Map<String, dynamic>>> list({
    bool resident,
    String? search,
    String? status,
  });
  Future<Map<String, dynamic>> detail(String surveyId);
  Future<void> residentUpdate(String id, Map<String, dynamic> values);
  Future<void> residentAction(
    String id,
    String action, [
    Map<String, dynamic>? body,
  ]);
  Future<void> correctCanonicalLocation(
    String id,
    GeoPoint point,
    String reason,
  );
  Future<void> correctionComment(
    String surveyId,
    String correctionId,
    String? comment,
  );
  Future<void> completeCorrection(String surveyId, String correctionId);
}

class ConstructionApi implements ConstructionRemote {
  ConstructionApi(this.client, this.sessions, this.packageInfo);
  final ApiClient client;
  final SessionStore sessions;
  final PackageInfo packageInfo;
  Future<FieldSession> fieldLogin({
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
      data: fieldSessionStartPayload(
        name: name,
        email: email,
        phone: phone,
        crew: crew,
        installationId: installation,
        platform: Platform.operatingSystem,
        manufacturer: manufacturer,
        model: model,
        osVersion: os,
        appVersion: '${packageInfo.version}+${packageInfo.buildNumber}',
      ),
      options: Options(extra: {'skipAuth': true}),
    );
    final j = response.data ?? const {};
    final normalizedCrew =
        crew.trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase();
    final value = FieldSession(
      sessionId: canonicalUuid('${j['sessionId']}'),
      userId: canonicalUuid('${j['userId']}'),
      accessToken: '${j['accessToken']}',
      refreshToken: '${j['refreshToken']}',
      installationId: installation,
      name: name.trim(),
      email: email.trim().toLowerCase(),
      phone: phone.trim(),
      crew: normalizedCrew,
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
          (await sessions.read())?.kind == SessionKind.admin
              ? '/construction/admin/profile'
              : '/construction/profile',
        )).data ??
        const {},
  );
  Future<void> logout(FieldSession session) async {
    if (session.kind == SessionKind.admin) {
      await client.dio.post<void>(
        logoutEndpoint(session),
        data: {'refreshToken': session.refreshToken},
      );
    } else {
      await client.dio.post<void>(
        logoutEndpoint(session),
        options: Options(
          headers: {'Idempotency-Key': 'end-${session.sessionId}'},
        ),
      );
    }
    await sessions.clear();
  }

  Future<Map<String, dynamic>> createSurvey(BaseSurvey survey) async =>
      (await client.dio.post<Map<String, dynamic>>(
        '/construction/base-surveys',
        data: surveyCreatePayload(survey),
        options: Options(
          headers: {
            'Idempotency-Key':
                'survey-${survey.id}-$constructionCausalIdempotencyVersion',
          },
        ),
      )).data ??
      const {};
  Future<void> openStep(String survey, int step) => client.dio.post<void>(
    '/construction/base-surveys/${canonicalUuid(survey)}/steps/$step/open',
    options: Options(
      headers: {
        'Idempotency-Key':
            'open-${canonicalUuid(survey)}-$step-$constructionCausalIdempotencyVersion',
      },
    ),
  );
  Future<void> commentStep(String survey, int step, String? comment) =>
      client.dio.patch<void>(
        '/construction/base-surveys/${canonicalUuid(survey)}/steps/$step',
        data: {'comment': comment},
      );
  Future<void> completeStep(String survey, int step) => client.dio.post<void>(
    '/construction/base-surveys/${canonicalUuid(survey)}/steps/$step/complete',
    options: Options(
      headers: {
        'Idempotency-Key':
            'complete-${canonicalUuid(survey)}-$step-$constructionCausalIdempotencyVersion',
      },
    ),
  );
  Future<void> upload(ConstructionPhoto photo) async {
    final location = photo.location!;
    final surveyId = canonicalUuid(photo.surveyId),
        path = photo.correctionId == null
            ? '/construction/base-surveys/$surveyId/steps/${photo.stepNumber}/photos'
            : '/construction/base-surveys/$surveyId/corrections/${canonicalUuid(photo.correctionId!)}/photos';
    final form = FormData.fromMap({
      'photoId': canonicalUuid(photo.id),
      'clientSha256': photo.sha256,
      'capturedAt': photo.capturedAt.toUtc().toIso8601String(),
      'latitude': location.latitude,
      'longitude': location.longitude,
      'accuracy': location.accuracy,
      if (location.altitude != null) 'altitude': location.altitude,
      if (photo.purpose != null) 'photoPurpose': photo.purpose!.name,
      'photo': await MultipartFile.fromFile(
        photo.localPath,
        filename: '${photo.id}.jpg',
        contentType: DioMediaType('image', 'jpeg'),
      ),
    });
    await client.dio.post<void>(
      path,
      data: form,
      options: Options(
        headers: {
          'Idempotency-Key':
              'photo-${photo.id}-$constructionCausalIdempotencyVersion',
        },
      ),
    );
  }

  Future<void> deletePhoto(
    String surveyId,
    String photoId,
  ) => client.dio.delete<void>(
    '/construction/base-surveys/${canonicalUuid(surveyId)}/photos/${canonicalUuid(photoId)}',
    options: Options(
      headers: {
        'Idempotency-Key':
            'delete-photo-${canonicalUuid(photoId)}-$constructionCausalIdempotencyVersion',
      },
    ),
  );

  Future<Map<String, dynamic>> verify(List<String> ids) async =>
      (await client.dio.post<Map<String, dynamic>>(
        '/construction/photos/verify-batch',
        data: {'photoIds': ids.take(100).map(canonicalUuid).toList()},
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
        '/construction/base-surveys/${canonicalUuid(surveyId)}',
      )).data ??
      const {};

  Future<void> residentUpdate(String id, Map<String, dynamic> values) =>
      client.dio.patch<void>(
        '/construction/resident/base-surveys/${canonicalUuid(id)}',
        data: values,
      );
  Future<void> residentAction(
    String id,
    String action, [
    Map<String, dynamic>? body,
  ]) => client.dio.post<void>(
    '/construction/resident/base-surveys/${canonicalUuid(id)}/$action',
    data: body,
    options: Options(headers: {'Idempotency-Key': '$action-$id'}),
  );
  Future<void> correctCanonicalLocation(
    String id,
    GeoPoint point,
    String reason,
  ) => client.dio.post<void>(
    '/construction/resident/base-surveys/${canonicalUuid(id)}/canonical-location',
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
    '/construction/base-surveys/${canonicalUuid(survey)}/corrections/${canonicalUuid(correction)}',
    data: {'comment': comment},
  );
  Future<void> completeCorrection(
    String survey,
    String correction,
  ) => client.dio.post<void>(
    '/construction/base-surveys/${canonicalUuid(survey)}/corrections/${canonicalUuid(correction)}/complete',
    options: Options(
      headers: {
        'Idempotency-Key':
            'correction-${canonicalUuid(correction)}-$constructionCausalIdempotencyVersion',
      },
    ),
  );
}
