import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import '../../data/cabinets/cabinet_controller.dart';
import '../../domain/cabinets/cabinet_models.dart';
import '../../domain/cabinets/cabinet_safety.dart';
import 'cabinet_safety_widgets.dart';
import '../../domain/construction/construction_models.dart' as bases;

final _cabinetActions = Expando<bool>();

Future<void> cabinetAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  if (_cabinetActions[context] == true) return;
  _cabinetActions[context] = true;
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(CabinetController.explain(e))));
    }
  } finally {
    _cabinetActions[context] = false;
  }
}

Widget cabinetDenied(CabinetController controller) => Scaffold(
  appBar: AppBar(title: const Text('Gabinetes')),
  body: Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            controller.eligible
                ? 'El primer acceso requiere conexión para comprobar permisos y descargar el catálogo.'
                : 'Acceso exclusivo para residentes Construction habilitados en TEST.',
          ),
          if (controller.message != null) Text(controller.message!),
          if (controller.eligible)
            CabinetBusyButton(
              onPressed: controller.refreshing ? null : controller.refresh,
              child: const Text('Conectar y descargar'),
            ),
        ],
      ),
    ),
  ),
);

class CabinetsPage extends StatefulWidget {
  const CabinetsPage({super.key, this.finalReview = false});
  final bool finalReview;
  @override
  State<CabinetsPage> createState() => _CabinetsPageState();
}

class _CabinetsPageState extends State<CabinetsPage> {
  String search = '', status = '', model = '';
  final searchText = TextEditingController();
  @override
  void dispose() {
    searchText.dispose();
    super.dispose();
  }

