import '../../core/identity/uuid_identity.dart';

enum ConstructionRole { contractor, resident, admin, superadmin }

extension ConstructionCapabilities on ConstructionRole {
  bool get isReviewer => this != ConstructionRole.contractor;
  bool get canViewAllSurveys => isReviewer;
  bool get canReviewBase => isReviewer;
  bool get canAccept => isReviewer;
  bool get canReject => isReviewer;
  bool get canEditIdentity => isReviewer;
  bool get canDeliver => isReviewer;
  bool get canCorrectCanonicalLocation => isReviewer;
  bool get canMutateEvidence => this == ConstructionRole.contractor;
  String get surveyListTitle =>
      isReviewer ? 'Levantamientos' : 'Mis levantamientos';
  String get displayLabel => switch (this) {
    ConstructionRole.contractor => 'Contratista',
    ConstructionRole.resident => 'Residente',
    ConstructionRole.admin => 'Administrador',
    ConstructionRole.superadmin => 'Superadministrador',
  };
}

enum SurveyStatus {
  created,
  inProgress,
  executed,
  rejected,
  accepted,
  delivered,
}

String surveyStatusLabel(SurveyStatus status) => switch (status) {
  SurveyStatus.created => 'Creado',
  SurveyStatus.inProgress => 'En proceso',
  SurveyStatus.executed => 'Ejecutado',
  SurveyStatus.rejected => 'Rechazado',
  SurveyStatus.accepted => 'Entregable',
  SurveyStatus.delivered => 'Entregado',
};

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

enum PhotoLocationState { pending, provisional, confirmed, unresolved }

enum LocationConfidence { excellent, good, acceptable, weak, invalid }

enum LocationConsistency { unknown, consistent, uncertain, outlier }

