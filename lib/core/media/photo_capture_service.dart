import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../domain/construction/construction_models.dart';
import '../identity/uuid_identity.dart';
import '../persistence/construction_operation_journal.dart';
import '../persistence/local_store.dart';

Future<String> sha256File(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

abstract interface class ConstructionImagePicker {
  Future<XFile?> takePhoto();
  Future<LostDataResponse> retrieveLostData();
}

class ImagePickerAdapter implements ConstructionImagePicker {
  ImagePickerAdapter([ImagePicker? picker]) : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;

  @override
  Future<XFile?> takePhoto() => _picker.pickImage(
    source: ImageSource.camera,
    imageQuality: 100,
    requestFullMetadata: true,
  );

  @override
  Future<LostDataResponse> retrieveLostData() => _picker.retrieveLostData();
}

class PhotoCaptureService {
  PhotoCaptureService({
    required this.local,
    ConstructionImagePicker? picker,
    Future<Directory> Function()? supportDirectory,
    Future<Directory> Function()? temporaryDirectory,
    this.representationBuilder,
  }) : picker = picker ?? ImagePickerAdapter(),
       supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final LocalStore local;
  final ConstructionImagePicker picker;
  final Future<Directory> Function() supportDirectory;
  final Future<Directory> Function() temporaryDirectory;
  final Future<bool> Function(File source, File upload, File thumbnail)?
  representationBuilder;

  Future<ConstructionPhoto?> capture({
    required String surveyId,
    int? step,
    String? correctionId,
    PhotoPurpose? purpose,
  }) async {
    final entry = await _prepare(
      id: canonicalUuid(const Uuid().v4()),
      surveyId: surveyId,
      step: step,
      correctionId: correctionId,
      purpose: purpose,
    );
    try {
      final picked = await picker.takePhoto();
      if (picked == null) {
        await local.journal.save(
          entry.copyWith(state: ConstructionJournalState.committed),
        );
        return null;
      }
      return _makeDurable(entry, File(picked.path));
    } on Object catch (error) {
      await local.journal.save(
        entry.copyWith(
          state: ConstructionJournalState.failedNeedsReview,
          lastError: error.runtimeType.toString(),
        ),
      );
      rethrow;
    }
  }

  Future<List<ConstructionPhoto>> recoverPendingCaptures() async {
    await _recordOrphanFiles();
    final pending =
        local.journal
            .pending()
            .where(
              (entry) =>
                  entry.operation == ConstructionJournalOperation.capturePhoto,
            )
            .toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (pending.isEmpty) return const [];
    if (kDebugMode) {
      debugPrint('[CAMERA_RECOVERY] pending=${pending.length}');
    }
    for (final entry in pending) {
      final sourcePath = entry.sourcePath;
      if (sourcePath != null && File(sourcePath).existsSync()) {
        try {
          await _makeDurable(entry, File(sourcePath));
        } on Object {
          // Preserve source and journal; a later bootstrap may recover it.
        }
      }
    }
    XFile? lostFile;
    try {
      final lost = await picker.retrieveLostData();
      lostFile = lost.files?.firstOrNull ?? lost.file;
    } on Object {
      // Journal and staging remain available for the next bootstrap.
    }
    final prepared = pending
        .where((entry) => entry.state == ConstructionJournalState.prepared)
        .firstOrNull;
    if (prepared != null) {
      var restored = false;
      if (lostFile != null) {
        restored = await _tryRecoverCandidate(prepared, File(lostFile.path));
      }
      if (!restored) {
        final cacheCandidate = await _recentPickerCacheCandidate(prepared);
        if (cacheCandidate != null) {
          await _tryRecoverCandidate(prepared, cacheCandidate);
        }
      }
    }
    final recovered = <ConstructionPhoto>[];
    for (final entry in local.journal.pending().where(
      (value) => value.operation == ConstructionJournalOperation.capturePhoto,
    )) {
      final upload = entry.uploadPath;
      final thumb = entry.thumbnailPath;
      if (upload == null ||
          thumb == null ||
          entry.sha256 == null ||
          !File(upload).existsSync() ||
          !File(thumb).existsSync()) {
        continue;
      }
      recovered.add(_photoFromEntry(entry));
    }
    return recovered;
  }

  Future<bool> _tryRecoverCandidate(
    ConstructionJournalEntry prepared,
    File cameraResult,
  ) async {
    if (!cameraResult.existsSync() || await cameraResult.length() == 0) {
      return false;
    }
    try {
      await _makeDurable(prepared, cameraResult);
      return true;
    } on Object catch (error) {
      await local.journal.save(
        prepared.copyWith(
          lastError: 'CAMERA_CACHE_RECOVERY_${error.runtimeType}',
        ),
      );
      // Keep both the picker cache file and journal for later recovery.
      return false;
    }
  }

  Future<File?> _recentPickerCacheCandidate(
    ConstructionJournalEntry prepared,
  ) async {
    final cache = await temporaryDirectory();
    if (!cache.existsSync()) {
      if (kDebugMode) debugPrint('[CAMERA_RECOVERY] cache_missing');
      return null;
    }
    final threshold = prepared.createdAt.subtract(const Duration(minutes: 5));
    final ceiling = prepared.createdAt.add(const Duration(minutes: 5));
    final candidates = <(File, DateTime)>[];
    await for (final entity in cache.list()) {
      if (entity is! File ||
          !const {
            '.jpg',
            '.jpeg',
          }.contains(p.extension(entity.path).toLowerCase())) {
        continue;
      }
      final modified = (await entity.stat()).modified.toUtc();
      if (kDebugMode) {
        debugPrint(
          '[CAMERA_RECOVERY] cache_jpeg modified=${modified.toIso8601String()} '
          'window=${threshold.toIso8601String()}..${ceiling.toIso8601String()}',
        );
      }
      if (!modified.isBefore(threshold) &&
          !modified.isAfter(ceiling) &&
          await entity.length() > 0) {
        candidates.add((entity, modified));
      }
    }
    candidates.sort((a, b) => b.$2.compareTo(a.$2));
    if (kDebugMode) {
      debugPrint('[CAMERA_RECOVERY] cache_candidates=${candidates.length}');
    }
    return candidates.firstOrNull?.$1;
  }

  Future<void> _recordOrphanFiles() async {
    final construction = Directory(
      p.join((await supportDirectory()).path, 'construction'),
    );
    if (!construction.existsSync()) return;
    await for (final entity in construction.list(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.upload.jpg')) continue;
      final id = p.basename(entity.path).replaceFirst('.upload.jpg', '');
      if (!RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        caseSensitive: false,
      ).hasMatch(id)) {
        continue;
      }
      if (local.journal.find(id) != null ||
          local.photos().any((photo) => uuidEquals(photo.id, id))) {
        continue;
      }
      final evidenceDirectory = entity.parent;
      final surveyId = p.basename(evidenceDirectory.parent.path);
      await local.journal.save(
        ConstructionJournalEntry(
          id: canonicalUuid(id),
          operation: ConstructionJournalOperation.capturePhoto,
          state: ConstructionJournalState.failedNeedsReview,
          surveyId: canonicalUuid(surveyId),
          photoId: canonicalUuid(id),
          sourcePath: p.join(evidenceDirectory.path, '$id.source.jpg'),
          uploadPath: entity.path,
          thumbnailPath: p.join(evidenceDirectory.path, '$id.thumb.jpg'),
          sha256: await sha256File(entity),
          fileSize: await entity.length(),
          createdAt: (await entity.stat()).modified.toUtc(),
          lastError: 'ORPHAN_UPLOAD_REQUIRES_LINK',
        ),
      );
    }
  }

  Future<void> advance(String photoId, ConstructionJournalState state) async {
    final entry = local.journal.find(canonicalUuid(photoId));
    if (entry != null) await local.journal.save(entry.copyWith(state: state));
  }

  Future<ConstructionJournalEntry> _prepare({
    required String id,
    required String surveyId,
    int? step,
    String? correctionId,
    PhotoPurpose? purpose,
  }) async {
    final canonicalSurvey = canonicalUuid(surveyId);
    final directory = Directory(
      p.join(
        (await supportDirectory()).path,
        'construction',
        canonicalSurvey,
        'evidence',
      ),
    );
    await directory.create(recursive: true);
    final entry = ConstructionJournalEntry(
      id: id,
      operation: ConstructionJournalOperation.capturePhoto,
      state: ConstructionJournalState.prepared,
      surveyId: canonicalSurvey,
      photoId: id,
      step: step,
      correctionId: canonicalUuidOrNull(correctionId),
      purpose: purpose?.name,
      sourcePath: p.join(directory.path, '$id.source.jpg'),
      uploadPath: p.join(directory.path, '$id.upload.jpg'),
      thumbnailPath: p.join(directory.path, '$id.thumb.jpg'),
      createdAt: DateTime.now().toUtc(),
    );
    await local.journal.save(entry);
    return entry;
  }

  Future<ConstructionPhoto> _makeDurable(
    ConstructionJournalEntry entry,
    File cameraFile,
  ) async {
    final source = File(entry.sourcePath!);
    if (!source.existsSync()) {
      await source.parent.create(recursive: true);
      final partial = File('${source.path}.part');
      final sink = partial.openWrite(mode: FileMode.writeOnly);
      try {
        await cameraFile.openRead().pipe(sink);
      } on Object {
        await sink.close();
        rethrow;
      }
      await partial.rename(source.path);
    }
    var current = entry.copyWith(state: ConstructionJournalState.fileDurable);
    await local.journal.save(current);
    final upload = File(entry.uploadPath!);
    final thumbnail = File(entry.thumbnailPath!);
    if ((!upload.existsSync() || !thumbnail.existsSync()) &&
        !await _buildRepresentations(source, upload, thumbnail)) {
      throw StateError('No fue posible procesar la fotografía.');
    }
    current = current.copyWith(
      state: ConstructionJournalState.fileDurable,
      sha256: await sha256File(upload),
      fileSize: await upload.length(),
    );
    await local.journal.save(current);
    return _photoFromEntry(current);
  }

  Future<bool> _buildRepresentations(
    File source,
    File upload,
    File thumbnail,
  ) async {
    final custom = representationBuilder;
    if (custom != null) return custom(source, upload, thumbnail);
    if (!upload.existsSync()) {
      final normalized = await FlutterImageCompress.compressAndGetFile(
        source.path,
        upload.path,
        quality: 88,
        minWidth: 1920,
        minHeight: 1920,
        format: CompressFormat.jpeg,
      );
      if (normalized == null) return false;
    }
    if (!thumbnail.existsSync()) {
      final thumb = await FlutterImageCompress.compressAndGetFile(
        upload.path,
        thumbnail.path,
        quality: 70,
        minWidth: 420,
        minHeight: 420,
        format: CompressFormat.jpeg,
      );
      if (thumb == null) return false;
    }
    return true;
  }

  ConstructionPhoto _photoFromEntry(ConstructionJournalEntry entry) =>
      ConstructionPhoto(
        id: entry.photoId!,
        surveyId: entry.surveyId,
        localPath: entry.uploadPath!,
        thumbnailPath: entry.thumbnailPath!,
        sha256: entry.sha256!,
        capturedAt: entry.createdAt,
        stepNumber: entry.step,
        correctionId: entry.correctionId,
        purpose: entry.purpose == null
            ? null
            : PhotoPurpose.values.byName(entry.purpose!),
        syncState: PhotoSyncState.localOnly,
      );
}