  int page = 1;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>();
    if (!c.allowed) return cabinetDenied(c);
    final records = c.records.where((r) {
      final w = r.working, installation = object(w['installation']);
      final base = c.app.visibleSurveys
          .where((b) => b.id == installation['baseId'])
          .firstOrNull;
      return (!widget.finalReview ||
              ['installed', 'deliverable'].contains(w['status'])) &&
          (status.isEmpty || w['status'] == status) &&
          (model.isEmpty ||
              '${w['model']}${w['automated'] == true ? '-A' : ''}' == model) &&
          '${w['uid']} ${displayUid(w['uid'])} ${installation['baseId']} ${base?.displayIdentifier} ${installation['accountNumber']}'
              .toLowerCase()
              .contains(search.toLowerCase());
    }).toList();
    final pages = (records.length / 25).ceil().clamp(1, 100000);
    final current = page.clamp(1, pages);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.finalReview ? 'Revisión de hidrante' : 'Registrar gabinete',
        ),
        actions: [
          IconButton(
            tooltip: 'Sincronización',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CabinetSyncPage()),
            ),
            icon: const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: 'Actualizar catálogo y expedientes',
            onPressed: c.refreshing ? null : c.refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (c.refreshing) const LinearProgressIndicator(),
          if (c.message != null)
            Padding(padding: const EdgeInsets.all(8), child: Text(c.message!)),
          if (!widget.finalReview)
            Padding(
              padding: const EdgeInsets.all(12),
              child: CabinetBusyButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const CabinetRegisterPage(),
                  ),
                ),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Escanear gabinete'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: searchText,
              decoration: const InputDecoration(
                labelText: 'Buscar UID, base o cuenta',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() {
                search = v;
                page = 1;
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('status-$status'),
                    isExpanded: true,
                    initialValue: status,
                    decoration: const InputDecoration(labelText: 'Estado'),
                    items:
                        [
                              '',
                              'draft',
                              'registered',
                              'incomplete',
                              'validated',
                              'installed',
                              'deliverable',
                            ]
                            .map(
                              (s) => DropdownMenuItem(
                                value: s,
                                child: Text(
                                  s.isEmpty ? 'Todos' : cabinetStatus(s),
                                ),
                              ),
                            )
                            .toList(),
                    onChanged: (v) => setState(() {
                      status = v!;
                      page = 1;
                    }),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('model-$model'),
                    isExpanded: true,
                    initialValue: model,
                    decoration: const InputDecoration(labelText: 'Modelo'),
                    items:
                        [
                              '',
                              'A1',
                              'A1-A',
                              'A2',
                              'A2-A',
                              'A3',
                              'A3-A',
                              'A4',
                              'A4-A',
                            ]
                            .map(
                              (s) => DropdownMenuItem(
                                value: s,
                                child: Text(s.isEmpty ? 'Todos' : s),
                              ),
                            )
                            .toList(),
                    onChanged: (v) => setState(() {
                      model = v!;
                      page = 1;
                    }),
                  ),
                ),
              ],
            ),
          ),
          if (search.isNotEmpty || status.isNotEmpty || model.isNotEmpty)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Text('Filtros activos'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    search = '';
                    status = '';
                    model = '';
                    page = 1;
                    searchText.clear();
                  }),
                  child: const Text('Limpiar filtros'),
                ),
              ],
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: c.refresh,
              child: ListView(
                children: [
                  if (records.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No hay expedientes para estos filtros. Sin conexión sólo se muestran los previamente descargados.',
                      ),
                    ),
                  for (final r in records.skip((current - 1) * 25).take(25))
                    Card(
                      child: ListTile(
                        title: Text(
                          '${displayUid(r.working['uid'])} · ${r.working['model']}${r.working['automated'] == true ? '-A' : ''}',
                        ),
                        subtitle: Text(
                          '${cabinetStatus(r.working['status'])}\n${r.synchronized ? 'Confirmado por servidor' : 'Guardado en este teléfono · pendiente'}',
                        ),
                        trailing: Icon(
                          r.synchronized
                              ? Icons.cloud_done
                              : Icons.cloud_upload_outlined,
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => CabinetDetailPage(
                              id: r.id,
                              initialTab: widget.finalReview ? 3 : 0,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: current > 1
                    ? () => setState(() => page = current - 1)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('$current / $pages · ${records.length} expedientes'),
              IconButton(
                onPressed: current < pages
                    ? () => setState(() => page = current + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class CabinetRegisterPage extends StatefulWidget {
  const CabinetRegisterPage({super.key});
  @override
  State<CabinetRegisterPage> createState() => _CabinetRegisterPageState();
}

class _CabinetRegisterPageState extends State<CabinetRegisterPage> {
  final uid = TextEditingController();
  String model = 'A1';
  bool automated = false, busy = false;
  @override
  void dispose() {
    uid.dispose();
    super.dispose();
  }

  Future<void> open(String raw) async {
    if (busy) return;
    setState(() => busy = true);
    await cabinetAction(context, () async {
      final id = await context.read<CabinetController>().scan(
        raw.trim(),
        model,
        automated,
      );
      if (mounted) {
        await Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(builder: (_) => CabinetDetailPage(id: id)),
        );
      }
    });
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>();
    if (!c.allowed) return cabinetDenied(c);
    return Scaffold(
      appBar: AppBar(title: const Text('Identificar gabinete')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Escanea el QR o escribe el UID de la placa. Una lectura repetida abre el expediente existente.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: uid,
            decoration: const InputDecoration(
              labelText: 'UID / URL QR',
              hintText: 'AQ26-00001-7',
              helperText:
                  'Lee la placa del gabinete. Un UID válido no garantiza que sea el gabinete correcto.',
              helperMaxLines: 3,
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: model,
            decoration: const InputDecoration(labelText: 'Modelo base'),
            items: [
              'A1',
              'A2',
              'A3',
              'A4',
            ].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
            onChanged: (v) => setState(() => model = v!),
          ),
          SwitchListTile(
            title: const Text('Incluye automatización'),
            subtitle: Text(automated ? '$model-A' : model),
            value: automated,
            onChanged: (v) => setState(() => automated = v),
          ),
          CabinetBusyButton.icon(
            onPressed: busy
                ? null
                : () async {
                    final raw = await Navigator.push<String>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CabinetScannerPage(),
                      ),
                    );
                    if (raw != null && mounted) {
                      uid.text = raw;
                      await open(raw);
                    }
                  },
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Abrir cámara QR'),
          ),
          TextButton(
            onPressed: busy ? null : () => open(uid.text),
            child: const Text('Continuar con UID escrito'),
          ),
          const Text(
            'Sin conexión, la unicidad global se comprobará al sincronizar. Para completar el registro se requiere fotografía de identificación.',
          ),
        ],
      ),
    );
  }
}

class CabinetScannerPage extends StatefulWidget {
  const CabinetScannerPage({super.key});
  @override
  State<CabinetScannerPage> createState() => _CabinetScannerPageState();
}

class _CabinetScannerPageState extends State<CabinetScannerPage>
    with WidgetsBindingObserver {
  final scanner = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool done = false;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !done &&
        context.read<CabinetController>().allowed) {
      unawaited(scanner.start());
    } else {
      unawaited(scanner.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(scanner.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>();
    if (!c.allowed) {
      unawaited(scanner.stop());
      return cabinetDenied(c);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Escanear QR')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: scanner,
              onDetect: (capture) {
                if (done) return;
                for (final barcode in capture.barcodes) {
                  final raw = barcode.rawValue;
                  if (raw == null) continue;
                  try {
                    cabinetUid(raw);
                    done = true;
                    unawaited(scanner.stop());
                    Navigator.pop(context, raw);
                    return;
                  } catch (e) {
                    setState(() => error = '$e');
                  }
                }
              },
            ),
          ),
          if (error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
        ],
      ),
    );
  }
}

class CabinetDetailPage extends StatelessWidget {
  const CabinetDetailPage({super.key, required this.id, this.initialTab = 0});
  final String id;
  final int initialTab;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>();
    if (!c.allowed) return cabinetDenied(c);
    CabinetRecord r;
    try {
      r = c.record(id);
    } catch (_) {
      return cabinetDenied(c);
    }
    return DefaultTabController(
      length: 4,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Text(displayUid(r.working['uid'])),
          actions: [
            IconButton(
              tooltip: 'Historial',
              icon: const Icon(Icons.history),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => CabinetHistoryPage(id: id)),
              ),
            ),
            IconButton(
              tooltip: 'Sincronización y conflictos',
              icon: const Icon(Icons.sync),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const CabinetSyncPage()),
              ),
            ),
          ],
          bottom: const TabBar(
            isScrollable: true,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: [
              Tab(text: '1 Registro'),
              Tab(text: '2 Piezas'),
              Tab(text: '3 Instalación'),
              Tab(text: '4 Revisión final'),
            ],
          ),
        ),
        body: Column(
          children: [
            Material(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: ListTile(
                isThreeLine: false,
                title: Text(
                  '${cabinetStatus(r.working['status'])} · ${r.working['model']}${r.working['automated'] == true ? '-A' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  r.synchronized
                      ? 'Confirmado por servidor · versión ${r.server['version']}'
                      : 'Guardado en este teléfono · ${r.pending.length} operaciones por enviar${r.json['dirty'] == true ? ' · borrador sin enviar' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (r.json['draftSavedAt'] != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Última captura local: ${cabinetCaptureDate(r.json['draftSavedAt'])}. Los campos se guardan automáticamente; usa el botón de cada etapa para enviarlos.',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (c.message != null) Text(c.message!),
            if (r.pending.any((o) => o['error'] != null))
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  '${r.pending.firstWhere((o) => o['error'] != null)['error']}',
                ),
              ),
            Expanded(
              child: TabBarView(
                children: [
                  CabinetRegistration(id: id),
                  CabinetParts(id: id),
                  CabinetInstallation(id: id),
                  CabinetFinalReview(id: id),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CabinetRegistration extends StatelessWidget {
  const CabinetRegistration({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>(), r = c.record(id);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Catálogo: ${r.working['catalogVersion']}'),
        const SizedBox(height: 12),
        EvidenceEditor(
          id: id,
          contextName: 'registration',
          readOnly: r.working['status'] != 'draft',
          value: objects(r.working['registrationEvidence']),
          onChanged: (v) => c.saveDraft(id, 'registrationEvidence', v),
        ),
        if (r.working['status'] == 'draft')
          CabinetBusyButton(
            onPressed: () => cabinetAction(context, () async {
              await c.flushDrafts();
              final evidence = objects(
                c.record(id).working['registrationEvidence'],
              );
              if (evidence.isEmpty) {
                throw StateError(
                  'Falta fotografía de identificación confirmada.',
                );
              }
              if (!context.mounted ||
                  !await confirmCabinetAction(
                    context,
                    title: 'Confirmar identificación',
                    message:
                        '${cabinetIdentity(c, id)}\n\nComprueba la placa física y la foto de identificación. El dígito verificador no identifica por sí solo el gabinete correcto.',
                    confirm: 'Corresponde a este gabinete',
                  )) {
                return;
              }
              await c.enqueue(id, 'registration_close', {'evidence': evidence});
            }),
            child: const Text('Completar registro local'),
          ),
        if (r.working['status'] != 'draft')
          CabinetBusyButton(
            onPressed: () => cabinetAction(context, () async {
              final value = await showDialog<Json>(
                context: context,
                builder: (_) => CabinetModelDialog(id: id),
              );
              if (value != null && context.mounted) {
                await c.enqueue(id, 'identity_correct', value);
              }
            }),
            child: const Text('Corregir modelo / automatización'),
          ),
      ],
    );
  }
}

class EvidenceEditor extends StatelessWidget {
  const EvidenceEditor({
    super.key,
    required this.id,
    required this.contextName,
    required this.value,
    required this.onChanged,
    this.serial = false,
    this.readOnly = false,
  });
  final String id, contextName;
  final List<Json> value;
  final Future<void> Function(List<Json>) onChanged;
  final bool serial, readOnly;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>(), r = c.record(id);
    final photos = r.photos
        .where(
          (p) => [
            contextName,
            'correction',
          ].contains(object(p['metadata'])['context']),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: (c.capturing || readOnly)
                  ? null
                  : () => cabinetAction(context, () async {
                      final before = c
                          .record(id)
                          .photos
                          .map((p) => p['id'])
                          .toSet();
                      await c.capture(id, contextName);
                      final captured = c
                          .record(id)
                          .photos
                          .where((p) => !before.contains(p['id']))
                          .firstOrNull;
                      if (captured == null || !context.mounted) return;
                      if (object(captured['metadata'])['accuracy'] == null) {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                CabinetPhotoPage(id: id, photo: captured),
                          ),
                        );
                        return;
                      }
                      final confirmed = await Navigator.push<bool>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CabinetEvidenceReview(
                            id: id,
                            photo: captured,
                            serial: serial,
                          ),
                        ),
                      );
                      if (confirmed == true && context.mounted) {
                        await onChanged([
                          ...value,
                          {
                            'photoId': captured['id'],
                            'confirmed': true,
                            if (serial) 'legible': true,
                          },
                        ]);
                      }
                    }),
              icon: const Icon(Icons.camera_alt),
              label: const Text('Tomar fotografía'),
            ),
            TextButton(
              onPressed: () =>
                  cabinetAction(context, () => c.downloadEvidence(id)),
              child: const Text('Descargar evidencia remota'),
            ),
          ],
        ),
        Text(
          '${value.length} fotografías relacionadas. Una misma foto puede respaldar varias piezas.',
        ),
        for (final p in photos)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            secondary: GestureDetector(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CabinetPhotoPage(id: id, photo: p),
                ),
              ),
              child: SizedBox(
                width: 56,
                height: 56,
                child: FutureBuilder(
                  builder: (context, snapshot) => snapshot.hasData
                      ? Image.memory(snapshot.data!, fit: BoxFit.cover)
                      : const Icon(Icons.image_not_supported_outlined),
                  future: c.photoBytes(id, p),
                ),
              ),
            ),
            title: Text(
              '${p['verified'] == true ? 'Archivo verificado' : 'Guardada localmente'} · ${cabinetCaptureDate(object(p['metadata'])['capturedAt'])}',
            ),
            subtitle: Text(
              object(p['metadata'])['accuracy'] == null
                  ? 'GPS pendiente; conserva esta foto y toma otra con GPS'
                  : serial
                  ? 'Confirmo placa legible y correspondencia con esta serie'
                  : 'Confirmo que documenta este punto',
            ),
            value: value.any((e) => e['photoId'] == p['id']),
            onChanged: readOnly || object(p['metadata'])['accuracy'] == null
                ? null
                : (checked) => cabinetAction(context, () async {
                    if (checked == true) {
                      final ok = await Navigator.push<bool>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => CabinetEvidenceReview(
                            id: id,
                            photo: p,
                            serial: serial,
                          ),
                        ),
                      );
                      if (ok != true || !context.mounted) return;
                    }
                    await onChanged([
                      ...value.where((e) => e['photoId'] != p['id']),
                      if (checked == true)
                        {
                          'photoId': p['id'],
                          'confirmed': true,
                          if (serial) 'legible': true,
                        },
                    ]);
                  }),
          ),
      ],
    );
  }
}

