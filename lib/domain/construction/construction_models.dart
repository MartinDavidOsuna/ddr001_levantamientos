enum ConstructionRole { contractor, resident }

enum SurveyStatus {
  created,
  inProgress,
  executed,
  rejected,
  accepted,
  delivered,
}

enum LocalSurveyState { createdLocal, active, executedLocal }

enum SyncState { pending, syncing, synchronized, offline, requiresReview }

enum StepState { locked, open, completedLocal, completedServer }

enum PhotoSyncState {
  localOnly,
  queued,
  uploading,
  uploadedUnverified,
  verifying,
  confirmed,
  retryRequired,
  permanentFailure,
  mappingConflict,
  missingLocal,
  deleted,
}

enum PhotoPurpose { north, east, south, west, additional }

const cardinalPhotoPurposes = <PhotoPurpose>[
  PhotoPurpose.north,
  PhotoPurpose.east,
  PhotoPurpose.south,
  PhotoPurpose.west,
];

String photoPurposeLabel(PhotoPurpose purpose) => switch (purpose) {
  PhotoPurpose.north => 'NORTE',
  PhotoPurpose.east => 'ESTE',
  PhotoPurpose.south => 'SUR',
  PhotoPurpose.west => 'OESTE',
  PhotoPurpose.additional => 'ADICIONAL',
};

enum QueueOperation {
  ensureProfile,
  createSurvey,
  openStep,
  deletePhoto,
  uploadPhoto,
  verifyPhotos,
  updateComment,
  completeStep,
  completeCorrection,
}

String normalizeIdentifier(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toUpperCase();

class GeoPoint {
  const GeoPoint({
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.capturedAt,
    this.altitude,
  });
  final double latitude, longitude, accuracy;
  final double? altitude;
  final DateTime capturedAt;
  bool get isValid =>
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180 &&
      accuracy > 0 &&
      accuracy <= 100;
  Map<String, dynamic> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'accuracy': accuracy,
    'altitude': altitude,
    'capturedAt': capturedAt.toIso8601String(),
  };
  factory GeoPoint.fromJson(Map<String, dynamic> j) => GeoPoint(
    latitude: (j['latitude'] as num).toDouble(),
    longitude: (j['longitude'] as num).toDouble(),
    accuracy: (j['accuracy'] as num).toDouble(),
    altitude: (j['altitude'] as num?)?.toDouble(),
    capturedAt: DateTime.parse(j['capturedAt'] as String),
  );
}

class ConstructionPhoto {
  const ConstructionPhoto({
    required this.id,
    required this.surveyId,
    required this.localPath,
    required this.thumbnailPath,
    required this.sha256,
    required this.capturedAt,
    required this.syncState,
    this.stepNumber,
    this.correctionId,
    this.location,
    this.purpose,
  });
  final String id, surveyId, localPath, thumbnailPath, sha256;
  final int? stepNumber;
  final String? correctionId;
  final DateTime capturedAt;
  final GeoPoint? location;
  final PhotoPurpose? purpose;
  final PhotoSyncState syncState;
  bool get locationPending => location == null || !location!.isValid;
  ConstructionPhoto copyWith({GeoPoint? location, PhotoSyncState? syncState}) =>
      ConstructionPhoto(
        id: id,
        surveyId: surveyId,
        localPath: localPath,
        thumbnailPath: thumbnailPath,
        sha256: sha256,
        capturedAt: capturedAt,
        stepNumber: stepNumber,
        correctionId: correctionId,
        location: location ?? this.location,
        purpose: purpose,
        syncState: syncState ?? this.syncState,
      );
  Map<String, dynamic> toJson() => {
    'id': id,
    'surveyId': surveyId,
    'localPath': localPath,
    'thumbnailPath': thumbnailPath,
    'sha256': sha256,
    'capturedAt': capturedAt.toIso8601String(),
    'stepNumber': stepNumber,
    'correctionId': correctionId,
    'location': location?.toJson(),
    'syncState': syncState.name,
    'purpose': purpose?.name,
  };
  factory ConstructionPhoto.fromJson(Map<String, dynamic> j) =>
      ConstructionPhoto(
        id: j['id'] as String,
        surveyId: j['surveyId'] as String,
        localPath: j['localPath'] as String,
        thumbnailPath: j['thumbnailPath'] as String,
        sha256: j['sha256'] as String,
        capturedAt: DateTime.parse(j['capturedAt'] as String),
        stepNumber: j['stepNumber'] as int?,
        correctionId: j['correctionId'] as String?,
        location: j['location'] == null
            ? null
            : GeoPoint.fromJson(
                Map<String, dynamic>.from(j['location'] as Map),
              ),
        syncState: PhotoSyncState.values.byName(j['syncState'] as String),
        purpose: j['purpose'] == null
            ? null
            : PhotoPurpose.values.byName(j['purpose'] as String),
      );
}