enum LocationIntegrityFlag { none, mocked }

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
    PhotoLocationState? locationState,
    this.locationFixAt,
    this.locationAcquiredAt,
    this.locationAltitudeAccuracy,
    this.locationHeading,
    this.locationSpeed,
    this.locationSource,
    this.locationTemporalDeltaMs,
    this.locationConfidence,
    this.locationDistanceToCanonical,
    this.locationConsistency = LocationConsistency.unknown,
    this.locationIntegrityFlag = LocationIntegrityFlag.none,
  }) : locationState =
           locationState ??
           (location == null
               ? PhotoLocationState.pending
               : PhotoLocationState.confirmed);
  final String id, surveyId, localPath, thumbnailPath, sha256;
  final int? stepNumber;
  final String? correctionId;
  final DateTime capturedAt;
  final GeoPoint? location;
  final PhotoPurpose? purpose;
  final PhotoSyncState syncState;
  final PhotoLocationState locationState;
  final DateTime? locationFixAt, locationAcquiredAt;
  final double? locationAltitudeAccuracy, locationHeading, locationSpeed;
  final String? locationSource;
  final int? locationTemporalDeltaMs;
  final LocationConfidence? locationConfidence;
  final double? locationDistanceToCanonical;
  final LocationConsistency locationConsistency;
  final LocationIntegrityFlag locationIntegrityFlag;
  bool get locationPending =>
      locationState != PhotoLocationState.unresolved &&
      (locationState == PhotoLocationState.pending ||
          locationState == PhotoLocationState.provisional ||
          location == null ||
          !location!.isValid);
  bool get locationConfirmed =>
      locationState == PhotoLocationState.confirmed &&
      location != null &&
      location!.isValid;
  bool get locationUnresolved => locationState == PhotoLocationState.unresolved;
  ConstructionPhoto copyWith({
    GeoPoint? location,
    PhotoSyncState? syncState,
    PhotoLocationState? locationState,
    DateTime? locationFixAt,
    DateTime? locationAcquiredAt,
    double? locationAltitudeAccuracy,
    double? locationHeading,
    double? locationSpeed,
    String? locationSource,
    int? locationTemporalDeltaMs,
    LocationConfidence? locationConfidence,
    double? locationDistanceToCanonical,
    LocationConsistency? locationConsistency,
    LocationIntegrityFlag? locationIntegrityFlag,
  }) => ConstructionPhoto(
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
    locationState:
        locationState ??
        (location != null && this.location == null
            ? PhotoLocationState.confirmed
            : this.locationState),
    locationFixAt: locationFixAt ?? this.locationFixAt,
    locationAcquiredAt: locationAcquiredAt ?? this.locationAcquiredAt,
    locationAltitudeAccuracy:
        locationAltitudeAccuracy ?? this.locationAltitudeAccuracy,
    locationHeading: locationHeading ?? this.locationHeading,
    locationSpeed: locationSpeed ?? this.locationSpeed,
    locationSource: locationSource ?? this.locationSource,
    locationTemporalDeltaMs:
        locationTemporalDeltaMs ?? this.locationTemporalDeltaMs,
    locationConfidence: locationConfidence ?? this.locationConfidence,
    locationDistanceToCanonical:
        locationDistanceToCanonical ?? this.locationDistanceToCanonical,
    locationConsistency: locationConsistency ?? this.locationConsistency,
    locationIntegrityFlag: locationIntegrityFlag ?? this.locationIntegrityFlag,
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
    'locationState': locationState.name,
    'locationFixAt': locationFixAt?.toIso8601String(),
    'locationAcquiredAt': locationAcquiredAt?.toIso8601String(),
    'locationAltitudeAccuracy': locationAltitudeAccuracy,
    'locationHeading': locationHeading,
    'locationSpeed': locationSpeed,
    'locationSource': locationSource,
    'locationTemporalDeltaMs': locationTemporalDeltaMs,
    'locationConfidence': locationConfidence?.name,
    'locationDistanceToCanonical': locationDistanceToCanonical,
    'locationConsistency': locationConsistency.name,
    'locationIntegrityFlag': locationIntegrityFlag.name,
  };
  factory ConstructionPhoto.fromJson(
    Map<String, dynamic> j,
  ) => ConstructionPhoto(
    id: canonicalUuid(j['id'] as String),
    surveyId: canonicalUuid(j['surveyId'] as String),
    localPath: j['localPath'] as String,
    thumbnailPath: j['thumbnailPath'] as String,
    sha256: j['sha256'] as String,
    capturedAt: DateTime.parse(j['capturedAt'] as String),
    stepNumber: j['stepNumber'] as int?,
    correctionId: canonicalUuidOrNull(j['correctionId'] as String?),
    location: j['location'] == null
        ? null
        : GeoPoint.fromJson(Map<String, dynamic>.from(j['location'] as Map)),
    syncState: PhotoSyncState.values.byName(j['syncState'] as String),
    purpose: j['purpose'] == null
        ? null
        : PhotoPurpose.values.byName(j['purpose'] as String),
    locationState: j['locationState'] == null
        ? j['location'] == null
              ? PhotoLocationState.pending
              : PhotoLocationState.confirmed
        : PhotoLocationState.values.byName(j['locationState'] as String),
    locationFixAt: DateTime.tryParse('${j['locationFixAt'] ?? ''}'),
    locationAcquiredAt: DateTime.tryParse('${j['locationAcquiredAt'] ?? ''}'),
    locationAltitudeAccuracy: (j['locationAltitudeAccuracy'] as num?)
        ?.toDouble(),
    locationHeading: (j['locationHeading'] as num?)?.toDouble(),
    locationSpeed: (j['locationSpeed'] as num?)?.toDouble(),
    locationSource: j['locationSource'] as String?,
    locationTemporalDeltaMs: j['locationTemporalDeltaMs'] as int?,
    locationConfidence: j['locationConfidence'] == null
        ? null
        : LocationConfidence.values.byName(j['locationConfidence'] as String),
    locationDistanceToCanonical: (j['locationDistanceToCanonical'] as num?)
        ?.toDouble(),
    locationConsistency: j['locationConsistency'] == null
        ? LocationConsistency.unknown
        : LocationConsistency.values.byName(j['locationConsistency'] as String),
    locationIntegrityFlag: j['locationIntegrityFlag'] == null
        ? LocationIntegrityFlag.none
        : LocationIntegrityFlag.values.byName(
            j['locationIntegrityFlag'] as String,
          ),
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
    photoIds: canonicalUuidList(
      List<String>.from(j['photoIds'] as List? ?? const []),
    ),
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
    id: canonicalUuid(j['id'] as String),
    round: j['round'] as int,
    state: StepState.values.byName(j['state'] as String),
    comment: j['comment'] as String?,
    photoIds: canonicalUuidList(
      List<String>.from(j['photoIds'] as List? ?? const []),
    ),
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
    String? displayIdentifier,
    String? contractorName,
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
    bool clearAccountNumber = false,
  }) => BaseSurvey(
    id: id,
    displayIdentifier: displayIdentifier ?? this.displayIdentifier,
    accountNumber: clearAccountNumber
        ? null
        : accountNumber ?? this.accountNumber,
    contractorName: contractorName ?? this.contractorName,
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
    id: canonicalUuid(j['id'] as String),
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
    required this.role,
  });
  final String userId, displayName, email, phone;
  final ConstructionRole role;
  Map<String, dynamic> toJson() => {
    'userId': userId,
    'displayName': displayName,
    'email': email,
    'phone': phone,
    'constructionRole': role.name,
  };
  factory ConstructionProfile.fromJson(Map<String, dynamic> j) =>
      ConstructionProfile(
        userId: canonicalUuid('${j['userId']}'),
        displayName: '${j['displayName'] ?? ''}',
        email: '${j['email'] ?? ''}',
        phone: '${j['phone'] ?? ''}',
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
  SyncQueueItem copyWith({
    int? attempts,
    DateTime? nextAttemptAt,
    bool clearNextAttempt = false,
  }) => SyncQueueItem(
    id: id,
    surveyId: surveyId,
    operation: operation,
    createdAt: createdAt,
    photoId: photoId,
    step: step,
    correctionId: correctionId,
    attempts: attempts ?? this.attempts,
    nextAttemptAt: clearNextAttempt
        ? null
        : nextAttemptAt ?? this.nextAttemptAt,
  );
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
    surveyId: canonicalUuid(j['surveyId'] as String),
    operation: QueueOperation.values.byName(j['operation'] as String),
    photoId: canonicalUuidOrNull(j['photoId'] as String?),
    step: j['step'] as int?,
    correctionId: canonicalUuidOrNull(j['correctionId'] as String?),
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
