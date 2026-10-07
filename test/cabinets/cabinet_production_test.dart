import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:ddr001_levantamientos/domain/cabinets/cabinet_models.dart';
import 'package:ddr001_levantamientos/domain/construction/construction_models.dart';
import 'package:ddr001_levantamientos/features/home/home_page.dart';
import 'package:ddr001_levantamientos/core/security/session_store.dart';
import 'harness.dart';

class DeploymentRemote extends FakeCabinetRemote {
  int? unavailable;
  @override
  Future<Json> get(String path, [Json? query]) {
    if (path == '/catalog' && unavailable != null) {
      throw failure(unavailable!, 'NOT_AVAILABLE');
    }
    return super.get(path, query);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  late DeploymentRemote remote;
  setUp(() async {
    h = Harness();
    remote = DeploymentRemote();
    await h.open(environment: 'production', remote: remote);
  });
  tearDown(() => h.close());

  testWidgets('production resident sees registration and final review', (
    tester,
  ) async {
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: h.app),
          ChangeNotifierProvider.value(value: h.controller),
        ],
        child: const MaterialApp(home: HomePage()),
      ),
    );
    expect(find.text('REGISTRAR GABINETE'), findsOneWidget);
    expect(find.text('REVISIÓN DE HIDRANTE'), findsOneWidget);
  });

  test('production preserves role and identity restrictions', () async {
    expect(h.controller.allowed, isTrue);
    h.setRole(ConstructionRole.contractor);
    expect(h.controller.eligible, isFalse);
    expect(
      () => h.controller.scan('AQ26000017', 'A1', false),
      throwsStateError,
    );
    h.setRole(ConstructionRole.resident);
    h.app.session = testSession(kind: SessionKind.admin);
    expect(h.controller.eligible, isFalse);
    h.app.session = testSession(user: '22222222-2222-4222-8222-222222222222');
    expect(h.controller.eligible, isFalse);
  });

  for (final status in [404, 503]) {
    test(
      'production first access waits for backend $status then retries',
      () async {
        await h.store.authorize(h.controller.actor!, false);
        remote.unavailable = status;
        await h.controller.refresh();
        expect(h.controller.allowed, isFalse);
        expect(h.controller.message, contains('no está disponible'));
        expect(remote.calls, isEmpty);
        remote.unavailable = null;
        await h.controller.refresh();
        expect(h.controller.allowed, isTrue);
        expect(h.controller.message, isNull);
        final id = await h.controller.scan('AQ26000017', 'A1', false);
        await h.controller.synchronize(force: true);
        expect(h.store.read(id)!.pending, isEmpty);
        expect(remote.calls, hasLength(1));
      },
    );
  }

  test('backend unavailable preserves queued production work', () async {
    final id = await h.controller.scan('AQ26000017', 'A1', false);
    remote.unavailable = 503;
    await h.controller.refresh();
    expect(h.store.read(id)!.pending, hasLength(1));
    expect(h.controller.allowed, isTrue);
    expect(remote.calls, isEmpty);
    remote.unavailable = null;
    await h.controller.synchronize(force: true);
    expect(h.store.read(id)!.pending, isEmpty);
  });

  test(
    'production backend forbidden revokes cached access without deleting drafts',
    () async {
      final id = await h.controller.scan('AQ26000017', 'A1', false);
      remote.deny = true;
      await h.controller.refresh();
      expect(h.controller.allowed, isFalse);
      expect(h.store.read(id)!.pending, hasLength(1));
      expect(remote.calls, isEmpty);
    },
  );
}