class SurveyStep {
  const SurveyStep({
    required this.number,
    required this.state,
    this.comment,
    this.photoIds = const [],
  });
  final int number;
  final StepState state;
  final String? comment;
  final List<String> photoIds;
  int get minimumPhotos => number == 6 ? 4 : 1;
  int? get maximumPhotos => number == 6 ? null : 4;
  SurveyStep copyWith({
    StepState? state,
    String? comment,
    List<String>? photoIds,
  }) => SurveyStep(
    number: number,
    state: state ?? this.state,
    comment: comment ?? this.comment,
    photoIds: photoIds ?? this.photoIds,
  );
  Map<String, dynamic> toJson() => {
    'number': number,
    'state': state.name,
    'comment': comment,
    'photoIds': photoIds,
  };
  factory SurveyStep.fromJson(Map<String, dynamic> j) => SurveyStep(
    number: j['number'] as int,
    state: StepState.values.byName(j['state'] as String),
    comment: j['comment'] as String?,
    photoIds: List<String>.from(j['photoIds'] as List? ?? const []),
  );
}

class CorrectionRound {
  const CorrectionRound({
    required this.id,
    required this.round,
    required this.state,
    this.comment,
    this.photoIds = const [],
  });
  final String id;
  final int round;
  final StepState state;
  final String? comment;
  final List<String> photoIds;
  Map<String, dynamic> toJson() => {
    'id': id,
    'round': round,
    'state': state.name,
    'comment': comment,
    'photoIds': photoIds,
  };
  factory CorrectionRound.fromJson(Map<String, dynamic> j) => CorrectionRound(
    id: j['id'] as String,
    round: j['round'] as int,
    state: StepState.values.byName(j['state'] as String),
    comment: j['comment'] as String?,
    photoIds: List<String>.from(j['photoIds'] as List? ?? const []),
  );
}

