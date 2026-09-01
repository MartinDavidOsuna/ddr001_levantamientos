import 'dart:convert';

import 'package:hive_ce/hive.dart';

enum ConstructionJournalOperation { capturePhoto, deletePhoto }

enum ConstructionJournalState {
  prepared,
  fileDurable,
  metadataPersisted,
  linked,
  queued,
  committed,
  recovered,
  failedNeedsReview,
}

class ConstructionJournalEntry {
  const ConstructionJournalEntry({
    required this.id,
    required this.operation,
    required this.state,
    required this.surveyId,
    required this.createdAt,
    this.photoId,
    this.step,
    this.correctionId,
    this.purpose,
    this.sourcePath,
    this.uploadPath,
    this.thumbnailPath,
    this.sha256,
    this.fileSize,
    this.remotePossible = false,
    this.lastError,
  });

  final String id;
  final ConstructionJournalOperation operation;
  final ConstructionJournalState state;
  final String surveyId;
  final DateTime createdAt;
  final String? photoId, correctionId, purpose;
  final int? step, fileSize;
  final String? sourcePath, uploadPath, thumbnailPath, sha256, lastError;
  final bool remotePossible;

  ConstructionJournalEntry copyWith({
    ConstructionJournalState? state,
    String? sourcePath,
    String? uploadPath,
    String? thumbnailPath,
    String? sha256,
    int? fileSize,
    bool? remotePossible,
    String? lastError,
  }) => ConstructionJournalEntry(
    id: id,
    operation: operation,
    state: state ?? this.state,
    surveyId: surveyId,
    createdAt: createdAt,
    photoId: photoId,
    step: step,
    correctionId: correctionId,
    purpose: purpose,
    sourcePath: sourcePath ?? this.sourcePath,
    uploadPath: uploadPath ?? this.uploadPath,
    thumbnailPath: thumbnailPath ?? this.thumbnailPath,
    sha256: sha256 ?? this.sha256,
    fileSize: fileSize ?? this.fileSize,
    remotePossible: remotePossible ?? this.remotePossible,
    lastError: lastError ?? this.lastError,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'operation': operation.name,
    'state': state.name,
    'surveyId': surveyId,
    'photoId': photoId,
    'step': step,
    'correctionId': correctionId,
    'purpose': purpose,
    'sourcePath': sourcePath,
    'uploadPath': uploadPath,
    'thumbnailPath': thumbnailPath,
    'sha256': sha256,
    'fileSize': fileSize,
    'remotePossible': remotePossible,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'lastError': lastError,
  };

  factory ConstructionJournalEntry.fromJson(Map<String, dynamic> json) =>
      ConstructionJournalEntry(
        id: '${json['id']}',
        operation: ConstructionJournalOperation.values.byName(
          '${json['operation']}',
        ),
        state: ConstructionJournalState.values.byName('${json['state']}'),
        surveyId: '${json['surveyId']}',
        photoId: json['photoId']?.toString(),
        step: (json['step'] as num?)?.toInt(),
        correctionId: json['correctionId']?.toString(),
        purpose: json['purpose']?.toString(),
        sourcePath: json['sourcePath']?.toString(),
        uploadPath: json['uploadPath']?.toString(),
        thumbnailPath: json['thumbnailPath']?.toString(),
        sha256: json['sha256']?.toString(),
        fileSize: (json['fileSize'] as num?)?.toInt(),
        remotePossible: json['remotePossible'] == true,
        createdAt: DateTime.parse('${json['createdAt']}').toUtc(),
        lastError: json['lastError']?.toString(),
      );
}

class ConstructionOperationJournal {
  const ConstructionOperationJournal(this.box);
  final Box<String> box;

  Future<void> save(ConstructionJournalEntry entry) =>
      box.put(entry.id, jsonEncode(entry.toJson()));

  ConstructionJournalEntry? find(String id) {
    final raw = box.get(id);
    if (raw == null) return null;
    return ConstructionJournalEntry.fromJson(
      Map<String, dynamic>.from(jsonDecode(raw) as Map),
    );
  }

  List<ConstructionJournalEntry> entries() {
    final result = <ConstructionJournalEntry>[];
    for (final raw in box.values) {
      try {
        result.add(
          ConstructionJournalEntry.fromJson(
            Map<String, dynamic>.from(jsonDecode(raw) as Map),
          ),
        );
      } on Object {
        // Keep unreadable values in Hive. Certification recovery never deletes
        // unknown evidence or journal data silently.
      }
    }
    return result;
  }

  List<ConstructionJournalEntry> pending() => entries()
      .where(
        (entry) =>
            entry.state != ConstructionJournalState.committed &&
            entry.state != ConstructionJournalState.recovered,
      )
      .toList();
}
