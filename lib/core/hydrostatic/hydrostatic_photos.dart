import 'dart:io';
import 'dart:ui' as ui;
import '../../data/hydrostatic/hydrostatic_repository.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';
import '../media/camera_capture_broker.dart';
import 'hydrostatic_contracts.dart';

Future<bool> decodeHydrostaticPhoto(File file) async {
  try {
    final codec = await ui.instantiateImageCodec(
      await file.readAsBytes(),
      targetWidth: 32,
    );
    final frame = await codec.getNextFrame();
    final valid = frame.image.width > 0 && frame.image.height > 0;
    frame.image.dispose();
    codec.dispose();
    return valid;
  } catch (_) {
    return false;
  }
}

class DurableHydrostaticPhotos implements HydrostaticPhotoCoordinator {
  DurableHydrostaticPhotos({
    required this.repository,
    required this.broker,
    required this.support,
    required this.locations,
    this.decode = decodeHydrostaticPhoto,
  });
  final HydrostaticRepository repository;
  final CameraCaptureBroker broker;
  final Directory support;
  final HydrostaticLocationProvider locations;
  final Future<bool> Function(File) decode;
  String? _capturing;
  bool _recovering = false;
  @override
  bool isCapturing(String id) => _capturing == id;
  Future<void> _save(Map<String, dynamic> row) => repository.store.serial(
    () => repository.store.write(
      repository.store.metadata,
      'capture:${row['id']}',
      row,
      'captureIntent',
    ),
  );
  @override
  Future<HydrostaticEvidence?> capture(HydrostaticCaptureIntent intent) async {
    hydroRequire(
      _capturing == null && !_recovering,
      'CAMERA_BUSY',
      'Otra captura está en curso.',
    );
    repository.access().requireUser(intent.actorId);
    final test = repository.get(intent.testId)!;
    hydroRequire(
      (intent.role == HydrostaticEvidenceRole.initialSetup &&
              test.state == HydrostaticTestState.preparation) ||
          (intent.role == HydrostaticEvidenceRole.manometer5Bar &&
              test.state == HydrostaticTestState.active),
      'INVALID_STATE',
      'La captura no corresponde a la etapa actual.',
    );
    _capturing = intent.testId;
    final row = <String, dynamic>{
      'id': intent.id,
      'testId': intent.testId,
      'actorId': intent.actorId,
      'role': hydroWire(intent.role),
      'requestedAt': intent.requestedAt.toUtc().toIso8601String(),
      'state': 'REQUESTED',
    };
    try {
      await _save(row);
      final result = await broker.capture(
        id: intent.id,
        module: 'hydrostatic',
        entityId: intent.testId,
        actorId: intent.actorId,
        role: hydroWire(intent.role),
        requestedAt: intent.requestedAt,
      );
      if (result == null) {
        await _save({...row, 'state': 'CANCELLED'});
        return null;
      }
      return await _adopt(row, result, allowGps: true);
    } finally {
      _capturing = null;
    }
  }

