import '../../domain/construction/construction_models.dart';
import '../identity/uuid_identity.dart';
import '../persistence/uuid_hive_migration.dart';

class QueueReadiness {
  const QueueReadiness.ready() : dependency = null;
  const QueueReadiness.blocked(this.dependency);

  final String? dependency;
  bool get isReady => dependency == null;
}

class ConstructionSyncScheduler {
  const ConstructionSyncScheduler();

  QueueReadiness readiness(
    SyncQueueItem item,
    List<SyncQueueItem> queue,
    List<ConstructionPhoto> photos,
    DateTime now,
  ) {
    if (item.requiresReview) {
      return const QueueReadiness.blocked('requires_review');
    }
    if (item.nextAttemptAt?.isAfter(now) == true) {
      return const QueueReadiness.blocked('retry_cooldown');
    }
    final surveyQueue = queue
        .where((candidate) => uuidEquals(candidate.surveyId, item.surveyId))
        .toList();
    bool pending(
      QueueOperation operation, {
      int? step,
      String? photoId,
      String? correctionId,
    }) => surveyQueue.any(
      (candidate) =>
          candidate.id != item.id &&
          candidate.operation == operation &&
          (step == null || candidate.step == step) &&
          (photoId == null || uuidEquals(candidate.photoId, photoId)) &&
          (correctionId == null ||
              uuidEquals(candidate.correctionId, correctionId)),
    );

    if (item.operation != QueueOperation.ensureProfile &&
        item.operation != QueueOperation.createSurvey &&
        pending(QueueOperation.createSurvey)) {
      return QueueReadiness.blocked(
        canonicalQueueItemId(
          SyncQueueItem(
            id: '',
            surveyId: item.surveyId,
            operation: QueueOperation.createSurvey,
            createdAt: item.createdAt,
          ),
        ),
      );
    }

    final step = item.step;
    if (step != null && item.operation != QueueOperation.openStep) {
      if (pending(QueueOperation.openStep, step: step)) {
        return QueueReadiness.blocked('openStep:$step');
      }
    }
    if (item.operation == QueueOperation.openStep &&
        step != null &&
        step > 1 &&
        pending(QueueOperation.completeStep, step: step - 1)) {
      return QueueReadiness.blocked('completeStep:${step - 1}');
    }

    if (item.operation == QueueOperation.uploadPhoto && step != null) {
      if (pending(QueueOperation.updateComment, step: step)) {
        return QueueReadiness.blocked('updateComment:$step');
      }
    }
    if (item.operation == QueueOperation.verifyPhotos &&
        pending(QueueOperation.uploadPhoto, photoId: item.photoId)) {
      return QueueReadiness.blocked('uploadPhoto:${item.photoId}');
    }
    if (item.operation == QueueOperation.completeStep && step != null) {
      for (final operation in const [
        QueueOperation.updateComment,
        QueueOperation.uploadPhoto,
        QueueOperation.verifyPhotos,
        QueueOperation.deletePhoto,
      ]) {
        if (pending(operation, step: step)) {
          return QueueReadiness.blocked('${operation.name}:$step');
        }
      }
      final evidence = photos.where(
        (photo) =>
            uuidEquals(photo.surveyId, item.surveyId) &&
            photo.stepNumber == step &&
            photo.syncState != PhotoSyncState.deleted,
      );
      if (evidence.any(
        (photo) => photo.syncState != PhotoSyncState.confirmed,
      )) {
        return const QueueReadiness.blocked('evidence_confirmed');
      }
    }
    if (item.operation == QueueOperation.completeCorrection) {
      for (final operation in const [
        QueueOperation.uploadPhoto,
        QueueOperation.verifyPhotos,
        QueueOperation.deletePhoto,
      ]) {
        if (pending(operation, correctionId: item.correctionId)) {
          return QueueReadiness.blocked(
            '${operation.name}:correction:${item.correctionId}',
          );
        }
      }
      final evidence = photos.where(
        (photo) => uuidEquals(photo.correctionId, item.correctionId),
      );
      if (evidence.any(
        (photo) => photo.syncState != PhotoSyncState.confirmed,
      )) {
        return const QueueReadiness.blocked('correction_evidence_confirmed');
      }
    }
    return const QueueReadiness.ready();
  }

  List<SyncQueueItem> readyRound(
    List<SyncQueueItem> queue,
    List<ConstructionPhoto> photos,
    DateTime now,
  ) {
    final chronological = [...queue]
      ..sort((left, right) => left.createdAt.compareTo(right.createdAt));
    final selected = <SyncQueueItem>[], seenSurveys = <String>{};
    for (final item in chronological) {
      final survey = canonicalUuid(item.surveyId);
      if (seenSurveys.contains(survey)) continue;
      if (readiness(item, queue, photos, now).isReady) {
        selected.add(item);
        seenSurveys.add(survey);
      }
    }
    return selected;
  }
}
