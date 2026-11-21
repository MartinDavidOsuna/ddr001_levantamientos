import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/recovery_main.dart';

void main() {
  testWidgets(
    'no export or platform access before explicit consent; cancel is inert',
    (tester) async {
      var calls = 0;
      const channel = MethodChannel('ddr/cabinet_recovery');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        _,
      ) async {
        calls++;
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: CabinetRecoveryPage()));
      expect(calls, 0);
      await tester.tap(find.text('Preparar respaldo'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(calls, 0);
    },
  );
  test(
    'diagnostic source has no productive bootstrap and manifest denies network',
    () {
      final main = File('lib/recovery_main.dart').readAsStringSync();
      expect(main, isNot(contains("import 'main.dart'")));
      expect(main, isNot(contains('CabinetController')));
      final manifest = File(
        'android/app/src/recovery/AndroidManifest.xml',
      ).readAsStringSync();
      expect(
        manifest,
        contains('android.permission.INTERNET" tools:node="remove"'),
      );
      final activity = File(
        'android/app/src/recovery/kotlin/com/aquafim/ddr001levantamientos/RecoveryActivity.kt',
      ).readAsStringSync();
      expect(activity, isNot(contains('super.configureFlutterEngine')));
      expect(activity, contains('Intent.EXTRA_LOCAL_ONLY'));
    },
  );
}
