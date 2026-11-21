import 'dart:async';
import 'package:ddr001_levantamientos/data/cabinets/cabinet_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/features/cabinets/legacy_recovery_page.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'harness.dart';
import 'legacy_recovery_test.dart' show LegacyRemote, pilotId;

// Hold close at a deterministic boundary instead of assuming Hive finishes in 100 ms.
class _MetricsGuardController extends CabinetController {
  _MetricsGuardController({
    required super.app,
    required super.store,
    required super.remote,
    required super.camera,
  });

  final closeEntered = Completer<void>();
  final allowClose = Completer<void>();
  late Future<void> closing;
  int refreshRequests = 0, syncRequests = 0;

  @override
  Future<void> refresh() {
    refreshRequests++;
    return super.refresh();
  }

  @override
  Future<void> synchronize({bool force = false}) {
    syncRequests++;
    return super.synchronize(force: force);
  }

  @override
  Future<void> endLegacySupport(Object token) {
    closing = _finishClosing(token);
    closeEntered.complete();
    return closing;
  }

  Future<void> _finishClosing(Object token) async {
    await allowClose.future;
    await super.endLegacySupport(token);
  }
}

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
  testWidgets('metrics action copies only safe text and never requests network', (
    tester,
  ) async {
    final original = h.controller;
    // These completion futures must live in the real I/O zone, not fakeAsync.
    final guard = (await tester.runAsync(
      () async => _MetricsGuardController(
        app: h.app,
        store: h.store,
        remote: remote,
        camera: original.camera,
      ),
    ))!;
    original.dispose();
    h.controller = guard;
    final cabinetBefore = h.store.box.get('cabinet:$pilotId');
    final mediaQueueBefore = h.store.media.queueBox.toMap();
    final mediaJournalBefore = h.store.media.journalBox.toMap();
    final baseQueueBefore = h.app.local.queueBox.toMap();
    final baseJournalBefore = h.app.local.journalBox.toMap();
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
      await tester.tap(find.widgetWithText(FilledButton, 'Preparar'));
      // Wait for the actual ready state. Yield real event turns for Hive/filesystem
      // completions; advancing fake frame time cannot finish that I/O.
      do {
        await Future<void>(() {});
        await tester.pump();
      } while (find.byType(LinearProgressIndicator).evaluate().isNotEmpty);
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
    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold)),
    ).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Cerrar soporte'));
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(TextButton, 'Cerrar soporte'));
      await tester.pumpAndSettle();
      expect(find.text('Finalizar soporte'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Cerrar soporte'));
      await tester.pump();
      await guard.closeEntered.future;
      // Closing has started but cannot release the lease until explicitly allowed.
      expect(h.controller.supportHeld, isTrue);
      guard.allowClose.complete();
      // This is the same Future awaited by the production close action,
      // including Hive.put/flush, not a fixed delay or a settled animation.
      await guard.closing;
    });
    await tester.pumpAndSettle();
    expect(h.controller.supportHeld, false);
    expect(guard.refreshRequests, 0);
    expect(guard.syncRequests, 0);
    expect(remote.traces, isEmpty);
    expect(remote.calls, isEmpty);
    expect(remote.uploads, isEmpty);
    expect(h.store.box.get('cabinet:$pilotId'), cabinetBefore);
    expect(h.store.media.queueBox.toMap(), mediaQueueBefore);
    expect(h.store.media.journalBox.toMap(), mediaJournalBefore);
    expect(h.app.local.queueBox.toMap(), baseQueueBefore);
    expect(h.app.local.journalBox.toMap(), baseJournalBefore);
    await tester.pumpWidget(const SizedBox());
  });

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
