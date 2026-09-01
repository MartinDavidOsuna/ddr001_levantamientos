import 'dart:io';

import 'package:ddr001_levantamientos/core/media/photo_capture_service.dart';
import 'package:ddr001_levantamientos/core/persistence/construction_operation_journal.dart';
import 'package:ddr001_levantamientos/core/persistence/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:image_picker/image_picker.dart';

const surveyId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const photoId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

class EmptyPicker implements ConstructionImagePicker {
  @override
  Future<XFile?> takePhoto() async => null;

  @override
  Future<LostDataResponse> retrieveLostData() async => LostDataResponse.empty();
}

class LostPicker extends EmptyPicker {
  LostPicker(this.file);
  final XFile file;

  @override
  Future<LostDataResponse> retrieveLostData() async =>
      LostDataResponse(file: file, files: [file], type: RetrieveType.image);
}

void main() {
  late Directory root;
  late LocalStore local;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('construction-journal-');
    Hive.init(root.path);
    local = await LocalStore.open();
  });

  tearDown(() async {
    await Hive.close();
    await root.delete(recursive: true);
  });

  test('journal round-trip preserves every recovery boundary', () async {
    final entry = ConstructionJournalEntry(
      id: photoId,
      operation: ConstructionJournalOperation.capturePhoto,
      state: ConstructionJournalState.prepared,
      surveyId: surveyId,
      photoId: photoId,
      step: 1,
      sourcePath: '${root.path}/$photoId.source.jpg',
      uploadPath: '${root.path}/$photoId.upload.jpg',
      thumbnailPath: '${root.path}/$photoId.thumb.jpg',
      createdAt: DateTime.utc(2026, 8, 30),
    );
    await local.journal.save(entry);
    final reopened = local.journal.find(photoId)!;
    expect(reopened.state, ConstructionJournalState.prepared);
    expect(reopened.sourcePath, endsWith('.source.jpg'));
    expect(local.journal.pending(), hasLength(1));
  });

  test(
    'process restart reconstructs metadata from durable representation',
    () async {
      final upload = File('${root.path}/$photoId.upload.jpg')
        ..writeAsBytesSync([1, 2, 3]);
      final thumb = File('${root.path}/$photoId.thumb.jpg')
        ..writeAsBytesSync([4, 5]);
      final entry = ConstructionJournalEntry(
        id: photoId,
        operation: ConstructionJournalOperation.capturePhoto,
        state: ConstructionJournalState.fileDurable,
        surveyId: surveyId,
        photoId: photoId,
        step: 1,
        sourcePath: '${root.path}/$photoId.source.jpg',
        uploadPath: upload.path,
        thumbnailPath: thumb.path,
        sha256: 'a' * 64,
        fileSize: 3,
        createdAt: DateTime.utc(2026, 8, 30),
      );
      await local.journal.save(entry);

      final service = PhotoCaptureService(
        local: local,
        picker: EmptyPicker(),
        supportDirectory: () async => root,
      );
      final recovered = await service.recoverPendingCaptures();

      expect(recovered, hasLength(1));
      expect(recovered.single.id, photoId);
      expect(recovered.single.localPath, upload.path);
      expect(recovered.single.sha256, 'a' * 64);
    },
  );

  test('orphan upload bytes are preserved and journaled for review', () async {
    final evidence = Directory('${root.path}/construction/$surveyId/evidence')
      ..createSync(recursive: true);
    File('${evidence.path}/$photoId.upload.jpg').writeAsBytesSync([1, 2, 3]);
    File('${evidence.path}/$photoId.thumb.jpg').writeAsBytesSync([4]);
    final service = PhotoCaptureService(
      local: local,
      picker: EmptyPicker(),
      supportDirectory: () async => root,
    );

    final recovered = await service.recoverPendingCaptures();

    expect(recovered.single.id, photoId);
    final incident = local.journal.find(photoId)!;
    expect(incident.lastError, 'ORPHAN_UPLOAD_REQUIRES_LINK');
    expect(File(incident.uploadPath!).existsSync(), isTrue);
  });

  test(
    'process restart consumes lost camera result into durable paths',
    () async {
      final cameraResult = File('${root.path}/picker-cache.jpg')
        ..writeAsBytesSync(List<int>.generate(8192, (index) => index & 0xff));
      final evidence = Directory('${root.path}/construction/$surveyId/evidence')
        ..createSync(recursive: true);
      await local.journal.save(
        ConstructionJournalEntry(
          id: photoId,
          operation: ConstructionJournalOperation.capturePhoto,
          state: ConstructionJournalState.prepared,
          surveyId: surveyId,
          photoId: photoId,
          step: 1,
          sourcePath: '${evidence.path}/$photoId.source.jpg',
          uploadPath: '${evidence.path}/$photoId.upload.jpg',
          thumbnailPath: '${evidence.path}/$photoId.thumb.jpg',
          createdAt: DateTime.utc(2026, 8, 30),
        ),
      );
      final service = PhotoCaptureService(
        local: local,
        picker: LostPicker(XFile(cameraResult.path)),
        supportDirectory: () async => root,
        representationBuilder: (source, upload, thumbnail) async {
          await source.openRead().pipe(upload.openWrite());
          await source.openRead(0, 256).pipe(thumbnail.openWrite());
          return true;
        },
      );

      final recovered = await service.recoverPendingCaptures();

      expect(recovered, hasLength(1));
      expect(recovered.single.id, photoId);
      expect(File('${evidence.path}/$photoId.source.jpg').lengthSync(), 8192);
      expect(File(recovered.single.localPath).lengthSync(), 8192);
      expect(
        recovered.single.sha256,
        await sha256File(File(recovered.single.localPath)),
      );
      expect(cameraResult.existsSync(), isTrue);
    },
  );

  test(
    'prepared journal recovers recent picker cache when lost data is empty',
    () async {
      final cache = Directory('${root.path}/cache')..createSync();
      final cached = File('${cache.path}/picker-result.jpg')
        ..writeAsBytesSync(
          List<int>.generate(4096, (index) => 255 - (index & 0xff)),
        );
      final evidence = Directory('${root.path}/construction/$surveyId/evidence')
        ..createSync(recursive: true);
      const oldPhotoId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      await local.journal.save(
        ConstructionJournalEntry(
          id: oldPhotoId,
          operation: ConstructionJournalOperation.capturePhoto,
          state: ConstructionJournalState.prepared,
          surveyId: surveyId,
          photoId: oldPhotoId,
          step: 1,
          sourcePath: '${evidence.path}/$oldPhotoId.source.jpg',
          uploadPath: '${evidence.path}/$oldPhotoId.upload.jpg',
          thumbnailPath: '${evidence.path}/$oldPhotoId.thumb.jpg',
          createdAt: DateTime.now().toUtc().subtract(
            const Duration(minutes: 10),
          ),
        ),
      );
      await local.journal.save(
        ConstructionJournalEntry(
          id: photoId,
          operation: ConstructionJournalOperation.capturePhoto,
          state: ConstructionJournalState.prepared,
          surveyId: surveyId,
          photoId: photoId,
          step: 1,
          sourcePath: '${evidence.path}/$photoId.source.jpg',
          uploadPath: '${evidence.path}/$photoId.upload.jpg',
          thumbnailPath: '${evidence.path}/$photoId.thumb.jpg',
          createdAt: DateTime.now().toUtc(),
        ),
      );
      final service = PhotoCaptureService(
        local: local,
        picker: EmptyPicker(),
        supportDirectory: () async => root,
        temporaryDirectory: () async => cache,
        representationBuilder: (source, upload, thumbnail) async {
          await source.openRead().pipe(upload.openWrite());
          await source.openRead(0, 256).pipe(thumbnail.openWrite());
          return true;
        },
      );

      final recovered = await service.recoverPendingCaptures();

      expect(recovered, hasLength(1));
      expect(File(recovered.single.localPath).lengthSync(), 4096);
      expect(cached.existsSync(), isTrue);
      await service.advance(photoId, ConstructionJournalState.committed);
      await service.recoverPendingCaptures();
      expect(
        File('${evidence.path}/$oldPhotoId.source.jpg').existsSync(),
        isFalse,
      );
      expect(
        local.journal.find(oldPhotoId)!.state,
        ConstructionJournalState.prepared,
      );
    },
  );
}
