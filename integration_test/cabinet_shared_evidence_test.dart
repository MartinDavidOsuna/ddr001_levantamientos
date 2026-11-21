// Separate Android TEST package only; never replaces the field installation.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/main.dart' as application;
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_controller.dart';
import 'package:ddr001_levantamientos/features/cabinets/cabinet_pages.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'another resident reads remote evidence and cached originals in isolated TEST',
    (tester) async {
      final package = await PackageInfo.fromPlatform();
      expect(package.packageName, 'com.aquafim.ddr001levantamientos.test');
      expect(const String.fromEnvironment('APP_ENV'), 'test');
      expect(
        const String.fromEnvironment('API_BASE_URL'),
        'http://127.0.0.1:3003/api/v1',
      );
      final session = FieldSession.fromJson(
        object(jsonDecode(const String.fromEnvironment('CABINETS_QA_SESSION'))),
      );
      await SecureSessionStore().save(session);
      await application.main();
      for (
        var i = 0;
        i < 120 && find.text('REGISTRAR GABINETE').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.text('REGISTRAR GABINETE'), findsOneWidget);
      await tester.tap(find.text('REGISTRAR GABINETE'));
      await tester.pumpAndSettle();
      final controller = tester
          .element(find.byType(CabinetsPage))
          .read<CabinetController>();
      const uid = String.fromEnvironment('CABINETS_QA_UID');
      final id = await controller.scan(uid, 'A4', true);
      final record = controller.record(id);
      expect(record.server['status'], 'deliverable');
      expect(record.pending, isEmpty);
      await tester.enterText(find.byType(TextField).first, uid);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(displayUid(uid)).first);
      await tester.pumpAndSettle();
      // Opening a dossier must load its inventory without a manual download tap.
      for (
        var i = 0;
        i < 120 && controller.record(id).photos.length != 6;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(controller.record(id).photos.length, 6);
      expect(
        controller.record(id).photos.every((p) => p['actor'] != session.userId),
        true,
      );
      for (final photo in controller.record(id).photos) {
        expect(
          await controller.photoBytes(id, photo, original: true),
          isNotEmpty,
        );
      }
      final cached = controller.record(id).photos;
      expect(cached.every((p) => File(p['localPath']).existsSync()), true);
      controller.app.online = false;
      for (final photo in cached) {
        expect(
          await controller.photoBytes(id, photo, original: true),
          isNotEmpty,
        );
      }
      expect(controller.record(id).pending, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
