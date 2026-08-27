import 'package:flutter_test/flutter_test.dart';

void main() {
  const enabled = bool.fromEnvironment(
    'RUN_CONSTRUCTION_E2E',
    defaultValue: false,
  );
  testWidgets('Construction TEST E2E requires explicit device credentials', (
    tester,
  ) async {
    if (!enabled) return;
    const base = String.fromEnvironment('API_BASE_URL');
    expect(base, isNotEmpty, reason: 'API_BASE_URL TEST is required');
    expect(base, isNot(contains('DDR001_Hidrantes_Prod')));
    // Camera/GPS/login execution is device-driven; credentials are never embedded.
  });
}
