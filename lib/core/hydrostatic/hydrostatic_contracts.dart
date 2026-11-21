import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import '../../domain/hydrostatic/hydrostatic_models.dart';

class HydrostaticClockReading {
  const HydrostaticClockReading(this.utc, this.runId, this.monotonicMs);
  final DateTime utc;
  final String runId;
  final int? monotonicMs;
  HydroJson toJson() => {
    'utc': utc.toUtc().toIso8601String(),
    'runId': runId,
    'monotonicMs': monotonicMs,
  };
  factory HydrostaticClockReading.fromJson(HydroJson j) =>
      HydrostaticClockReading(
        hydroDate(j['utc']),
        j['runId'],
        j['monotonicMs'],
      );
}

abstract interface class HydrostaticClock {
  HydrostaticClockReading now();
}

class SystemHydrostaticClock implements HydrostaticClock {
  final _watch = Stopwatch()..start();
  final _runId = const Uuid().v4();
  @override
  HydrostaticClockReading now() => HydrostaticClockReading(
    DateTime.now().toUtc(),
    _runId,
    _watch.elapsedMilliseconds,
  );
}

class HydrostaticElapsed {
  const HydrostaticElapsed(this.milliseconds, this.state, this.anomalies);
  final int milliseconds;
  final HydrostaticTimeState state;
  final List<String> anomalies;
  static HydrostaticElapsed between(
    HydrostaticClockReading start,
    HydrostaticClockReading end,
  ) {
    final wall = end.utc.difference(start.utc).inMilliseconds;
    final same =
        start.runId == end.runId &&
        start.monotonicMs != null &&
        end.monotonicMs != null;
    final elapsed = same ? end.monotonicMs! - start.monotonicMs! : wall;
    final anomalies = <String>[];
    if (wall < 0 || elapsed < 0) anomalies.add('NEGATIVE_DURATION');
    if (same && (wall - elapsed).abs() > 5000) {
      anomalies.add('WALL_CLOCK_CHANGED');
    }
    return HydrostaticElapsed(
      elapsed,
      anomalies.isNotEmpty
          ? HydrostaticTimeState.needsReview
          : same
          ? HydrostaticTimeState.consistent
          : HydrostaticTimeState.reconstructed,
      anomalies,
    );
  }

  String get display {
    if (milliseconds < 0) return '--:--:--';
    final seconds = milliseconds ~/ 1000;
    return '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}

class HydrostaticAccess {
  const HydrostaticAccess({
    required this.actor,
    required this.authorized,
    required this.fieldSession,
  });
  final HydrostaticActorSnapshot actor;
  final bool authorized, fieldSession;
  void requireUser(String userId) => hydroRequire(
    authorized && fieldSession && actor.userId == userId,
    'NOT_AUTHORIZED',
    'Requiere la sesión autorizada del actor original.',
  );
}

abstract interface class HydrostaticCabinetLookup {
  Future<HydrostaticCabinetSnapshot?> findLocal(
    String canonicalUid,
    HydrostaticAccess access,
  );
}

abstract interface class HydrostaticLocationProvider {
  Future<HydrostaticLocation> capture();
}

class HydrostaticCaptureIntent {
  HydrostaticCaptureIntent({
    required this.id,
    required this.testId,
    required this.actorId,
    required this.role,
    required this.requestedAt,
  }) {
    hydroUuid(id);
    hydroUuid(testId);
    hydroIdentityGuid(actorId, field: 'actorId');
  }
  final String id, testId, actorId;
  final HydrostaticEvidenceRole role;
  final DateTime requestedAt;
  String get module => 'hydrostatic';
}

/// M2 contract only. No picker, camera, GPS or legacy recovery is invoked.
abstract interface class HydrostaticPhotoCoordinator {
  Future<HydrostaticEvidence?> capture(HydrostaticCaptureIntent intent);
  Future<List<HydrostaticEvidence>> recover(HydrostaticAccess access);
  bool isCapturing(String testId);
}

abstract interface class HydrostaticEvidenceFiles {
  Future<bool> verify(HydrostaticEvidence evidence);
  Future<void> removeExclusive(
    String testId,
    List<HydrostaticEvidence> evidence,
    Set<String> protectedPaths,
  );
}

/// Only explicit evidence manifests, never recursive/global cleanup. Original
/// files are verified by length and streaming SHA-256; image decoding belongs
/// to the future capture adapter, not this local persistence implementation.
class LocalHydrostaticEvidenceFiles implements HydrostaticEvidenceFiles {
  LocalHydrostaticEvidenceFiles(this.supportDirectory);
  final Directory supportDirectory;
  Future<File> _file(String testId, String relative) async {
    hydroUuid(testId);
    hydroRequire(
      relative.startsWith('hydrostatic/$testId/evidence/') &&
          relative.split('/').length == 4 &&
          !relative.contains('..') &&
          !relative.contains('\\'),
      'INVALID_PATH',
      'Ruta fuera de la prueba.',
    );
    final root = await supportDirectory.resolveSymbolicLinks();
    var current = root;
    for (final segment in relative.split('/')) {
      current = p.join(current, segment);
      final type = await FileSystemEntity.type(current, followLinks: false);
      hydroRequire(
        type != FileSystemEntityType.link,
        'INVALID_PATH',
        'No se siguen enlaces simbólicos.',
      );
    }
    hydroRequire(
      p.isWithin(root, current),
      'INVALID_PATH',
      'Ruta fuera del almacenamiento.',
    );
    return File(current);
  }

  @override
  Future<bool> verify(HydrostaticEvidence evidence) async {
    final file = await _file(evidence.testId, evidence.originalPath);
    if (!await file.exists() || await file.length() != evidence.byteLength) {
      return false;
    }
    return (await sha256.bind(file.openRead()).first).toString() ==
        evidence.sha256;
  }

  @override
  Future<void> removeExclusive(
    String testId,
    List<HydrostaticEvidence> evidence,
    Set<String> protectedPaths,
  ) async {
    final paths = evidence.map((e) => e.originalPath).toSet();
    hydroRequire(
      paths.intersection(protectedPaths).isEmpty,
      'SHARED_FILE',
      'Archivo relacionado con otro registro.',
    );
    final files = <File>[];
    // Validate every path before deleting any file.
    for (final path in paths) {
      files.add(await _file(testId, path));
    }
    for (final file in files) {
      if (await file.exists()) await file.delete();
    }
  }
}

class HydrostaticDevelopmentPolicy {
  const HydrostaticDevelopmentPolicy({
    this.environment = 'production',
    this.enabled = false,
    this.syntheticData = false,
  });
  final String environment;
  final bool enabled, syntheticData;
  void requireDeletion() => hydroRequire(
    ['development', 'test'].contains(environment) &&
        enabled &&
        syntheticData &&
        const String.fromEnvironment('APP_ENV') != 'production',
    'DELETE_DISABLED',
    'Eliminación exclusiva de desarrollo con fixtures sintéticos.',
  );
}
