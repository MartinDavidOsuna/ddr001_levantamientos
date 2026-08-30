import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import '../../domain/construction/construction_models.dart';
import '../identity/uuid_identity.dart';

class UuidHiveMigration {
  const UuidHiveMigration();
  static const marker = 'uuidCanonicalizationV2';

  Future<void> run({
    required Box<String> surveysBox,
    required Box<String> photosBox,
    required Box<String> queueBox,
    required Box<String> metadataBox,
  }) async {
    if (metadataBox.get(marker) == 'complete') return;
    final queue = queueBox.toMap().values.map(_queue).toList();
    final pendingSurveys = queue.map((item) => item.surveyId).toSet();
    await _migratePhotos(photosBox);
    await _migrateSurveys(surveysBox, pendingSurveys);
    await _migrateQueue(queueBox);
    await metadataBox.put(marker, 'complete');
  }

  Future<void> _migratePhotos(Box<String> box) async {
    final source = box.toMap(), grouped = <String, List<ConstructionPhoto>>{};
    for (final value in source.values) {
      final photo = _photo(value);
      grouped.putIfAbsent(photo.id, () => []).add(photo);
    }
    for (final entry in grouped.entries) {
      final merged = mergeDuplicatePhotos(entry.value);
      await box.put(entry.key, jsonEncode(merged.toJson()));
      _validateCanonical(box.get(entry.key), entry.key, _photo);
      await _removeDuplicateKeys(box, source.keys, entry.key);
    }
  }

  Future<void> _migrateSurveys(
    Box<String> box,
    Set<String> pendingSurveys,
  ) async {
    final source = box.toMap(), grouped = <String, List<BaseSurvey>>{};
    for (final value in source.values) {
      final survey = _survey(value);
      grouped.putIfAbsent(survey.id, () => []).add(survey);
    }
    for (final entry in grouped.entries) {
      if (entry.value.length > 1 && kDebugMode) {
        debugPrint('[UUID MIGRATION] duplicate pair detected ${entry.key}');
      }
      final merged = mergeDuplicateSurveys(
        entry.value,
        hasPendingOperations: pendingSurveys.contains(entry.key),
      );
      await box.put(entry.key, jsonEncode(merged.toJson()));
      _validateCanonical(box.get(entry.key), entry.key, _survey);
      await _removeDuplicateKeys(box, source.keys, entry.key);
      if (entry.value.length > 1 && kDebugMode) {
        debugPrint('[UUID MIGRATION] merge completed ${entry.key}');
      }
    }
  }

  Future<void> _migrateQueue(Box<String> box) async {
    final source = box.toMap(), merged = <String, SyncQueueItem>{};
    for (final value in source.values) {
      final item = _queue(value), key = canonicalQueueItemId(item);
      final normalized = SyncQueueItem(
        id: key,
        surveyId: item.surveyId,
        operation: item.operation,
        photoId: item.photoId,
        step: item.step,
        correctionId: item.correctionId,
        attempts: item.attempts,
        createdAt: item.createdAt,
        nextAttemptAt: item.nextAttemptAt,
        requiresReview: item.requiresReview,
        lastErrorCode: item.lastErrorCode,
      );
      final current = merged[key];
      merged[key] = current == null
          ? normalized
          : mergeQueueItems(current, normalized);
    }
    for (final entry in merged.entries) {
      await box.put(entry.key, jsonEncode(entry.value.toJson()));
      _validateCanonical(box.get(entry.key), entry.key, _queue);
    }
    for (final key in source.keys) {
      if (!merged.containsKey('$key')) await box.delete(key);
    }
  }

  Future<void> _removeDuplicateKeys(
    Box<String> box,
    Iterable<dynamic> sourceKeys,
    String canonicalKey,
  ) async {
    for (final key in sourceKeys) {
      if ('$key' != canonicalKey && canonicalUuid('$key') == canonicalKey) {
        await box.delete(key);
        if (kDebugMode) {
          debugPrint('[UUID MIGRATION] duplicate key removed $canonicalKey');
        }
      }
    }
  }

