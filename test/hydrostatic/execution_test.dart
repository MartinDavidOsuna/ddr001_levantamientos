import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_contracts.dart';
import 'package:ddr001_levantamientos/domain/hydrostatic/hydrostatic_models.dart';
import 'harness.dart';
import 'execution_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ExecutionHarness h;
  setUp(() async {
    h = ExecutionHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  test(
    'original photo durable SHA, preview path, repeat preserves both and startup recovery',
    () async {
      final id = await h.ready();
      final e = h.repo.get(id)!.evidence.single;
      expect(e.ready, isTrue);
      expect(e.timeSource, HydrostaticCaptureTimeSource.estimated);
      expect(e.returnedAt, isNotNull);
      expect(await h.files.verify(e), isTrue);
      final bytes = await File(
        '${h.root.path}/${e.originalPath}',
      ).readAsBytes();
      expect(
        bytes,
        await File('test/cabinets/fixtures/evidence.jpg').readAsBytes(),
      );
      await h.controller.capturePhoto(id, HydrostaticEvidenceRole.initialSetup);
      expect(h.repo.get(id)!.evidence.length, 2);
      await h.restart();
      expect(h.repo.get(id)!.evidence.length, 2);
      expect(await h.controller.startAvailable(id), isTrue);
    },
  );
  test(
    'cancel camera preserves preparation without consuming attempt',
    () async {
      final id = await h.controller.identify('AQ26000017');
      h.picker.cancel = true;
      await h.controller.capturePhoto(id, HydrostaticEvidenceRole.initialSetup);
      expect(h.repo.get(id)!.evidence, isEmpty);
      expect(await h.controller.startAvailable(id), isFalse);
      expect(h.repo.sequences.last('AQ26000017'), 0);
    },
  );
  test('corrupt image retained but cannot start', () async {
    h.picker.corrupt = true;
    final id = await h.ready();
    expect(
      h.repo.get(id)!.evidence.single.integrity,
      HydrostaticIntegrity.corrupt,
    );
    expect(await h.controller.startAvailable(id), isFalse);
  });
  test('empty or partial camera file does not count as evidence', () async {
    h.picker.empty = true;
    final id = await h.controller.identify('AQ26000017');
    await expectLater(
      h.controller.capturePhoto(id, HydrostaticEvidenceRole.initialSetup),
      throwsStateError,
    );
    expect(h.repo.get(id)!.evidence, isEmpty);
    expect(await h.controller.startAvailable(id), isFalse);
    h.picker.empty = false;
    await h.controller.initialize();
    expect(h.controller.pendingCaptures(id), 1);
    await h.controller.capturePhoto(id, HydrostaticEvidenceRole.initialSetup);
    expect(await h.controller.startAvailable(id), isTrue);
  });
  test('removed and altered original block start', () async {
    final id = await h.ready();
    final e = h.repo.get(id)!.evidence.single;
    await File(
      '${h.root.path}/${e.originalPath}',
    ).writeAsString('corrupt', flush: true);
    expect(await h.controller.startAvailable(id), isFalse);
    await File('${h.root.path}/${e.originalPath}').delete();
    expect(await h.controller.startAvailable(id), isFalse);
  });
  test('initial photo required; no GPS when unavailable', () async {
    final id = await h.controller.identify('AQ26000017');
    await expectLater(
      h.controller.start(id),
      throwsA(isA<HydrostaticException>()),
    );
    expect(h.gps.calls, 0);
    expect(h.repo.get(id)!.startedAt, isNull);
  });
  for (final failure in ['denied', 'timeout', 'revoked']) {
    test(
      'GPS $failure retains photo and preparation, retry uses same UUID',
      () async {
        final id = await h.ready();
        h.gps.error = StateError(failure);
        await expectLater(h.controller.start(id), throwsStateError);
        expect(h.repo.get(id)!.state, HydrostaticTestState.preparation);
        expect(h.repo.sequences.last('AQ26000017'), 0);
        expect(h.repo.get(id)!.evidence.length, 1);
        h.gps.error = null;
        await h.controller.start(id);
        expect(h.repo.get(id)!.attemptNumber, 1);
        expect(h.repo.get(id)!.id, id);
      },
    );
  }
  for (final failure in ['accuracy', 'old', 'future', 'coordinate', 'zero']) {
    test('GPS rejects $failure before numbering', () async {
      final id = await h.ready();
      h.gps.suppliedFix = HydrostaticLocation(
        latitude: failure == 'coordinate' ? 91 : 20,
        longitude: -100,
        accuracy: failure == 'accuracy'
            ? 101
            : failure == 'zero'
            ? 0
            : 5,
        fixAt: h.clock.utc.add(
          Duration(
            seconds: failure == 'old'
                ? -61
                : failure == 'future'
                ? 1
                : 0,
          ),
        ),
        acquiredAt: h.clock.utc,
        source: 'synthetic',
      );
      await expectLater(
        h.controller.start(id),
        throwsA(isA<HydrostaticException>()),
      );
      expect(h.repo.get(id)!.state, HydrostaticTestState.preparation);
      expect(h.repo.get(id)!.attemptNumber, isNull);
    });
  }
  test(
    'duplicate start/finish durable one attempt, elapsed >24h and result pending only',
    () async {
      final id = await h.ready();
      await Future.wait([h.controller.start(id), h.controller.start(id)]);
      final start = h.repo.get(id)!.startedAt;
      expect(h.repo.get(id)!.attemptNumber, 1);
      h.clock.advance(25 * 60 * 60 * 1000 + 12000);
      expect(h.controller.elapsed(id).display, '25:00:12');
      await Future.wait([h.controller.finish(id), h.controller.finish(id)]);
      final end = h.repo.get(id)!.endedAt;
      h.clock.advance(5000);
      await h.controller.finish(id);
      expect(h.repo.get(id)!.endedAt, end);
      expect(h.repo.get(id)!.startedAt, start);
      expect(h.repo.get(id)!.state, HydrostaticTestState.endedPendingResult);
      expect(h.repo.get(id)!.result, HydrostaticResult.pending);
      expect(h.repo.get(id)!.hadLeaks, isNull);
      await h.restart();
      expect(h.repo.get(id)!.endedAt, end);
    },
  );
  test(
    'ACTIVE restart retains number, time reconstructed; clock anomaly is visible',
    () async {
      final id = await h.ready();
      await h.controller.start(id);
      h.clock.advance(3000);
      await h.restart();
      expect(h.repo.get(id)!.state, HydrostaticTestState.active);
      expect(
        h.controller.elapsed(id).state,
        HydrostaticTimeState.reconstructed,
      );
      h.clock.utc = h.clock.utc.subtract(const Duration(days: 1));
      expect(h.controller.elapsed(id).state, HydrostaticTimeState.needsReview);
    },
  );
  test(
    '5 bar during active has timestamp GPS; GPS failed preserves pending photo',
    () async {
      final id = await h.ready();
      await h.controller.start(id);
      await h.controller.capturePhoto(
        id,
        HydrostaticEvidenceRole.manometer5Bar,
      );
      expect(h.repo.get(id)!.evidence.last.ready, isTrue);
      expect(h.repo.get(id)!.evidence.last.location, isNotNull);
      h.gps.error = StateError('denied');
      await h.controller.capturePhoto(
        id,
        HydrostaticEvidenceRole.manometer5Bar,
      );
      expect(
        h.repo.get(id)!.evidence.last.state,
        HydrostaticEvidenceState.pendingMetadata,
      );
      await h.controller.finish(id);
      await expectLater(
        h.controller.capturePhoto(id, HydrostaticEvidenceRole.manometer5Bar),
        throwsA(isA<HydrostaticException>()),
      );
    },
  );
  for (final change in ['model', 'status', 'deleted', 'archived', 'identity']) {
    test(
      'cabinet $change changed blocks start and preserves old preparation',
      () async {
        final id = await h.ready();
        final old = h.records.single;
        h.records = [
          h.record(
            id: change == 'identity' ? uuid() : old.id,
            model: change == 'model' ? 'A3' : 'A1',
            status: change == 'status' ? 'validated' : 'registered',
            deleted: change == 'deleted',
            archived: change == 'archived',
          ),
        ];
        expect(await h.controller.startAvailable(id), isFalse);
        await expectLater(
          h.controller.start(id),
          throwsA(isA<HydrostaticException>()),
        );
        expect(h.repo.get(id)!.attemptNumber, isNull);
      },
    );
  }
  test(
    'session changes during GPS and during camera never attribute to new user',
    () async {
      final original = h.access;
      final id = await h.ready();
      void change() {
        h.access = HydrostaticAccess(
          actor: HydrostaticActorSnapshot(
            userId: uuid(),
            name: 'OTHER',
            sessionId: uuid(),
            deviceInstallationId: uuid(),
          ),
          authorized: true,
          fieldSession: true,
        );
      }

      h.gps.beforeReturn = () async => change();
      await expectLater(
        h.controller.start(id),
        throwsA(isA<HydrostaticException>()),
      );
      expect(h.store.test(id)!.startedAt, isNull);
      h.access = original;
      h.gps.beforeReturn = null;
      h.picker.beforeReturn = () async => change();
      await expectLater(
        h.controller.capturePhoto(id, HydrostaticEvidenceRole.initialSetup),
        throwsA(isA<HydrostaticException>()),
      );
      expect(h.store.test(id)!.evidence.length, 1);
      h.access = original;
      await h.photos.recover(original);
      expect(h.repo.get(id)!.evidence.length, 2);
    },
  );
  test(
    'native lost result recovered into original intention once after restart',
    () async {
      h.picker.throwAfter = true;
      final id = await h.controller.identify('AQ26000017');
      await expectLater(
        h.controller.capturePhoto(id, HydrostaticEvidenceRole.initialSetup),
        throwsStateError,
      );
      h.picker.throwAfter = false;
      await h.restart();
      expect(h.repo.get(id)!.evidence.length, 1);
      expect(h.repo.get(id)!.evidence.single.recovered, isTrue);
      await h.controller.initialize();
      expect(h.repo.get(id)!.evidence.length, 1);
    },
  );
  for (final boundary in ['before:copy', 'after:copy']) {
    test('photo copy fault $boundary preserves receipt and recovery', () async {
      var fail = true;
      h.broker.fault = (point) async {
        if (fail && point == boundary) {
          fail = false;
          throw StateError('synthetic full disk');
        }
      };
      final id = await h.controller.identify('AQ26000017');
      {
        await expectLater(
          h.controller.capturePhoto(id, HydrostaticEvidenceRole.initialSetup),
          throwsStateError,
        );
        await h.restart();
        expect(h.repo.get(id)!.evidence.length, 1);
      }
    });
  }
  for (final boundary in [
    'before:ready',
    'after:ready',
    'before:sequence',
    'after:sequence',
    'before:document',
    'after:document',
    'after:applied',
  ]) {
    test(
      'start interrupted $boundary recovers without second attempt',
      () async {
        final id = await h.ready();
        var fail = true;
        h.store.fault = (point) async {
          // Only interrupt the start carrying the sequence, not requestStart.
          final start = h.repo.journal.entries.where(
            (e) => e['type'] == 'start',
          );
          if (fail && point == boundary && start.isNotEmpty) {
            fail = false;
            throw StateError('interrupted');
          }
        };
        await expectLater(h.controller.start(id), throwsStateError);
        await h.restart();
        if (h.repo.get(id)!.state == HydrostaticTestState.preparation) {
          await h.controller.start(id);
        }
        expect(h.repo.get(id)!.state, HydrostaticTestState.active);
        expect(h.repo.get(id)!.attemptNumber, 1);
      },
    );
  }
  test('capture intent failure never opens camera', () async {
    final id = await h.controller.identify('AQ26000017');
    h.store.fault = (point) async {
      if (point == 'before:captureIntent') throw StateError('disk full');
    };
    await expectLater(
      h.controller.capturePhoto(id, HydrostaticEvidenceRole.initialSetup),
      throwsStateError,
    );
    expect(h.picker.captures, 0);
    expect(h.repo.get(id)!.evidence, isEmpty);
  });
  test(
    'unknown capture timestamp is preserved but never counted as valid',
    () async {
      h.picker.beforeReturn = () async {
        final files = await h.root
            .list()
            .where((f) => f is File && f.path.endsWith('.jpg'))
            .toList();
        await File(
          files.single.path,
        ).setLastModified(h.clock.utc.subtract(const Duration(days: 1)));
      };
      final id = await h.ready();
      final e = h.repo.get(id)!.evidence.single;
      expect(e.timeSource, HydrostaticCaptureTimeSource.unknown);
      expect(e.ready, isFalse);
      expect(await h.controller.startAvailable(id), isFalse);
    },
  );
  test(
    'STARTING without committed start is recovered as preparation without GPS',
    () async {
      final id = await h.ready();
      await h.repo.requestStart(id, uuid());
      await h.restart();
      expect(h.repo.get(id)!.state, HydrostaticTestState.preparation);
      expect(h.repo.get(id)!.attemptNumber, isNull);
      expect(h.gps.calls, 0);
    },
  );
  test(
    'recovered 5 bar image is pending without contemporaneous GPS',
    () async {
      final id = await h.ready();
      await h.controller.start(id);
      h.picker.throwAfter = true;
      await expectLater(
        h.controller.capturePhoto(id, HydrostaticEvidenceRole.manometer5Bar),
        throwsStateError,
      );
      h.picker.throwAfter = false;
      h.clock.advance(300000);
      await h.restart();
      expect(
        h.repo.get(id)!.evidence.last.state,
        HydrostaticEvidenceState.pendingMetadata,
      );
      expect(h.repo.get(id)!.evidence.last.location, isNull);
      expect(h.repo.get(id)!.state, HydrostaticTestState.active);
    },
  );
  for (final boundary in [
    'before:ready',
    'after:ready',
    'before:document',
    'after:document',
    'after:applied',
  ]) {
    test('finish interruption $boundary recovers one end timestamp', () async {
      final id = await h.ready();
      await h.controller.start(id);
      h.clock.advance(12000);
      var fail = true;
      h.store.fault = (point) async {
        if (fail &&
            point == boundary &&
            h.repo.journal.entries.any((e) => e['type'] == 'finish')) {
          fail = false;
          throw StateError('interrupted');
        }
      };
      await expectLater(h.controller.finish(id), throwsStateError);
      final commandAt = h.clock.utc;
      h.clock.advance(4000);
      await h.restart();
      if (h.repo.get(id)!.state == HydrostaticTestState.active) {
        await h.controller.finish(id);
      }
      final ended = h.repo.get(id)!;
      expect(ended.state, HydrostaticTestState.endedPendingResult);
      if (boundary != 'before:ready') expect(ended.endedAt, commandAt);
      final stored = ended.endedAt;
      await h.controller.finish(id);
      expect(h.repo.get(id)!.endedAt, stored);
    });
  }
}