class CabinetParts extends StatefulWidget {
  const CabinetParts({super.key, required this.id});
  final String id;
  @override
  State<CabinetParts> createState() => _CabinetPartsState();
}

class _CabinetPartsState extends State<CabinetParts> {
  String get id => widget.id;
  String? selectedGroup;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>(),
        r = c.record(id),
        w = r.working;
    if (w['status'] == 'draft') {
      return const Center(
        child: Text('Completa primero el registro con identificación.'),
      );
    }
    final definitions = objects(w['partDefinitions']);
    final groups = <String, List<Json>>{};
    for (final p in definitions) {
      final group = '${p['position']}'.split('.').first;
      (groups[group] ??= []).add(p);
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '${definitions.length} piezas · ${partsPending(w).length} pendientes',
        ),
        for (final warning in duplicateSerialWarnings(w))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(warning),
          ),
        Wrap(
          children: [
            for (final group in groups.entries)
              if (partsPending(
                w,
              ).any((p) => group.value.any((d) => d['code'] == p['subject'])))
                TextButton(
                  onPressed: () => setState(() => selectedGroup = group.key),
                  child: Text(
                    'Revisar pendientes: ${partGroupLabel(group.key)}',
                  ),
                ),
            if (selectedGroup != null)
              TextButton(
                onPressed: () => setState(() => selectedGroup = null),
                child: const Text('Ver todas las piezas'),
              ),
          ],
        ),
        for (final group in groups.entries.where(
          (g) => selectedGroup == null || selectedGroup == g.key,
        ))
          Card(
            child: ExpansionTile(
              key: ValueKey('${group.key}-$selectedGroup'),
              initiallyExpanded: selectedGroup == group.key,
              title: Text(partGroupLabel(group.key)),
              subtitle: Text('${group.value.length} instancias'),
              children: [
                for (final definition in group.value)
                  Builder(
                    builder: (context) {
                      final p =
                          objects(w['parts'])
                              .where((p) => p['code'] == definition['code'])
                              .firstOrNull ??
                          <String, dynamic>{
                            'code': definition['code'],
                            'present': null,
                            'evidence': <Json>[],
                          };
                      Future<void> update(String key, Object? value) =>
                          c.patchPart(id, '${p['code']}', {key: value});
                      return Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${definition['description']} · ${definition['code']}',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            for (final pending in partsPending(
                              w,
                            ).where((p) => p['subject'] == definition['code']))
                              Text(
                                '${pending['reason']}',
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            SegmentedButton<bool>(
                              emptySelectionAllowed: true,
                              segments: const [
                                ButtonSegment(
                                  value: true,
                                  label: Text('Presente'),
                                ),
                                ButtonSegment(
                                  value: false,
                                  label: Text('Faltante'),
                                ),
                              ],
                              selected: p['present'] == null
                                  ? {}
                                  : {p['present'] as bool},
                              onSelectionChanged: (s) =>
                                  update('present', s.firstOrNull),
                            ),
                            if (definition['serial'] != 'none') ...[
                              TextFormField(
                                key: ValueKey(
                                  '${definition['code']}-serial-${p['serialException']}',
                                ),
                                maxLength: 180,
                                autocorrect: false,
                                enableSuggestions: false,
                                enabled: p['serialException'] == null,
                                initialValue: p['serial'],
                                decoration: InputDecoration(
                                  labelText: definition['serial'] == 'required'
                                      ? 'Serie obligatoria'
                                      : 'Serie opcional',
                                  helperText:
                                      'Copia la placa; conserva ceros iniciales. Revisa 0/O y 1/I.',
                                  helperMaxLines: 3,
                                ),
                                onChanged: (v) =>
                                    c.patchPart(id, '${p['code']}', {
                                      'serial': normalizeSerial(v).isEmpty
                                          ? null
                                          : normalizeSerial(v),
                                      'serialException': null,
                                    }),
                              ),
                              DropdownButtonFormField<String>(
                                key: ValueKey(
                                  '${definition['code']}-${p['serialException']}',
                                ),
                                initialValue: p['serialException'] ?? '',
                                decoration: const InputDecoration(
                                  labelText: 'Serie pendiente',
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: '',
                                    child: Text('Sin excepción'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'illegible',
                                    child: Text('Ilegible'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'unavailable',
                                    child: Text('No disponible'),
                                  ),
                                ],
                                onChanged: (v) =>
                                    c.patchPart(id, '${p['code']}', {
                                      'serialException': v == '' ? null : v,
                                      if (v != '') 'serial': null,
                                    }),
                              ),
                              if (p['serialException'] != null)
                                TextFormField(
                                  maxLength: 2000,
                                  validator: reasonError,
                                  autovalidateMode:
                                      AutovalidateMode.onUserInteraction,
                                  initialValue: p['reason'],
                                  decoration: const InputDecoration(
                                    labelText: 'Motivo de serie pendiente',
                                  ),
                                  onChanged: (v) => update('reason', v),
                                ),
                            ],
                            TextFormField(
                              initialValue: p['observations'],
                              decoration: const InputDecoration(
                                labelText: 'Observación',
                              ),
                              onChanged: (v) => update('observations', v),
                            ),
                            EvidenceEditor(
                              id: id,
                              contextName: 'parts_validation',
                              serial: (p['serial'] ?? '').toString().isNotEmpty,
                              value: objects(p['evidence']),
                              onChanged: (v) => update('evidence', v),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        _CorrectionReason(id: id),
        CabinetBusyButton(
          onPressed: () => cabinetAction(context, () async {
            await c.flushDrafts();
            final now = c.record(id).working;
            final warnings = duplicateSerialWarnings(now);
            if (warnings.isNotEmpty &&
                (!context.mounted ||
                    !await confirmCabinetAction(
                      context,
                      title: 'Revisar series repetidas',
                      message:
                          '${cabinetIdentity(c, id)}\n\n${warnings.join('\n')}',
                      confirm: 'Comprobé las placas',
                    ))) {
              return;
            }
            await c.enqueue(id, 'parts_save', {
              'parts': objects(now['parts']),
              if (now['correctionReason'] != null)
                'reason': now['correctionReason'],
            });
            await c.enqueue(id, 'parts_validate', {});
          }),
          child: const Text('Guardar y validar piezas'),
        ),
        const Text(
          'Faltantes, series obligatorias o evidencia pendientes mantienen el expediente Incompleto.',
        ),
      ],
    );
  }
}

class _CorrectionReason extends StatelessWidget {
  const _CorrectionReason({required this.id});
  final String id;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>(), w = c.record(id).working;
    if (!['installed', 'deliverable'].contains(w['status'])) {
      return const SizedBox.shrink();
    }
    return TextFormField(
      maxLength: 2000,
      validator: reasonError,
      autovalidateMode: AutovalidateMode.onUserInteraction,
      initialValue: w['correctionReason'],
      decoration: const InputDecoration(
        labelText: 'Motivo de corrección (obligatorio)',
      ),
      onChanged: (v) => c.saveDraft(id, 'correctionReason', v),
    );
  }
}

class CabinetInstallation extends StatefulWidget {
  const CabinetInstallation({super.key, required this.id});
  final String id;
  @override
  State<CabinetInstallation> createState() => _CabinetInstallationState();
}

class _CabinetInstallationState extends State<CabinetInstallation> {
  String? expandedGroup;
  final accountText = TextEditingController();
  String? accountBase;
  @override
  void dispose() {
    accountText.dispose();
    super.dispose();
  }

  Future<void> update(CabinetController c, String key, Object? value) =>
      c.patchInstallation(widget.id, key, value);

  Future<void> answer(CabinetController c, Json value) => c.patchInstallation(
    widget.id,
    'answers',
    value,
    answerCode: '${value['code']}',
  );

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>(),
        r = c.record(widget.id),
        w = r.working;
    if (w['partsValidated'] != true) {
      return const Center(
        child: Text('Completa y valida las piezas antes de instalar.'),
      );
    }
    final catalog = c.catalogFor(r), install = object(w['installation']);
    final questions = catalog.applicable(w),
        pending = installationPending(w, catalog);
    final base = c.app.visibleSurveys
        .where((b) => b.id == install['baseId'])
        .firstOrNull;
    if (accountBase != '${install['baseId']}') {
      accountBase = '${install['baseId']}';
      accountText.text = '${install['accountNumber'] ?? ''}';
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        OutlinedButton.icon(
          onPressed: () async {
            final selected = await Navigator.push<bases.BaseSurvey>(
              context,
              MaterialPageRoute(builder: (_) => const CabinetBasePicker()),
            );
            if (selected != null && context.mounted) {
              final ok = await confirmCabinetAction(
                context,
                title: 'Confirmar base',
                message:
                    '${cabinetIdentity(c, widget.id)}\n\nBase elegida: ${selected.displayIdentifier}\nCuenta: ${selected.accountNumber ?? 'sin cuenta'}\nCoordenadas: ${selected.canonicalLocation?.latitude ?? 'sin dato'}, ${selected.canonicalLocation?.longitude ?? 'sin dato'}',
                confirm: 'Usar esta base',
              );
              if (!ok) return;
              await update(c, 'baseId', selected.id);
              await update(c, 'accountNumber', selected.accountNumber);
              await update(c, 'accountResolution', null);
            }
          },
          icon: const Icon(Icons.foundation),
          label: Text(
            base == null
                ? 'Seleccionar base aceptada / entregada'
                : 'Base: ${base.displayIdentifier}',
          ),
        ),
        if (base != null)
          Text(
            'Ubicación de base: ${base.canonicalLocation?.latitude ?? 'sin dato'}, ${base.canonicalLocation?.longitude ?? 'sin dato'}',
          ),
        Text(
          'GPS de instalación: ${object(install['gps'])['latitude'] ?? 'pendiente'}, ${object(install['gps'])['longitude'] ?? 'pendiente'} · precisión ${object(install['gps'])['accuracy'] ?? '—'} m\nCaptura: ${w['installationGpsAt'] ?? '—'}',
        ),
        OutlinedButton(
          onPressed: () => cabinetAction(context, () async {
            final gps = await c.installationGps();
            final at = gps.remove('capturedAt');
            await c.saveDraft(widget.id, 'installationGpsAt', at);
            await update(c, 'gps', gps);
          }),
          child: const Text('Capturar GPS propio de instalación'),
        ),
        if (!freshInstallationGps(w['installationGpsAt'], DateTime.now()))
          const Text(
            'GPS pendiente o antiguo. Captura una ubicación actual antes de guardar.',
          ),
        for (final warning in installationWarnings(c, widget.id))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(warning),
          ),
        TextFormField(
          maxLength: 50,
          autocorrect: false,
          enableSuggestions: false,
          controller: accountText,
          decoration: const InputDecoration(
            labelText: 'Cuenta de la base (opcional)',
            helperText:
                'No escribas aquí la serie del equipo. Conserva los ceros iniciales.',
            helperMaxLines: 2,
          ),
          onChanged: (v) =>
              update(c, 'accountNumber', v.trim().isEmpty ? null : v.trim()),
        ),
        if (base != null &&
            (install['accountNumber'] != base.accountNumber ||
                install['accountResolution'] != null)) ...[
          const Text(
            'La cuenta difiere de la base. Elige y explica la resolución; la base no se modificará.',
          ),
          DropdownButtonFormField<String>(
            initialValue: object(install['accountResolution'])['decision'],
            decoration: const InputDecoration(labelText: 'Resolución'),
            items: const [
              DropdownMenuItem(
                value: 'use_base',
                child: Text('Usar cuenta de base'),
              ),
              DropdownMenuItem(
                value: 'use_cabinet',
                child: Text('Usar cuenta del gabinete'),
              ),
              DropdownMenuItem(value: 'no_account', child: Text('Sin cuenta')),
            ],
            onChanged: (v) async {
              await update(c, 'accountResolution', {
                ...object(install['accountResolution']),
                'decision': v,
              });
              if (v == 'use_base') {
                accountText.text = base.accountNumber ?? '';
                await update(c, 'accountNumber', base.accountNumber);
              }
              if (v == 'no_account') await update(c, 'accountNumber', null);
            },
          ),
          TextFormField(
            maxLength: 2000,
            validator: reasonError,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            initialValue: object(install['accountResolution'])['reason'],
            decoration: const InputDecoration(
              labelText: 'Motivo de discrepancia',
            ),
            onChanged: (v) => update(c, 'accountResolution', {
              ...object(install['accountResolution']),
              'reason': v,
            }),
          ),
        ],
        Text(
          '${pending.where((p) => p['classification'] == 'blocking').length} bloqueos · ${pending.where((p) => p['classification'] == 'minor').length} observaciones menores · ${pending.where((p) => p['classification'] == 'mandatory_test').length} pruebas pendientes',
        ),
        Wrap(
          children: [
            for (final group in cabinetGroups.entries)
              if (pending.any(
                (p) => questions.any(
                  (q) => q['code'] == p['subject'] && q['group'] == group.key,
                ),
              ))
                TextButton(
                  onPressed: () => setState(() => expandedGroup = group.key),
                  child: Text(
                    '${group.value}: ${pending.where((p) => questions.any((q) => q['code'] == p['subject'] && q['group'] == group.key)).length} pendientes',
                  ),
                ),
            if (expandedGroup != null)
              TextButton(
                onPressed: () => setState(() => expandedGroup = null),
                child: const Text('Ver todos los bloques'),
              ),
          ],
        ),
        for (final group in cabinetGroups.entries)
          Builder(
            builder: (context) {
              if (expandedGroup != null && expandedGroup != group.key) {
                return const SizedBox.shrink();
              }
              final qs = questions
                  .where((q) => q['group'] == group.key)
                  .toList();
              if (qs.isEmpty) return const SizedBox.shrink();
              final count = qs
                  .where((q) => !pending.any((p) => p['subject'] == q['code']))
                  .length;
              return Card(
                child: ExpansionTile(
                  key: ValueKey('${group.key}-${expandedGroup == group.key}'),
                  initiallyExpanded: expandedGroup == group.key,
                  title: Text(group.value),
                  subtitle: Text('$count / ${qs.length} sin pendientes'),
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        'Comprueba y responde cada punto individualmente. Los puntos sin respuesta quedan pendientes.',
                      ),
                    ),
                    for (final q in qs)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: q['kind'] == 'evidence'
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${q['code']} · ${q['label']}'),
                                  EvidenceEditor(
                                    id: widget.id,
                                    contextName: 'installation',
                                    value: objects(
                                      object(install['evidence'])[q['code']],
                                    ),
                                    onChanged: (v) => update(c, 'evidence', {
                                      ...object(
                                        object(
                                          c
                                              .record(widget.id)
                                              .working['installation'],
                                        )['evidence'],
                                      ),
                                      q['code']: v,
                                    }),
                                  ),
                                ],
                              )
                            : CabinetAnswerEditor(
                                id: widget.id,
                                question: q,
                                value:
                                    objects(install['answers'])
                                        .where((a) => a['code'] == q['code'])
                                        .firstOrNull ??
                                    {'code': q['code'], 'evidence': <Json>[]},
                                onChanged: (v) => answer(c, v),
                              ),
                      ),
                  ],
                ),
              );
            },
          ),
        if (catalog.questions.any((q) => q['automatedOnly'] == true) &&
            w['automated'] != true)
          const Text(
            'Automatización: No aplica, derivado del modelo manual y del catálogo de este expediente.',
          ),
        TextFormField(
          initialValue: install['observations'],
          decoration: const InputDecoration(
            labelText: 'Observaciones de instalación',
          ),
          onChanged: (v) => update(c, 'observations', v),
        ),
        _CorrectionReason(id: widget.id),
        CabinetBusyButton(
          onPressed: () => cabinetAction(context, () async {
            if (!await confirmInstallation(context, c, widget.id)) return;
            final now = c.record(widget.id).working;
            final payload = object(now['installation']);
            payload.removeWhere((k, v) => v == null && k != 'accountNumber');
            await c.enqueue(widget.id, 'installation_save', {
              'installation': payload,
              if (now['correctionReason'] != null)
                'reason': now['correctionReason'],
            });
          }),
          child: const Text('Guardar instalación para sincronizar'),
        ),
        OutlinedButton(
          onPressed: () => cabinetAction(context, () async {
            if (!await confirmInstallation(context, c, widget.id)) return;
            final now = c.record(widget.id).working;
            final payload = object(now['installation']);
            payload.removeWhere((k, v) => v == null && k != 'accountNumber');
            await c.enqueue(widget.id, 'installation_save', {
              'installation': payload,
              if (now['correctionReason'] != null)
                'reason': now['correctionReason'],
            });
            await c.enqueue(widget.id, 'installation_close', {});
          }),
          child: const Text('Completar instalación en este teléfono'),
        ),
      ],
    );
  }
}

