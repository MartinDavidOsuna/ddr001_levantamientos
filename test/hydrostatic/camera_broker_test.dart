import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:ddr001_levantamientos/core/media/camera_capture_broker.dart';
import 'package:ddr001_levantamientos/core/media/photo_capture_service.dart';
import 'package:ddr001_levantamientos/core/persistence/local_store.dart';
import 'package:ddr001_levantamientos/core/persistence/construction_operation_journal.dart';
import 'package:hive_ce/hive.dart';
import 'execution_harness.dart';
import 'harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ExecutionHarness h;
  setUp(() async {
    h = ExecutionHarness();
    await h.open();
  });
  tearDown(() async => h.close());
  Future<Map<String, dynamic>?> take(String module, String id, String entity) =>
      h.broker.capture(
        id: id,
        module: module,
        entityId: entity,
        actorId: h.access.actor.userId,
        role: 'INITIAL_SETUP',
        requestedAt: h.clock.utc,
      );
  test(
    'durable intent exists before native camera and retains exact scope',
    () async {
      final id = uuid(), entity = uuid();
      h.picker.beforeReturn = () async {
        final row = jsonDecode(
          await File(
            '${h.root.path}/camera_dispatch_v1/$id.json',
          ).readAsString(),
        );
        expect(row['state'], 'PREPARED');
        expect(row['module'], 'hydrostatic');
        expect(row['entityId'], entity);
        expect(row['actorId'], h.access.actor.userId);
        expect(row['role'], 'INITIAL_SETUP');
      };
      final result = await take('hydrostatic', id, entity);
      expect(result!['sha256'], hasLength(64));
      expect(result['byteLength'], greaterThan(0));
      expect(await h.broker.result('construction', id), isNull);
      expect(await h.broker.result('cabinets', id), isNull);
      expect(await take('hydrostatic', id, entity), result);
      expect(h.picker.captures, 1);
    },
  );
  test(
    'global acquisition and recovery reject competitors until native return',
    () async {
      final gate = Completer<void>(), entered = Completer<void>();
      h.picker.beforeReturn = () async {
        entered.complete();
        await gate.future;
      };
      final capture = take('hydrostatic', uuid(), uuid());
      await entered.future;
      await expectLater(take('cabinets', uuid(), uuid()), throwsStateError);
      await expectLater(h.broker.recover(), throwsStateError);
      expect(h.picker.captures, 1);
      gate.complete();
      await capture;
    },
  );
  test(
    'unowned result preserved in quarantine, not delivered to caller',
    () async {
      final file = File('${h.root.path}/lost.jpg');
      await file.writeAsBytes([1, 2, 3], flush: true);
      h.picker.lost = [XFile(file.path)];
      await h.broker.recover();
      final rows = await h.broker.quarantined();
      expect(rows.length, 1);
      expect(await File(rows.single['originalPath']).readAsBytes(), [1, 2, 3]);
      expect(await h.broker.result('hydrostatic', rows.single['id']), isNull);
      expect(await file.exists(), isTrue);
    },
  );
  test(
    'multiple returned files remain ambiguous even with active pointer',
    () async {
      final id = uuid();
      h.picker.throwAfter = true;
      await expectLater(take('hydrostatic', id, uuid()), throwsStateError);
      final second = await File(
        h.picker.lost.single.path,
      ).copy('${h.root.path}/second.jpg');
      h.picker.lost.add(XFile(second.path));
      await h.broker.recover();
      expect(await h.broker.result('hydrostatic', id), isNull);
      expect((await h.broker.quarantined()).length, 3);
      expect(await second.exists(), isTrue);
    },
  );
  test(
    'restart with durable owner replays one result to original module only',
    () async {
      final id = uuid(), entity = uuid();
      h.picker.throwAfter = true;
      await expectLater(take('cabinets', id, entity), throwsStateError);
      final restarted = CameraCaptureBroker(
        picker: h.picker,
        supportDirectory: () => Future.value(h.root),
        now: () => h.clock.utc,
      );
      await restarted.recover();
      final row = await restarted.result('cabinets', id);
      expect(row!['entityId'], entity);
      expect(row['recovered'], isTrue);
      expect(await restarted.result('hydrostatic', id), isNull);
      final path = row['originalPath'];
      await restarted.recover();
      expect((await restarted.result('cabinets', id))!['originalPath'], path);
    },
  );
  test(
    'no lost response never assigns cache by proximity and cache remains durable',
    () async {
      final cache = Directory('${h.root.path}/cache');
      await cache.create();
      final file = File('${cache.path}/recent.jpg');
      await file.writeAsBytes([6, 7, 8], flush: true);
      await h.broker.preserveUnownedCache(cache);
      await h.broker.preserveUnownedCache(cache);
      final rows = await h.broker.quarantined();
      expect(rows.length, 1);
      expect(rows.single['reason'], 'UNOWNED_CACHE_FILE_NOT_ASSOCIATED');
      expect(await File(rows.single['originalPath']).readAsBytes(), [6, 7, 8]);
    },
  );
  for (final module in ['construction', 'cabinets']) {
    test(
      'legacy $module capture and interrupted recovery keep original contract',
      () async {
        final boxes = <Box<String>>[];
        for (var i = 0; i < 5; i++) {
          boxes.add(await Hive.openBox<String>('legacy_$i', path: h.root.path));
        }
        final local = LocalStore(
          boxes[0],
          boxes[1],
          boxes[2],
          boxes[3],
          boxes[4],
        );
        final service = PhotoCaptureService(
          local: local,
          broker: h.broker,
          directoryName: module,
          supportDirectory: () => Future.value(h.root),
          temporaryDirectory: () =>
              Future.value(Directory('${h.root.path}/unused')),
          representationBuilder: (source, upload, thumb) async {
            await source.copy(upload.path);
            await source.copy(thumb.path);
            return true;
          },
        );
        final entity = uuid();
        final first = await service.capture(
          surveyId: entity,
          actorId: h.access.actor.userId,
          step: 1,
        );
        expect(first!.surveyId, entity);
        expect(first.stepNumber, 1);
        expect(await File(first.localPath).exists(), isTrue);
        await service.advance(first.id, ConstructionJournalState.committed);
        h.picker.throwAfter = true;
        await expectLater(
          service.capture(
            surveyId: entity,
            actorId: h.access.actor.userId,
            step: 2,
          ),
          throwsStateError,
        );
        h.picker.throwAfter = false;
        final recovered = await service.recoverPendingCaptures();
        expect(recovered.length, 1);
        expect(recovered.single.stepNumber, 2);
        expect(recovered.single.surveyId, entity);
        expect(await File(first.localPath).exists(), isTrue);
        for (final b in boxes) {
          await b.close();
        }
      },
    );
  }
  test(
    'incomplete copied file is rejected then recovered without deleting source',
    () async {
      h.broker.fault = (point) async {
        if (point == 'after:copy') {
          final parts = await Directory('${h.root.path}/camera_dispatch_v1')
              .list(recursive: true)
              .where((e) => e.path.endsWith('original.part'))
              .toList();
          await File(parts.single.path).writeAsString('partial', flush: true);
        }
      };
      final id = uuid(), entity = uuid();
      await expectLater(take('hydrostatic', id, entity), throwsStateError);
      h.broker.fault = null;
      await h.broker.recover();
      expect(await h.broker.result('hydrostatic', id), isNotNull);
    },
  );
}