  void _validateCanonical<T>(
    String? raw,
    String expected,
    T Function(String) decode,
  ) {
    if (raw == null) {
      throw StateError('UUID migration canonical write missing.');
    }
    final value = decode(raw);
    final id = switch (value) {
      BaseSurvey survey => survey.id,
      ConstructionPhoto photo => photo.id,
      SyncQueueItem item => item.id,
      _ => '',
    };
    if (id != expected) throw StateError('UUID migration validation failed.');
  }

  BaseSurvey _survey(String raw) =>
      BaseSurvey.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
  ConstructionPhoto _photo(String raw) => ConstructionPhoto.fromJson(
    Map<String, dynamic>.from(jsonDecode(raw) as Map),
  );
  SyncQueueItem _queue(String raw) =>
      SyncQueueItem.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
}

String canonicalQueueItemId(SyncQueueItem item) =>
    '${canonicalUuid(item.surveyId)}-${item.operation.name}-'
    '${canonicalUuidOrNull(item.photoId) ?? item.step ?? canonicalUuidOrNull(item.correctionId) ?? ''}';

SyncQueueItem mergeQueueItems(SyncQueueItem left, SyncQueueItem right) =>
    SyncQueueItem(
      id: left.id,
      surveyId: left.surveyId,
      operation: left.operation,
      photoId: left.photoId,
      step: left.step,
      correctionId: left.correctionId,
      attempts: left.attempts > right.attempts ? left.attempts : right.attempts,
      createdAt: left.createdAt.isBefore(right.createdAt)
          ? left.createdAt
          : right.createdAt,
      nextAttemptAt: _latest(left.nextAttemptAt, right.nextAttemptAt),
      requiresReview: left.requiresReview || right.requiresReview,
      lastErrorCode: right.lastErrorCode ?? left.lastErrorCode,
    );

DateTime? _latest(DateTime? left, DateTime? right) {
  if (left == null) return right;
  if (right == null) return left;
  return left.isAfter(right) ? left : right;
}

ConstructionPhoto mergeDuplicatePhotos(List<ConstructionPhoto> values) {
  var local = values.first;
  for (final candidate in values.skip(1)) {
    final candidateExists = File(candidate.localPath).existsSync();
    final localExists = File(local.localPath).existsSync();
    if ((candidateExists && !localExists) ||
        (candidate.thumbnailPath.isNotEmpty && local.thumbnailPath.isEmpty)) {
      local = candidate;
    }
  }
  final strongest = [...values]
    ..sort(
      (a, b) =>
          _photoStateRank(b.syncState).compareTo(_photoStateRank(a.syncState)),
    );
  final state = strongest.first.syncState;
  final located = values.where((photo) => photo.location != null).firstOrNull;
  return ConstructionPhoto(
    id: canonicalUuid(local.id),
    surveyId: canonicalUuid(local.surveyId),
    localPath: local.localPath,
    thumbnailPath: local.thumbnailPath,
    sha256: local.sha256,
    capturedAt: local.capturedAt,
    stepNumber: local.stepNumber,
    correctionId: canonicalUuidOrNull(local.correctionId),
    location: located?.location ?? local.location,
    purpose: local.purpose,
    syncState: state,
    locationState: located?.locationState ?? local.locationState,
    locationFixAt: located?.locationFixAt ?? local.locationFixAt,
    locationAcquiredAt: located?.locationAcquiredAt ?? local.locationAcquiredAt,
    locationAltitudeAccuracy:
        located?.locationAltitudeAccuracy ?? local.locationAltitudeAccuracy,
    locationHeading: located?.locationHeading ?? local.locationHeading,
    locationSpeed: located?.locationSpeed ?? local.locationSpeed,
    locationSource: located?.locationSource ?? local.locationSource,
    locationTemporalDeltaMs:
        located?.locationTemporalDeltaMs ?? local.locationTemporalDeltaMs,
    locationConfidence: located?.locationConfidence ?? local.locationConfidence,
    locationDistanceToCanonical:
        located?.locationDistanceToCanonical ??
        local.locationDistanceToCanonical,
    locationConsistency:
        located?.locationConsistency ?? local.locationConsistency,
    locationIntegrityFlag:
        located?.locationIntegrityFlag ?? local.locationIntegrityFlag,
  );
}