class CabinetAnswerEditor extends StatelessWidget {
  const CabinetAnswerEditor({
    super.key,
    required this.id,
    required this.question,
    required this.value,
    required this.onChanged,
  });
  final String id;
  final Json question, value;
  final Future<void> Function(Json) onChanged;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>(), w = c.record(id).working;
    final knownFailed =
        (w['knownFailures'] as List? ?? []).contains(question['code']) ||
        value['answer'] == 'no';
    final choices = [
      'yes',
      'no',
      if (!knownFailed) 'not_checked',
      if (!knownFailed &&
          question['exceptionAllowed'] == true &&
          (question['code'] != 'CI034' ||
              object(w['installation'])['accountNumber'] == null))
        'not_applicable',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${question['code']} · ${question['label']}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Wrap(
          spacing: 6,
          children: choices
              .map(
                (a) => ChoiceChip(
                  label: Text(answerLabels[a]!),
                  selected: value['answer'] == a,
                  onSelected: (_) => onChanged({
                    'code': question['code'],
                    'answer': a,
                    'evidence': value['evidence'] ?? <Json>[],
                    if (a != 'yes' && value['reason'] != null)
                      'reason': value['reason'],
                  }),
                ),
              )
              .toList(),
        ),
        if (value['answer'] != null && value['answer'] != 'yes') ...[
          TextFormField(
            maxLength: 2000,
            validator: reasonError,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            initialValue: value['reason'],
            decoration: const InputDecoration(
              labelText: 'Motivo / observación obligatoria',
            ),
            onChanged: (v) => onChanged({...value, 'reason': v}),
          ),
          if (value['answer'] == 'not_checked' &&
              (question['deferredReasons'] as List).isNotEmpty)
            DropdownButtonFormField<String>(
              initialValue: value['pendingReason'],
              decoration: const InputDecoration(
                labelText: 'Condición que impide la prueba',
              ),
              items: (question['deferredReasons'] as List)
                  .map(
                    (r) => DropdownMenuItem(
                      value: '$r',
                      child: Text(pendingLabels[r] ?? '$r'),
                    ),
                  )
                  .toList(),
              onChanged: (v) => onChanged({...value, 'pendingReason': v}),
            ),
          if (value['answer'] == 'no' && question['failure'] == 'assessed')
            CheckboxListTile(
              title: const Text(
                'Observación menor: confirmo que no afecta seguridad, protección ni funcionamiento',
              ),
              value: value['assessment'] == 'minor',
              onChanged: (v) => onChanged({
                ...value,
                'assessment': v == true ? 'minor' : 'blocking',
                if (v == true)
                  'impact': {
                    'safety': false,
                    'protection': false,
                    'function': false,
                  },
              }),
            ),
          EvidenceEditor(
            id: id,
            contextName: 'installation',
            value: objects(value['evidence']),
            onChanged: (v) => onChanged({...value, 'evidence': v}),
          ),
        ],
        if (question['code'] == 'CI031' && value['answer'] == 'yes') ...[
          for (final p in objects(
            w['parts'],
          ).where((p) => (p['serial'] ?? '').toString().isNotEmpty))
            CheckboxListTile(
              title: Text('${p['code']} · ${p['serial']}'),
              subtitle: const Text(
                'He comprobado la placa legible y su correspondencia',
              ),
              value: (value['serialComponents'] as List? ?? []).contains(
                p['code'],
              ),
              onChanged: (v) {
                final serials = [...value['serialComponents'] as List? ?? []]
                  ..remove(p['code']);
                if (v == true) serials.add(p['code']);
                final evidence = <String, Json>{};
                for (final piece in objects(
                  w['parts'],
                ).where((p) => serials.contains(p['code']))) {
                  for (final e in objects(
                    piece['evidence'],
                  ).where((e) => e['legible'] == true)) {
                    evidence[e['photoId']] = e;
                  }
                }
                onChanged({
                  ...value,
                  'serialComponents': serials,
                  'evidence': evidence.values.toList(),
                });
              },
            ),
        ],
      ],
    );
  }
}

