import 'package:flutter/foundation.dart' show kReleaseMode;

import '../../domain/cabinets/cabinet_models.dart';

const legacyCabinetUids = {
  'AQ26000068',
  'AQ26000076',
  'AQ26000092',
  'AQ26000105',
  'AQ26000121',
  'AQ26000130',
  'AQ26000148',
  'AQ26000156',
  'AQ26000164',
  'AQ26000172',
  'AQ26000189',
};
const legacyAutomaticUids = {
  'AQ26000076',
  'AQ26000092',
  'AQ26000105',
  'AQ26000121',
  'AQ26000130',
  'AQ26000148',
  'AQ26000156',
  'AQ26000164',
  'AQ26000172',
  'AQ26000189',
};
const legacyAutomaticEnabled = bool.fromEnvironment('CABINET_LEGACY_AUTO_RC14');
const legacyPilotUid = 'AQ26000068';
const legacySupportEnabled = bool.fromEnvironment(
  'CABINET_LEGACY_RECOVERY_ENABLED',
);
// Release builds do not apply incident-specific UID filtering.
bool legacyProtected(CabinetRecord r) =>
    !kReleaseMode &&
    legacyCabinetUids.contains(r.working['uid']) &&
    (legacyAutomaticEnabled || r.json['legacyRecoveryCompleted'] != true);