  Future<HydrostaticEvidence?> _adopt(
    Map<String, dynamic> row,
    Map<String, dynamic> result, {
    bool allowGps = false,
  }) async {
    final id = row['id'] as String, testId = row['testId'] as String;
    hydroRequire(
      result['module'] == 'hydrostatic' &&
          result['id'] == id &&
          result['entityId'] == testId &&
          result['actorId'] == row['actorId'] &&
          result['role'] == row['role'],
      'CAPTURE_CONFLICT',
      'La intención y el resultado de cámara no coinciden.',
    );
    // Never adopt under a different session. Keep both durable receipts instead.
    repository.access().requireUser(row['actorId']);
    final test = repository.get(testId)!;
    final existing = test.evidence.where((e) => e.id == id).firstOrNull;
    if (existing != null) {
      await _save({...row, 'state': 'LINKED'});
      return existing;
    }
    HydrostaticEvidence evidence;
    if (row['evidence'] != null) {
      evidence = HydrostaticEvidence.fromJson(hydroObject(row['evidence']));
    } else {
      final role = hydroEnum(HydrostaticEvidenceRole.values, row['role']);
      final relative = 'hydrostatic/$testId/evidence/$id.original';
      final file = File('${support.path}/$relative');
      await file.parent.create(recursive: true);
      if (!await file.exists()) {
        final partial = File('${file.path}.part');
        final sink = partial.openWrite();
        await sink.addStream(File(result['originalPath']).openRead());
        await sink.flush();
        await sink.close();
        await partial.rename(file.path);
      }
      final returned = hydroDate(result['returnedAt']),
          modified = hydroDate(result['fileModifiedAt']);
      final requested = hydroDate(row['requestedAt']);
      final knownTime =
          !modified.isBefore(requested) && !modified.isAfter(returned);
      // File time is an estimate, not EXIF shutter time or camera launch time.
      final at = knownTime ? modified : returned;
      HydrostaticLocation? gps;
      if (role == HydrostaticEvidenceRole.manometer5Bar && allowGps) {
        try {
          final candidate = await locations.capture();
          if (candidate.validAt(at, photo: true)) gps = candidate;
        } catch (_) {
          /* Preserve image pending GPS. */
        }
      }
      final inInterval =
          role != HydrostaticEvidenceRole.manometer5Bar ||
          (test.startedAt != null &&
              !at.isBefore(test.startedAt!) &&
              (test.endedAt == null || !at.isAfter(test.endedAt!)));
      final decoded = await decode(file);
      evidence = HydrostaticEvidence(
        id: id,
        testId: testId,
        captureIntentId: id,
        actorId: row['actorId'],
        role: role,
        originalPath: relative,
        sha256: result['sha256'],
        byteLength: result['byteLength'],
        capturedAt: at,
        returnedAt: returned,
        recovered: result['recovered'] == true,
        timeSource: knownTime
            ? HydrostaticCaptureTimeSource.estimated
            : HydrostaticCaptureTimeSource.unknown,
        location: gps,
        integrity: decoded
            ? HydrostaticIntegrity.verified
            : HydrostaticIntegrity.corrupt,
        state:
            knownTime &&
                inInterval &&
                decoded &&
                (role != HydrostaticEvidenceRole.manometer5Bar || gps != null)
            ? HydrostaticEvidenceState.ready
            : HydrostaticEvidenceState.pendingMetadata,
      );
      final intact = await repository.files.verify(evidence);
      if (!intact) {
        throw const HydrostaticException(
          'FILE_CORRUPT',
          'Original ausente o distinto del hash de cámara; datos conservados.',
        );
      }
      row = {...row, 'evidence': evidence.toJson(), 'state': 'FILE_DURABLE'};
      await _save(row);
    }
    repository.access().requireUser(row['actorId']);
    await repository.addEvidence(testId, id, evidence);
    await _save({...row, 'state': 'LINKED'});
    return evidence;
  }

  @override
  Future<List<HydrostaticEvidence>> recover(HydrostaticAccess access) async {
    access.requireUser(access.actor.userId);
    if (_capturing != null || _recovering || broker.busy) return [];
    _recovering = true;
    try {
      await broker.recover();
      final result = <HydrostaticEvidence>[];
      final keys = repository.store.metadata.keys
          .where((k) => '$k'.startsWith('capture:'))
          .toList();
      for (final key in keys) {
        final row = repository.store.read(repository.store.metadata, '$key')!;
        if (row['actorId'] != access.actor.userId ||
            ['LINKED', 'CANCELLED'].contains(row['state'])) {
          continue;
        }
        try {
          final delivered = await broker.result('hydrostatic', row['id']);
          if (delivered != null) {
            final e = await _adopt(row, delivered);
            if (e != null) result.add(e);
          } else {
            final receipt = await broker.receipt('hydrostatic', row['id']);
            if (receipt?['state'] == 'CANCELLED' ||
                receipt?['state'] == 'AMBIGUOUS') {
              await _save({
                ...row,
                'state': receipt!['state'],
                'reason': receipt['reason'],
              });
            }
          }
        } catch (e) {
          repository.access().requireUser(access.actor.userId);
          await _save({
            ...row,
            'state': 'RECOVERY_PENDING',
            'reason': e.runtimeType.toString(),
          });
        }
      }
      return result;
    } finally {
      _recovering = false;
    }
  }
}