class CabinetBasePicker extends StatefulWidget {
  const CabinetBasePicker({super.key});
  @override
  State<CabinetBasePicker> createState() => _CabinetBasePickerState();
}

class _CabinetBasePickerState extends State<CabinetBasePicker> {
  String search = '';
  int page = 1;
  bool loading = false;
  Future<void> refresh() async {
    setState(() => loading = true);
    await cabinetAction(
      context,
      context.read<CabinetController>().app.refreshServer,
    );
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>();
    if (!c.allowed) return cabinetDenied(c);
    final list = c.app.visibleSurveys
        .where(
          (b) =>
              [
                bases.SurveyStatus.accepted,
                bases.SurveyStatus.delivered,
              ].contains(b.status) &&
              '${b.displayIdentifier} ${b.accountNumber ?? ''} ${b.id}'
                  .toLowerCase()
                  .contains(search.toLowerCase()),
        )
        .toList();
    final pages = (list.length / 25).ceil().clamp(1, 100000),
        current = page.clamp(1, pages);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Elegir base'),
        actions: [
          IconButton(
            onPressed: loading ? null : refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (loading) const LinearProgressIndicator(),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Sin conexión se utilizan las bases descargadas. Actualizar consulta todas las páginas autorizadas. La API comprobará la exclusividad al sincronizar.',
            ),
          ),
          TextField(
            decoration: const InputDecoration(
              labelText: 'Buscar base / cuenta',
            ),
            onChanged: (v) => setState(() {
              search = v;
              page = 1;
            }),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final b in list.skip((current - 1) * 25).take(25))
                  ListTile(
                    title: Text(b.displayIdentifier),
                    subtitle: Text(
                      'Cuenta ${b.accountNumber ?? 'sin cuenta'} · ${b.status.name}\n${b.canonicalLocation == null ? 'Sin coordenadas descargadas' : '${b.canonicalLocation!.latitude}, ${b.canonicalLocation!.longitude}'}',
                    ),
                    onTap: () => Navigator.pop(context, b),
                  ),
              ],
            ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                onPressed: current > 1
                    ? () => setState(() => page = current - 1)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Text('$current / $pages · ${list.length} bases'),
              IconButton(
                onPressed: current < pages
                    ? () => setState(() => page = current + 1)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class CabinetFinalReview extends StatelessWidget {
  const CabinetFinalReview({super.key, required this.id});
  final String id;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>(),
        r = c.record(id),
        w = r.working,
        review = object(r.json['finalReviewDraft']);
    if (!['installed', 'deliverable'].contains(w['status'])) {
      return const Center(
        child: Text('La revisión final requiere instalación completada.'),
      );
    }
    Future<void> update(String field, Object? value) =>
        c.saveReviewDraft(id, field, value);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Consulta Registro, Piezas e Instalación para revisar evidencia y resolver pendientes. Se reutilizan las respuestas existentes. Cada corrección debe validarse y cerrarse de nuevo.',
        ),
        for (final p in objects(w['pending']))
          ListTile(
            leading: const Icon(Icons.warning_amber),
            title: Text('${p['subject']} · ${p['classification']}'),
            subtitle: Text('${p['reason']}'),
          ),
        CheckboxListTile(
          value: review['dossierConsulted'] == true,
          onChanged: (v) => update('dossierConsulted', v),
          title: const Text('He consultado el expediente y su evidencia'),
        ),
        CheckboxListTile(
          value:
              review['fieldChecked'] == true &&
              freshInstallationGps(review['fieldCheckedAt'], DateTime.now()),
          onChanged: (v) => update('fieldChecked', v),
          title: const Text('He realizado la comprobación en campo'),
          subtitle: const Text(
            'Confirma de nuevo si retomas el expediente después de 15 minutos.',
          ),
        ),
        const Text(
          'Fotografía general actualizada, posterior al cierre de instalación y al intento de revisión anterior.',
        ),
        EvidenceEditor(
          id: id,
          contextName: 'final_review',
          value: objects(review['evidence']),
          onChanged: (v) => update('evidence', v),
        ),
        TextFormField(
          maxLength: 2000,
          validator: reasonError,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          initialValue: review['reason'],
          decoration: const InputDecoration(labelText: 'Dictamen y motivo'),
          onChanged: (v) => update('reason', v),
        ),
        if (w['reviewCorrection'] != null)
          TextFormField(
            maxLength: 2000,
            validator: reasonError,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            initialValue: review['resolutionReason'],
            decoration: const InputDecoration(
              labelText: 'Cómo se resolvió el dictamen negativo anterior',
            ),
            onChanged: (v) => update('resolutionReason', v),
          ),
        for (final verdict in ['approve', 'correction_required'])
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: CabinetBusyButton(
              onPressed:
                  review['fieldChecked'] == true &&
                      freshInstallationGps(
                        review['fieldCheckedAt'],
                        DateTime.now(),
                      ) &&
                      review['dossierConsulted'] == true
                  ? () => cabinetAction(context, () async {
                      await c.flushDrafts();
                      final latest = c.record(id),
                          draft = object(latest.json['finalReviewDraft']);
                      if (reasonError(draft['reason']) != null ||
                          objects(draft['evidence']).isEmpty) {
                        throw StateError(
                          'Falta motivo o fotografía general confirmada.',
                        );
                      }
                      if (verdict == 'approve' &&
                          latest.working['reviewCorrection'] != null &&
                          reasonError(draft['resolutionReason']) != null) {
                        throw StateError(
                          'Explica cómo se resolvió el dictamen anterior (3 a 2000 caracteres).',
                        );
                      }
                      if (!context.mounted ||
                          !await confirmCabinetAction(
                            context,
                            title: verdict == 'approve'
                                ? 'Confirmar aprobación'
                                : 'Confirmar solicitud de corrección',
                            message:
                                '${cabinetIdentity(c, id)}\n\nMotivo: ${draft['reason']}\n\nEsta decisión quedará registrada con tu usuario y fecha. Comprueba el expediente antes de enviar.',
                            confirm: verdict == 'approve'
                                ? 'Aprobar este gabinete'
                                : 'Solicitar corrección',
                          )) {
                        return;
                      }
                      if (!freshInstallationGps(
                        draft['fieldCheckedAt'],
                        DateTime.now(),
                      )) {
                        throw StateError(
                          'Confirma nuevamente la revisión en campo.',
                        );
                      }
                      await c.enqueue(id, 'final_review', {
                        'fieldChecked': true,
                        'dossierConsulted': true,
                        'installationOperationId':
                            latest.working['installationOperationId'],
                        'verdict': verdict,
                        'reason': draft['reason'],
                        'evidence': draft['evidence'],
                        'evidenceConfirmed': true,
                        if (verdict == 'approve' &&
                            latest.working['reviewCorrection'] != null)
                          'resolvesReview': {
                            'operationId': object(
                              latest.working['reviewCorrection'],
                            )['operationId'],
                            'reason': draft['resolutionReason'],
                          },
                      });
                    })
                  : null,
              child: Text(
                verdict == 'approve'
                    ? 'Emitir aprobación para sincronizar'
                    : 'Requiere corrección',
              ),
            ),
          ),
        const Text(
          'Entregable no equivale a Entregado. La aprobación sólo se confirma al recibir la respuesta del servidor.',
        ),
      ],
    );
  }
}

