import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'consistency_test.dart' show syntheticUid;
import 'harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reading 22 synthetic dossiers preserves raw documents and photo bytes; '
      'detached snapshot retains pending payloads and receipts', () async {
    final h = Harness();
    final remote = FakeCabinetRemote();
    await h.open(remote: remote);
    try {
      for (var n = 1; n <= 22; n++) {
        await h.controller.scan(syntheticUid(n + 100), 'A1', false);
      }
      final first = h.store.all().first;
      final photo = await h.photo(first.id, 'registration');
      final original = File(photo['localPath'] as String);
      final photoHash = sha256.convert(await original.readAsBytes()).toString();
      final states = ['queued', 'sending', 'done', 'conflict'];
      for (var n = 0; n < 22; n++) {
        final record = h.store.all()[n];
        final value = clone(record.json);
        final operations = objects(value['operations']);
        operations.first['state'] = states[n % states.length];
        if (operations.first['state'] == 'done') {
          operations.first['result'] = {'cabinet': clone(record.working)};
        }
        value['operations'] = operations;
        await h.store.save(value);
      }
      final before = Map<dynamic, String>.from(h.store.box.toMap());
      final records = h.store.all();
      final detached = jsonEncode(records.map((r) => r.json).toList());
      expect(records.length, 22);
      expect(h.store.box.toMap(), before);
      expect(
        sha256.convert(await original.readAsBytes()).toString(),
        photoHash,
      );
      expect(remote.calls, isEmpty);
      final decoded = (jsonDecode(detached) as List)
          .map((j) => CabinetRecord(object(j)))
          .toList();
      expect(
        decoded.map((r) => r.json).toList(),
        records.map((r) => r.json).toList(),
      );
      expect(
        decoded.where((r) => r.operations.first['state'] == 'sending').length,
        6,
      );
      expect(
        decoded.where((r) => r.operations.first['state'] == 'conflict').length,
        5,
      );
      expect(
        decoded.every(
          (r) => object(r.operations.first['body'])['operationId'] != null,
        ),
        isTrue,
      );
      // This verifies detached synthetic documents, not a physical Pixel backup.
      expect(decoded.first.photos.single['localPath'], photo['localPath']);
    } finally {
      await h.close();
    }
  });
}
