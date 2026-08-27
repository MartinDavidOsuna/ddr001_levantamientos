import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../domain/construction/construction_models.dart';
import '../identity/uuid_identity.dart';

class PhotoCaptureService {
  Future<ConstructionPhoto?> capture({
    required String surveyId,
    int? step,
    String? correctionId,
    PhotoPurpose? purpose,
  }) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 95,
    );
    if (picked == null) return null;
    final id = canonicalUuid(const Uuid().v4()),
        canonicalSurveyId = canonicalUuid(surveyId),
        root = Directory(
          p.join(
            (await getApplicationDocumentsDirectory()).path,
            'construction',
            canonicalSurveyId,
          ),
        );
    await root.create(recursive: true);
    final output = p.join(root.path, '$id.jpg'),
        thumbnail = p.join(root.path, '${id}_thumb.jpg');
    final normalized = await FlutterImageCompress.compressAndGetFile(
      picked.path,
      output,
      quality: 88,
      minWidth: 1920,
      minHeight: 1920,
      format: CompressFormat.jpeg,
    );
    if (normalized == null) {
      throw StateError('No fue posible procesar la fotografía.');
    }
    final thumb = await FlutterImageCompress.compressAndGetFile(
      normalized.path,
      thumbnail,
      quality: 70,
      minWidth: 420,
      minHeight: 420,
      format: CompressFormat.jpeg,
    );
    if (thumb == null) throw StateError('No fue posible crear la miniatura.');
    final digest = sha256
        .convert(await File(normalized.path).readAsBytes())
        .toString();
    return ConstructionPhoto(
      id: id,
      surveyId: canonicalSurveyId,
      localPath: normalized.path,
      thumbnailPath: thumb.path,
      sha256: digest,
      capturedAt: DateTime.now().toUtc(),
      stepNumber: step,
      correctionId: canonicalUuidOrNull(correctionId),
      purpose: purpose,
      syncState: PhotoSyncState.localOnly,
    );
  }
}
