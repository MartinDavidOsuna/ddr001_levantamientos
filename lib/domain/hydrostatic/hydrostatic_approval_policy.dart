import 'hydrostatic_models.dart';

/// Procedure limit approved by the user: close within 30 minutes after execution.
class HydrostaticApprovalPolicy {
  const HydrostaticApprovalPolicy({this.version, this.maximumFinalDelay});
  static const approved = HydrostaticApprovalPolicy(
    version: 'hydrostatic-close-30m-v1',
    maximumFinalDelay: Duration(minutes: 30),
  );
  final String? version;
  final Duration? maximumFinalDelay;
  void requireConfigured() => hydroRequire(
    version != null &&
        version!.trim().isNotEmpty &&
        maximumFinalDelay != null &&
        maximumFinalDelay! > Duration.zero,
    'FINAL_PHOTO_POLICY_REQUIRED',
    'Pendiente de definir el tiempo máximo permitido para la foto final a 4 bar. Las evidencias se conservan; no se puede aprobar todavía.',
  );
  bool accepts(DateTime endedAt, DateTime capturedAt) {
    requireConfigured();
    final delay = capturedAt.difference(endedAt);
    return !delay.isNegative && delay <= maximumFinalDelay!;
  }

  HydroJson toJson() => {
    'version': version,
    'maximumFinalDelayMs': maximumFinalDelay?.inMilliseconds,
  };
}
