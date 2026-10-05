// Only run on a newly created dedicated TEST emulator. No production credentials.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/main.dart' as application;
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_controller.dart';
import 'package:ddr001_levantamientos/features/cabinets/cabinet_pages.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'dedicated TEST emulator opens live resident dossier and conserves offline copy',
    (tester) async {
      if (const String.fromEnvironment('APP_ENV') != 'test' ||
          const String.fromEnvironment('CABINETS_QA_DEVICE') !=
              'DDR001_Cabinets_TEST_20261005') {
        fail(
          'Refused: identify the dedicated TEST emulator and APP_ENV=test first.',
        );
      }
      final raw = object(
        jsonDecode(const String.fromEnvironment('CABINETS_QA_SESSION')),
      );
      await SecureSessionStore().save(FieldSession.fromJson(raw));
      await application.main();
      for (
        var attempt = 0;
        attempt < 120 && find.text('REGISTRAR GABINETE').evaluate().isEmpty;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.text('REGISTRAR GABINETE'), findsOneWidget);
      await tester.tap(find.text('REGISTRAR GABINETE'));
      await tester.pumpAndSettle();
      final element = tester.element(find.byType(CabinetsPage));
      final controller = element.read<CabinetController>();
      await controller.refresh();
      for (var attempt = 0; controller.refreshing && attempt < 240; attempt++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(controller.refreshing, isFalse, reason: controller.message);
      await tester.pumpAndSettle();
      expect(controller.allowed, isTrue);
      expect(find.text('Escanear gabinete'), findsOneWidget);
      final uid = const String.fromEnvironment('CABINETS_QA_UID');
      await tester.enterText(find.byType(TextField).first, uid);
      await tester.pumpAndSettle();
      final row = find.textContaining(displayUid(uid)).first;
      expect(row, findsOneWidget);
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.text('4 Revisión final'), findsOneWidget);
      final record = controller.records.firstWhere(
        (r) => r.working['uid'] == uid,
      );
      expect(record.server['status'], 'deliverable');
      await controller.downloadEvidence(record.id);
      await tester.pumpAndSettle();
      expect(controller.store.read(record.id)!.photos.length, 6);
      final localFiles = controller.store.read(record.id)!.photos;
      expect(
        localFiles.every((p) => File(p['localPath']).existsSync()),
        isTrue,
      );
      await tester.ensureVisible(find.text('4 Revisión final'));
      await tester.tap(find.text('4 Revisión final'));
      await tester.pumpAndSettle();
      expect(
        find.text('He consultado el expediente y su evidencia'),
        findsOneWidget,
      );
      await tester.pumpAndSettle();
      await binding.convertFlutterSurfaceToImage();
      await tester.pumpAndSettle();
      final image = await binding.takeScreenshot('cabinet-final-test');
      final folder = await getApplicationSupportDirectory();
      await File(
        '${folder.path}/cabinet-final-test.png',
      ).writeAsBytes(image, flush: true);
      // This real platform run validates navigation/Hive/media rendering, not camera/GNSS measurements.
    },
  );
}