class CabinetSyncPage extends StatelessWidget {
  const CabinetSyncPage({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>();
    if (!c.allowed) return cabinetDenied(c);
    return Scaffold(
      appBar: AppBar(title: const Text('Sincronización de gabinetes')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (c.syncing) const LinearProgressIndicator(),
          CabinetBusyButton(
            onPressed: c.syncing ? null : () => c.synchronize(force: true),
            child: const Text('Reintentar ahora'),
          ),
          const Text(
            'Se reanuda al abrir la app o recuperar conexión. No se garantiza ejecución con la app cerrada.',
          ),
          for (final archived in c.store.all().where(
            (r) => r.json['archived'] == true && r.json['actor'] == c.actor,
          ))
            Card(
              child: ListTile(
                title: Text(
                  '${displayUid(archived.working['uid'])} · conflicto conservado',
                ),
                subtitle: const Text(
                  'Las capturas originales siguen disponibles; el expediente vigente está separado.',
                ),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CabinetDetailPage(id: archived.id),
                  ),
                ),
              ),
            ),
          for (final r in c.records)
            Card(
              child: Column(
                children: [
                  ListTile(
                    title: Text(displayUid(r.working['uid'])),
                    subtitle: Text(
                      '${r.pending.length} operaciones · ${r.photos.where((p) => p['verified'] == true).length}/${r.photos.length} fotos verificadas\nÚltimo envío: ${r.json['lastSent'] ?? 'pendiente'}',
                    ),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => CabinetDetailPage(id: r.id),
                      ),
                    ),
                  ),
                  for (final o in r.pending)
                    ListTile(
                      title: Text(
                        '${cabinetOperationLabels[object(o['body'])['type']]} · ${cabinetSyncLabels[o['state']]}',
                      ),
                      subtitle: Text(
                        '${o['error'] ?? 'Pendiente'}${o['actor'] != c.actor ? '\nRequiere la sesión del residente que capturó' : ''}',
                      ),
                    ),
                  if (r.pending.firstOrNull?['state'] == 'conflict')
                    TextButton(
                      onPressed: () async {
                        await cabinetAction(context, () async {
                          final problem = object(r.pending.first['problem']);
                          if (problem['code'] == 'UID_CONFLICT') {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('UID ya registrado'),
                                content: const Text(
                                  'Abrir el expediente del servidor y conservar este registro con sus fotos como conflicto archivado. No se trasladan capturas automáticamente.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx),
                                    child: const Text('Cancelar'),
                                  ),
                                  CabinetBusyButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Abrir existente'),
                                  ),
                                ],
                              ),
                            );
                            if (ok == true) await c.resolveDuplicate(r.id);
                            return;
                          }
                          await c.pull(r.id);
                          if (!context.mounted) return;
                          var reason = '';
                          final retry = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text('Reconciliar explícitamente'),
                              content: SingleChildScrollView(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'Servidor: versión ${c.record(r.id).server['version']} · ${cabinetStatus(c.record(r.id).server['status'])}. Consulta historial y compara antes de reenviar.',
                                    ),
                                    Text('${r.pending.first['error']}'),
                                    CabinetComparison(record: c.record(r.id)),
                                    TextField(
                                      decoration: const InputDecoration(
                                        labelText: 'Motivo de resolución',
                                      ),
                                      onChanged: (v) => reason = v,
                                    ),
                                  ],
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('Cancelar'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text(
                                    'Usar servidor, conservar borrador',
                                  ),
                                ),
                                CabinetBusyButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Reintentar captura local'),
                                ),
                              ],
                            ),
                          );
                          if (retry != null) {
                            await c.reconcile(
                              r.id,
                              retryLocal: retry,
                              reason: reason,
                            );
                          }
                        });
                      },
                      child: const Text('Consultar y resolver conflicto'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class CabinetHistoryPage extends StatefulWidget {
  const CabinetHistoryPage({super.key, required this.id});
  final String id;
  @override
  State<CabinetHistoryPage> createState() => _CabinetHistoryPageState();
}

class _CabinetHistoryPageState extends State<CabinetHistoryPage> {
  bool loading = true;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final c = context.read<CabinetController>();
    if (!c.allowed) return;
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      await c.history(widget.id);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>();
    if (!c.allowed) return cabinetDenied(c);
    final r = c.record(widget.id);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Historial y versiones'),
        actions: [
          IconButton(
            tooltip: 'Actualizar historial',
            onPressed: loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        children: [
          if (loading) const LinearProgressIndicator(),
          if (failed)
            ListTile(
              title: const Text('No se pudo actualizar el historial.'),
              subtitle: const Text('Se conserva la información descargada.'),
              trailing: TextButton(
                onPressed: loading ? null : _load,
                child: const Text('Reintentar'),
              ),
            ),
          if (!loading &&
              !failed &&
              objects(r.json['history']).isEmpty &&
              r.operations.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Este gabinete aún no tiene historial.'),
            ),
          for (final op in objects(r.json['history']))
            ExpansionTile(
              title: Text(
                'v${op['result_version']} · ${cabinetOperationLabels[op['command_type']]}',
              ),
              subtitle: Text(
                'Actor ${op['actor_user_id']}\nCaptura ${op['captured_at']} · recepción ${op['received_at']}',
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: CabinetVersionSummary(
                    command: object(op['command']),
                    cabinet: object(object(op['result'])['cabinet']),
                  ),
                ),
              ],
            ),
          for (final op in r.operations)
            ListTile(
              title: Text(
                '${cabinetOperationLabels[object(op['body'])['type']]} · ${cabinetSyncLabels[op['state']]}',
              ),
              subtitle: Text(
                'Actor ${op['actor']}\n${object(op['body'])['capturedAt']}\n${op['resolution'] ?? op['error'] ?? ''}',
              ),
            ),
        ],
      ),
    );
  }
}

