import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../domain/cabinets/cabinet_models.dart';
import 'hydrostatic_pages.dart';

typedef HydrostaticScannerSurface =
    Widget Function(BuildContext context, ValueChanged<String> onRead);

/// An isolated barcode reader. It never captures evidence or mutates cabinets.
class HydrostaticScannerPage extends StatefulWidget {
  const HydrostaticScannerPage({super.key, this.surface});
  final HydrostaticScannerSurface? surface;
  @override
  State<HydrostaticScannerPage> createState() => _HydrostaticScannerPageState();
}

class _HydrostaticScannerPageState extends State<HydrostaticScannerPage> {
  bool done = false;
  String? error;
  void read(String raw) {
    if (!mounted || done || ModalRoute.of(context)?.isCurrent != true) return;
    try {
      final uid = cabinetUid(raw);
      done = true;
      Navigator.pop(context, uid);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => HydrostaticFrame(
    title: 'ESCANEAR QR',
    builder: (context, c) => Column(
      children: [
        Expanded(
          child: widget.surface?.call(context, read) ?? _QrCamera(onRead: read),
        ),
        if (error != null)
          Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
        TextButton(
          onPressed: () {
            done = true;
            Navigator.pop(context);
          },
          child: const Text('CANCELAR ESCANEO'),
        ),
      ],
    ),
  );
}

class _QrCamera extends StatefulWidget {
  const _QrCamera({required this.onRead});
  final ValueChanged<String> onRead;
  @override
  State<_QrCamera> createState() => _QrCameraState();
}

class _QrCameraState extends State<_QrCamera> with WidgetsBindingObserver {
  final scanner = MobileScannerController(
    formats: [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Frame reconstructs and revalidates the reader on resume.
    if (state != AppLifecycleState.resumed) unawaited(scanner.stop());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(scanner.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MobileScanner(
    controller: scanner,
    errorBuilder: (context, error) => const HydrostaticCameraUnavailable(),
    onDetect: (capture) {
      if (!mounted) return;
      for (final barcode in capture.barcodes) {
        if (barcode.rawValue != null) widget.onRead(barcode.rawValue!);
      }
    },
  );
}

class HydrostaticCameraUnavailable extends StatelessWidget {
  const HydrostaticCameraUnavailable({super.key});
  @override
  Widget build(BuildContext context) => const Center(
    child: Padding(
      padding: EdgeInsets.all(24),
      child: Text(
        'No se pudo abrir la cámara. Revisa su permiso en Ajustes o regresa para capturar el número de serie manualmente.',
      ),
    ),
  );
}
