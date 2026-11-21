import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/features/cabinets/legacy_recovery_page.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'harness.dart';
import 'legacy_recovery_test.dart' show LegacyRemote, pilotId;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late LegacyRemote remote;
  setUp(() async {
    h = Harness();
    remote = LegacyRemote();
    await h.open(remote: remote);
    await h.store.save({
      'id': pilotId,
      'actor': h.controller.actor,
      'working': {'uid': 'AQ26000068', 'status': 'validated'},
      'server': {},
      'operations': [],
      'photos': [],
    });
  });
  tearDown(() async {
    await h.close();
  });
  testWidgets('support cancellation does not acquire hold or transmit', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: LegacyRecoveryPage(controller: h.controller)),
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AQ26-00006-8').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preparar recuperación'));
    await tester.pumpAndSettle();
    expect(find.text('Preparar soporte selectivo'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(h.controller.supportHeld, false);
    expect(remote.traces, isEmpty);
    expect(remote.calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'failed acquisition exposes pre-HTTP phase and retry without remote zero',
    (tester) async {
      final row = h.store.read(pilotId)!.json;
      row['actor'] = 'b3000000-0000-4000-8000-000000000001';
      await tester.runAsync(() => h.store.save(row));
      await tester.pumpWidget(
        MaterialApp(home: LegacyRecoveryPage(controller: h.controller)),
      );
      // Keep a known server snapshot so this synthetic dossier remains visible to the session.
      await tester.pumpWidget(const SizedBox());
      row['server'] = {'cabinetId': pilotId};
      await tester.runAsync(() => h.store.save(row));
      await tester.pumpWidget(
        MaterialApp(home: LegacyRecoveryPage(controller: h.controller)),
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AQ26-00006-8').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preparar recuperación'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preparar'));
      await tester.pumpAndSettle();
      expect(find.textContaining('SUPPORT_ACTOR_MISMATCH'), findsOneWidget);
      expect(find.textContaining('servidor no consultado'), findsOneWidget);
      expect(
        find.textContaining(
          'Coincidencias en inventario remoto: no consultado',
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Reintentar preparación'));
      await tester.tap(find.text('Reintentar preparación'));
      await tester.pumpAndSettle();
      expect(find.text('Preparar recuperación'), findsOneWidget);
      expect(remote.traces, isEmpty);
      expect(h.controller.supportHeld, false);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'metrics action copies only safe text and never requests network',
    (tester) async {
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await tester.pumpWidget(
        MaterialApp(home: LegacyRecoveryPage(controller: h.controller)),
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('AQ26-00006-8').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Medir fotografías · sin envío'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Medir fotografías · sin envío'));
        await tester.pumpAndSettle();
        expect(find.text('Medir fotografías locales'), findsOneWidget);
        await tester.tap(find.text('Preparar'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Copiar resumen técnico'));
      await tester.tap(find.text('Copiar resumen técnico'));
      await tester.pumpAndSettle();
      expect(copied, contains('Límite productivo NO CERTIFICADO'));
      expect(copied, isNot(contains(h.directory.path)));
      expect(copied, isNot(contains('accessToken')));
      expect(remote.traces, isEmpty);
      expect(remote.calls, isEmpty);
      expect(remote.uploads, isEmpty);
      final recover = find.widgetWithText(
        FilledButton,
        'Recuperar este gabinete',
      );
      await tester.ensureVisible(recover);
      expect(tester.widget<FilledButton>(recover).onPressed, isNull);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Cerrar soporte'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Cerrar soporte'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Cerrar soporte'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(h.controller.supportHeld, false);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('contractor cannot see preparation or transmit control', (
    tester,
  ) async {
    h.setRole(ConstructionRole.contractor);
    await tester.pumpWidget(
      MaterialApp(home: LegacyRecoveryPage(controller: h.controller)),
    );
    expect(
      find.text('Soporte no autorizado para esta sesión.'),
      findsOneWidget,
    );
    expect(find.text('Preparar recuperación'), findsNothing);
    expect(find.text('Recuperar este gabinete'), findsNothing);
    expect(remote.traces, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