class BaseSurvey {
  const BaseSurvey({
    required this.id,
    required this.displayIdentifier,
    required this.contractorName,
    required this.createdAt,
    required this.updatedAt,
    required this.status,
    required this.localState,
    required this.syncState,
    required this.currentStep,
    required this.steps,
    this.accountNumber,
    this.canonicalLocation,
    this.rejectionReason,
    this.corrections = const [],
  });
  final String id, displayIdentifier, contractorName;
  final String? accountNumber, rejectionReason;
  final DateTime createdAt, updatedAt;
  final SurveyStatus status;
  final LocalSurveyState localState;
  final SyncState syncState;
  final int currentStep;
  final List<SurveyStep> steps;
  final List<CorrectionRound> corrections;
  final GeoPoint? canonicalLocation;
  BaseSurvey copyWith({
    SurveyStatus? status,
    LocalSurveyState? localState,
    SyncState? syncState,
    int? currentStep,
    List<SurveyStep>? steps,
    List<CorrectionRound>? corrections,
    GeoPoint? canonicalLocation,
    String? rejectionReason,
    DateTime? updatedAt,
    String? accountNumber,
  }) => BaseSurvey(
    id: id,
    displayIdentifier: displayIdentifier,
    accountNumber: accountNumber ?? this.accountNumber,
    contractorName: contractorName,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    status: status ?? this.status,
    localState: localState ?? this.localState,
    syncState: syncState ?? this.syncState,
    currentStep: currentStep ?? this.currentStep,
    steps: steps ?? this.steps,
    corrections: corrections ?? this.corrections,
    canonicalLocation: canonicalLocation ?? this.canonicalLocation,
    rejectionReason: rejectionReason ?? this.rejectionReason,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'displayIdentifier': displayIdentifier,
    'accountNumber': accountNumber,
    'contractorName': contractorName,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'status': status.name,
    'localState': localState.name,
    'syncState': syncState.name,
    'currentStep': currentStep,
    'steps': steps.map((e) => e.toJson()).toList(),
    'corrections': corrections.map((e) => e.toJson()).toList(),
    'canonicalLocation': canonicalLocation?.toJson(),
    'rejectionReason': rejectionReason,
  };
  factory BaseSurvey.fromJson(Map<String, dynamic> j) => BaseSurvey(
    id: j['id'] as String,
    displayIdentifier: j['displayIdentifier'] as String,
    accountNumber: j['accountNumber'] as String?,
    contractorName: j['contractorName'] as String? ?? '',
    createdAt: DateTime.parse(j['createdAt'] as String),
    updatedAt: DateTime.parse(j['updatedAt'] as String),
    status: SurveyStatus.values.byName(j['status'] as String),
    localState: LocalSurveyState.values.byName(j['localState'] as String),
    syncState: SyncState.values.byName(j['syncState'] as String),
    currentStep: j['currentStep'] as int,
    steps: (j['steps'] as List)
        .map((e) => SurveyStep.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    corrections: (j['corrections'] as List? ?? const [])
        .map(
          (e) => CorrectionRound.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList(),
    canonicalLocation: j['canonicalLocation'] == null
        ? null
        : GeoPoint.fromJson(
            Map<String, dynamic>.from(j['canonicalLocation'] as Map),
          ),
    rejectionReason: j['rejectionReason'] as String?,
  );
}

class ConstructionProfile {
  const ConstructionProfile({
    required this.userId,
    required this.displayName,
    required this.email,
    required this.phone,
    required this.crew,
    required this.role,
  });
  final String userId, displayName, email, phone, crew;
  final ConstructionRole role;
  Map<String, dynamic> toJson() => {
    'userId': userId,
    'displayName': displayName,
    'email': email,
    'phone': phone,
    'crew': crew,
    'constructionRole': role.name,
  };
  factory ConstructionProfile.fromJson(Map<String, dynamic> j) =>
      ConstructionProfile(
        userId: '${j['userId']}',
        displayName: '${j['displayName'] ?? ''}',
        email: '${j['email'] ?? ''}',
        phone: '${j['phone'] ?? ''}',
        crew: '${j['crew'] ?? ''}',
        role: ConstructionRole.values.byName('${j['constructionRole']}'),
      );
}

class SyncQueueItem {
  const SyncQueueItem({
    required this.id,
    required this.surveyId,
    required this.operation,
    required this.createdAt,
    this.photoId,
    this.step,
    this.correctionId,
    this.attempts = 0,
    this.nextAttemptAt,
  });
  final String id, surveyId;
  final String? photoId, correctionId;
  final int? step;
  final QueueOperation operation;
  final int attempts;
  final DateTime createdAt;
  final DateTime? nextAttemptAt;
  SyncQueueItem retry(DateTime now) {
    final seconds = (1 << attempts.clamp(0, 8)) * 2;
    return SyncQueueItem(
      id: id,
      surveyId: surveyId,
      operation: operation,
      createdAt: createdAt,
      photoId: photoId,
      step: step,
      correctionId: correctionId,
      attempts: attempts + 1,
      nextAttemptAt: now.add(
        Duration(seconds: seconds + id.hashCode.abs() % 5),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'surveyId': surveyId,
    'operation': operation.name,
    'photoId': photoId,
    'step': step,
    'correctionId': correctionId,
    'attempts': attempts,
    'createdAt': createdAt.toIso8601String(),
    'nextAttemptAt': nextAttemptAt?.toIso8601String(),
  };
  factory SyncQueueItem.fromJson(Map<String, dynamic> j) => SyncQueueItem(
    id: j['id'] as String,
    surveyId: j['surveyId'] as String,
    operation: QueueOperation.values.byName(j['operation'] as String),
    photoId: j['photoId'] as String?,
    step: j['step'] as int?,
    correctionId: j['correctionId'] as String?,
    attempts: j['attempts'] as int? ?? 0,
    createdAt: DateTime.parse(j['createdAt'] as String),
    nextAttemptAt: j['nextAttemptAt'] == null
        ? null
        : DateTime.parse(j['nextAttemptAt'] as String),
  );
}

const constructionStepNames = [
  'Creación',
  'Preparación del terreno',
  'Cimbrado',
  'Armado',
  'Colado',
  'Descimbrado',
  'Terminado',
];
