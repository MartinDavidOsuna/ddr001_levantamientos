import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('release cleartext is limited to the official production host', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final policy = File(
      'android/app/src/main/res/xml/network_security_config.xml',
    ).readAsStringSync();

    expect(
      manifest,
      contains('android:networkSecurityConfig="@xml/network_security_config"'),
    );
    expect(manifest, isNot(contains('android:usesCleartextTraffic="true"')));
    expect(policy, contains('<base-config cleartextTrafficPermitted="false"'));
    expect(policy, contains('<domain-config cleartextTrafficPermitted="true"'));
    expect(
      policy,
      contains('<domain includeSubdomains="false">cifra.aquafim.com</domain>'),
    );
    expect(policy, isNot(contains('localhost')));
    expect(policy, isNot(contains('192.168.')));
    expect(policy, isNot(contains('10.0.2.2')));
  });
}
