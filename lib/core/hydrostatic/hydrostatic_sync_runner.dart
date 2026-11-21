import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import '../../data/hydrostatic/hydrostatic_sync.dart';

/// Best effort only while this process is alive. Reopen/resume always scans
/// durable documents and the outbox; no background-execution promise.
class HydrostaticSyncRunner with WidgetsBindingObserver {
  HydrostaticSyncRunner(this.sync, {this.connectivityChanges});
  final Stream<dynamic>? connectivityChanges;
  final HydrostaticSync sync;
  Timer? _retry, _debounce;
  StreamSubscription<dynamic>? _network, _documents;
  void start() {
    WidgetsBinding.instance.addObserver(this);
    _network = (connectivityChanges ?? Connectivity().onConnectivityChanged)
        .listen((_) => kick());
    _documents = sync.repository.store.changes.listen((_) => kick());
    _retry = Timer.periodic(const Duration(seconds: 30), (_) => kick());
    kick();
  }

  void kick() {
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(sync.run()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) kick();
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retry?.cancel();
    _debounce?.cancel();
    unawaited(_network?.cancel());
    unawaited(_documents?.cancel());
  }
}
