import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ddr001_levantamientos/core/hydrostatic/hydrostatic_sync_runner.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync_api.dart';
import 'package:ddr001_levantamientos/data/hydrostatic/hydrostatic_sync_store.dart';
import 'package:ddr001_levantamientos/features/hydrostatic/hydrostatic_pages.dart';
import 'ui_harness.dart';
import 'ui_widgets_test.dart' as widgets;
import 'sync_test.dart' show FakeHydroRemote;

void main() {
  widgets.localWidgetTest(
    'outbox opening failure preserves local capture and can retry',
    (tester) async {
      final h = UiHarness();
      await h.open();
      final id = await h.active();
      h.controller.initializeSync = () async {
        throw const FileSystemException('synthetic disk full');
      };
      await widgets.open(tester, h, page: HydrostaticDetailPage(id: id));
      expect(h.controller.ready, true);
      expect(h.repo.get(id)!.attemptNumber, 1);
      expect(find.textContaining('Outbox no disponible'), findsOneWidget);
      expect(find.text('REINTENTAR SINCRONIZACIÓN'), findsOneWidget);
      var calls = 0;
      h.controller.initializeSync = () async {
        calls++;
      };
      await tester.tap(find.text('REINTENTAR SINCRONIZACIÓN'));
      await widgets.settle(tester);
      expect(calls, 1);
      expect(h.controller.syncSetupError, null);
      await tester.pumpWidget(const SizedBox.shrink());
      await h.close();
    },
  );

  widgets.localWidgetTest(
    'detail retry updates durable receipt and keeps local evidence warning',
    (tester) async {
      final h = UiHarness();
      await h.open();
      final id = await h.passed();
      final box = await HydrostaticSyncStore.open(
        Directory('${h.root.path}/sync'),
      );
      bool online = false;
      final sync = HydrostaticSync(
        repository: h.repo,
        store: box,
        remote: FakeHydroRemote(),
        identity: () => HydrostaticSyncIdentity(
          h.access.actor.userId,
          h.access.actor.sessionId,
          h.access.actor.deviceInstallationId,
        ),
        verifySession: () async {},
        online: () => online,
        enabled: true,
        now: () => h.clock.utc,
      );
      h.controller.attachSync(sync);
      await widgets.open(tester, h, page: HydrostaticDetailPage(id: id));
      await sync.run();
      await widgets.settle(tester);
      expect(
        find.text('Documento pendiente de envío · fotos locales'),
        findsOneWidget,
      );
      online = true;
      await tester.tap(find.text('REINTENTAR / RECUPERAR RECIBO'));
      await widgets.settle(tester);
      expect(
        find.text(
          'Documento recibido · fotos e historial pendientes de transferencia',
        ),
        findsOneWidget,
      );
      expect(find.text('APROBADO'), findsOneWidget);
      expect(box.read(id)!['active'], null);
      expect(h.controller.canDelete(id), false);
      await tester.pumpWidget(const SizedBox.shrink());
      await box.close();
      await h.close();
    },
  );
  widgets.localWidgetTest(
    'automatic runner handles startup reconnect source writes and resume',
    (tester) async {
      final h = UiHarness();
      await h.open();
      final id = await h.active();
      final box = await HydrostaticSyncStore.open(
        Directory('${h.root.path}/sync'),
      );
      final remote = FakeHydroRemote();
      final events = StreamController<void>.broadcast();
      bool online = false;
      final sync = HydrostaticSync(
        repository: h.repo,
        store: box,
        remote: remote,
        identity: () => HydrostaticSyncIdentity(
          h.access.actor.userId,
          h.access.actor.sessionId,
          h.access.actor.deviceInstallationId,
        ),
        verifySession: () async {},
        online: () => online,
        enabled: true,
        now: () => h.clock.utc,
      );
      final runner = HydrostaticSyncRunner(
        sync,
        connectivityChanges: events.stream,
      )..start();
      Future<void> waitFor(bool Function() done) async {
        for (var n = 0; n < 200 && !done(); n++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(done(), true);
      }

      try {
        await waitFor(() => box.read(id)?['active'] != null);
        expect(remote.requests, isEmpty);
        online = true;
        events.add(null);
        await waitFor(() => box.read(id)?['serverVersion'] == 1);
        h.clock.advance(1000);
        await h.repo.finish(id, 'b0000000-0000-4000-8000-000000000001');
        await waitFor(() => box.read(id)?['serverVersion'] == 2);
        online = false;
        await h.repo.answerLeaks(
          id,
          'b0000000-0000-4000-8000-000000000002',
          true,
        );
        await waitFor(() => box.read(id)?['active'] != null);
        online = true;
        runner.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await waitFor(() => box.read(id)?['serverVersion'] == 3);
        expect(remote.requests, hasLength(3));
      } finally {
        runner.dispose();
        await events.close();
        sync.dispose();
        await box.close();
        await h.close();
      }
    },
  );
}