class CabinetPhotoPage extends StatelessWidget {
  const CabinetPhotoPage({super.key, required this.id, required this.photo});
  final String id;
  final Json photo;
  @override
  Widget build(BuildContext context) {
    final c = context.watch<CabinetController>();
    if (!c.allowed) return cabinetDenied(c);
    return Scaffold(
      appBar: AppBar(title: const Text('Evidencia del gabinete')),
      body: FutureBuilder(
        future: c.photoBytes(id, {
          ...photo,
          'thumbnailPath': photo['localPath'],
        }),
        builder: (context, snapshot) => snapshot.hasData
            ? InteractiveViewer(
                minScale: 0.5,
                maxScale: 8,
                child: Center(child: Image.memory(snapshot.data!)),
              )
            : Center(
                child: Text(
                  snapshot.hasError
                      ? 'No se pudo recuperar la fotografía. Datos conservados.'
                      : 'Cargando evidencia…',
                ),
              ),
      ),
    );
  }
}

class CabinetComparison extends StatelessWidget {
  const CabinetComparison({super.key, required this.record});
  final CabinetRecord record;
  @override
  Widget build(BuildContext context) {
    final local = record.working, server = record.server;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Comparación: teléfono / servidor',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        for (final entry in {
          'model': 'Modelo',
          'automated': 'Automatización',
          'status': 'Estado',
        }.entries)
          if (local[entry.key] != server[entry.key])
            Text('${entry.value}: ${local[entry.key]} / ${server[entry.key]}'),
        for (final entry in {
          'baseId': 'Base',
          'accountNumber': 'Cuenta',
        }.entries)
          if (object(local['installation'])[entry.key] !=
              object(server['installation'])[entry.key])
            Text(
              '${entry.value}: ${object(local['installation'])[entry.key]} / ${object(server['installation'])[entry.key]}',
            ),
        for (final p in objects(local['parts']))
          Builder(
            builder: (_) {
              final other =
                  objects(
                    server['parts'],
                  ).where((s) => s['code'] == p['code']).firstOrNull ??
                  {};
              return p['present'] == other['present'] &&
                      p['serial'] == other['serial']
                  ? const SizedBox.shrink()
                  : Text(
                      '${p['code']}: presente ${p['present']} / ${other['present']}; serie ${p['serial'] ?? '—'} / ${other['serial'] ?? '—'}',
                    );
            },
          ),
        for (final a in objects(object(local['installation'])['answers']))
          Builder(
            builder: (_) {
              final other =
                  objects(
                    object(server['installation'])['answers'],
                  ).where((s) => s['code'] == a['code']).firstOrNull ??
                  {};
              return a['answer'] == other['answer']
                  ? const SizedBox.shrink()
                  : Text(
                      '${a['code']}: ${answerLabels[a['answer']] ?? 'Pendiente'} / ${answerLabels[other['answer']] ?? 'Pendiente'}',
                    );
            },
          ),
      ],
    );
  }
}

