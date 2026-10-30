"""Build signed RC from committed sources in this primary checkout; never install.
Preserves an existing QA-only Gradle overlay byte-for-byte, including on build failure.
No keystore values are read, printed or copied by this script; Gradle uses existing signing.
"""
from pathlib import Path
import os
import base64
import re
import json
import subprocess

root = Path(__file__).resolve().parents[1]
os.chdir(root)
if subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip() != str(root):
    raise SystemExit('Run only inside the primary checkout')
production_changes = subprocess.check_output(
    ['git', 'diff', '--name-only', 'HEAD', '--', 'lib', 'pubspec.yaml', 'pubspec.lock', 'android'], text=True,
).splitlines()
if any(name != 'android/app/build.gradle.kts' for name in production_changes):
    raise SystemExit('Commit reviewed production sources before building')
gradle = root / 'android/app/build.gradle.kts'
original = gradle.read_bytes()
committed = subprocess.check_output(['git', 'show', 'HEAD:android/app/build.gradle.kts'])
backup = root / 'build/hapi7-preserved-build.gradle.kts'
backup.parent.mkdir(exist_ok=True)
backup.write_bytes(original)
# This is the existing official endpoint contract; no requests are made by the build.
endpoint = 'http://cifra.aquafim.com:3002/api/v1'
defines = ['APP_ENV=production', 'API_BASE_URL=' + endpoint,
           'HYDROSTATIC_SYNC_ENABLED=false', 'HYDROSTATIC_PRODUCTION_SYNC_ENABLED=false']
command = ['./gradlew', '--no-daemon', ':app:assembleRelease', '-Ptarget=lib/main.dart',
           '-Ptarget-platform=android-arm,android-arm64,android-x64',
           '-Pdart-defines=' + ','.join(base64.b64encode(v.encode()).decode() for v in defines)]
local = root / 'android/local.properties'
local_original = local.read_bytes()
lines = [line for line in local_original.decode().splitlines()
         if not line.startswith(('flutter.buildMode=', 'flutter.versionName=', 'flutter.versionCode='))]
local_rc = ('\n'.join(lines + ['flutter.buildMode=release', 'flutter.versionName=1.5.25-rc.1',
                             'flutter.versionCode=39']) + '\n').encode()

registrant = root / 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java'
registrant_original = registrant.read_bytes()
plugins = json.loads((root / '.flutter-plugins-dependencies').read_text())
assert any(p['name'] == 'integration_test' and p.get('dev_dependency') for p in plugins['plugins']['android'])
registrant_rc = re.sub(rb'    try \{\n      flutterEngine.getPlugins\(\).add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\n    \} catch \(Exception e\) \{\n      Log\.e\(TAG, "Error registering plugin integration_test,[^\n]*\n    \}\n', b'', registrant_original)
assert b'IntegrationTestPlugin' not in registrant_rc
try:
    registrant.write_bytes(registrant_rc)
    gradle.write_bytes(committed)
    local.write_bytes(local_rc)
    subprocess.run(command, check=True, cwd=root / 'android', timeout=1200)
finally:
    if registrant.read_bytes() == registrant_rc:
        registrant.write_bytes(registrant_original)
    if local.read_bytes() == local_rc:
        local.write_bytes(local_original)
    if gradle.read_bytes() != committed:
        raise RuntimeError('Concurrent Gradle edit detected. Original overlay preserved in build; do not overwrite concurrent work.')
    gradle.write_bytes(original)
    assert gradle.read_bytes() == original
