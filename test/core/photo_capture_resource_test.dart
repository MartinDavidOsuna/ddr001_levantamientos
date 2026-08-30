import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ddr001_levantamientos/core/media/photo_capture_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('streaming SHA-256 matches canonical digest for a field-sized file', () async {
    final root = await Directory.systemTemp.createTemp('ddr001-photo-digest-');
    addTearDown(() => root.delete(recursive: true));

    final file = File('${root.path}/evidence.jpg');
    final sink = file.openWrite();
    final block = List<int>.generate(64 * 1024, (index) => index & 0xff);
    for (var i = 0; i < 64; i++) {
      sink.add(block);
    }
    await sink.close();

    final expected = sha256.convert(await file.readAsBytes()).toString();
    final actual = await sha256File(file);

    expect(file.lengthSync(), 4 * 1024 * 1024);
    expect(actual, expected);
    expect(actual, hasLength(64));
  });
}