class CabinetVersionSummary extends StatelessWidget {
  const CabinetVersionSummary({
    super.key,
    required this.command,
    required this.cabinet,
  });
  final Json command, cabinet;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '${cabinetStatus(cabinet['status'])} · ${cabinet['model']}${cabinet['automated'] == true ? '-A' : ''}',
      ),
      if (command['reason'] != null) Text('Motivo: ${command['reason']}'),
      if (command['verdict'] != null)
        Text(
          command['verdict'] == 'approve' ? 'Aprobado' : 'Requiere corrección',
        ),
      if (cabinet['installation'] != null)
        Text(
          'Base: ${object(cabinet['installation'])['baseId']} · Cuenta: ${object(cabinet['installation'])['accountNumber'] ?? 'sin cuenta'}',
        ),
      for (final part in objects(command['parts']))
        Text(
          '${part['code']}: ${part['present'] == true ? 'Presente' : 'Pendiente'}${part['serial'] == null ? '' : ' · Serie ${part['serial']}'}${part['observations'] == null ? '' : ' · ${part['observations']}'}',
        ),
      for (final p in objects(cabinet['pending']))
        Text('${p['subject']}: ${p['reason']}'),
    ],
  );
}

String cabinetCaptureDate(Object? value) {
  final date = DateTime.tryParse('$value');
  return date == null
      ? 'Fecha no disponible'
      : DateFormat('dd/MM/yyyy HH:mm').format(date.toLocal());
}