int _photoStateRank(PhotoSyncState state) => switch (state) {
  PhotoSyncState.confirmed => 10,
  PhotoSyncState.verifying => 9,
  PhotoSyncState.uploadedUnverified => 8,
  PhotoSyncState.uploading => 7,
  PhotoSyncState.queued => 6,
  PhotoSyncState.retryRequired => 5,
  PhotoSyncState.mappingConflict => 4,
  PhotoSyncState.localOnly => 3,
  PhotoSyncState.missingLocal => 2,
  PhotoSyncState.permanentFailure => 1,
  PhotoSyncState.deleted => 0,
};

BaseSurvey mergeDuplicateSurveys(
  List<BaseSurvey> values, {
  required bool hasPendingOperations,
}) {
  if (values.isEmpty) throw ArgumentError('At least one survey is required.');
  final ordered = [...values]
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  final remote = ordered.where(_hasServerState).firstOrNull;
  var local = values.first;
  for (final candidate in values.skip(1)) {
    if (_evidenceCount(candidate) > _evidenceCount(local)) local = candidate;
  }
  final steps = List.generate(6, (index) {
    final candidates = values.map((survey) => survey.steps[index]).toList();
    final localStep = local.steps[index];
    final comment = candidates
        .map((step) => step.comment)
        .whereType<String>()
        .where((value) => value.trim().isNotEmpty)
        .firstOrNull;
    final state = [...candidates]
      ..sort((a, b) => _stepRank(b.state).compareTo(_stepRank(a.state)));
    return SurveyStep(
      number: index + 1,
      state: state.first.state,
      comment: localStep.comment?.trim().isNotEmpty == true
          ? localStep.comment
          : comment,
      photoIds: canonicalUuidList(candidates.expand((step) => step.photoIds)),
    );
  });
  final server = remote ?? ordered.first;
  return BaseSurvey(
    id: canonicalUuid(local.id),
    displayIdentifier: server.displayIdentifier.isNotEmpty
        ? server.displayIdentifier
        : local.displayIdentifier,
    accountNumber: server.accountNumber ?? local.accountNumber,
    contractorName: local.contractorName.isNotEmpty
        ? local.contractorName
        : server.contractorName,
    createdAt: values
        .map((survey) => survey.createdAt)
        .reduce((a, b) => a.isBefore(b) ? a : b),
    updatedAt: ordered.first.updatedAt,
    status: hasPendingOperations ? local.status : server.status,
    localState: hasPendingOperations ? local.localState : server.localState,
    syncState: hasPendingOperations ? SyncState.pending : server.syncState,
    currentStep: values
        .map((survey) => survey.currentStep)
        .reduce((a, b) => a > b ? a : b),
    steps: steps,
    corrections: _mergeCorrections(
      values.expand((survey) => survey.corrections),
    ),
    canonicalLocation: server.canonicalLocation ?? local.canonicalLocation,
    rejectionReason: server.rejectionReason ?? local.rejectionReason,
  );
}

bool _hasServerState(BaseSurvey survey) =>
    survey.syncState == SyncState.synchronized ||
    survey.steps.any((step) => step.state == StepState.completedServer);

int _evidenceCount(BaseSurvey survey) =>
    survey.steps.fold(0, (count, step) => count + step.photoIds.length);

int _stepRank(StepState state) => switch (state) {
  StepState.completedLocal => 4,
  StepState.completedServer => 3,
  StepState.open => 2,
  StepState.locked => 1,
};

List<CorrectionRound> _mergeCorrections(Iterable<CorrectionRound> source) {
  final grouped = <String, List<CorrectionRound>>{};
  for (final correction in source) {
    grouped.putIfAbsent(canonicalUuid(correction.id), () => []).add(correction);
  }
  return grouped.entries.map((entry) {
    final values = entry.value;
    final local = values.reduce(
      (a, b) => a.photoIds.length >= b.photoIds.length ? a : b,
    );
    return CorrectionRound(
      id: entry.key,
      round: values.map((value) => value.round).reduce((a, b) => a > b ? a : b),
      state: values.any((value) => value.state == StepState.completedLocal)
          ? StepState.completedLocal
          : values.any((value) => value.state == StepState.completedServer)
          ? StepState.completedServer
          : StepState.open,
      comment:
          local.comment ??
          values.map((value) => value.comment).whereType<String>().firstOrNull,
      photoIds: canonicalUuidList(values.expand((value) => value.photoIds)),
    );
  }).toList();
}
