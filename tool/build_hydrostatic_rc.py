"""Build signed RC from committed sources (or explicit uncommitted review candidate) in this primary checkout; never install.
Preserves an existing QA-only Gradle overlay byte-for-byte, including on build failure.
No keystore values are read, printed or copied by this script; Gradle uses existing signing.
"""
from pathlib import Path
import os
import base64
import re
import json
import subprocess
import argparse
import hashlib

parser = argparse.ArgumentParser()
parser.add_argument('--allow-uncommitted-candidate', action='store_true',
                    help='Build review candidate without committing; preserve a source hash manifest.')
parser.add_argument('--legacy-cabinet-support', action='store_true',
                    help='Enable resident-only selective historical cabinet support in this candidate.')
parser.add_argument('--auto-historical-sync', action='store_true', help='Temporary RC14 manual-home-sync historical batch.')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
os.chdir(root)
if subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip() != str(root):
    raise SystemExit('Run only inside the primary checkout')
production_changes = subprocess.check_output(
    ['git', 'diff', '--name-only', 'HEAD', '--', 'lib', 'pubspec.yaml', 'pubspec.lock', 'android'], text=True,
).splitlines()
if not args.allow_uncommitted_candidate and any(name != 'android/app/build.gradle.kts' for name in production_changes):
    raise SystemExit('Commit reviewed production sources before building')
gradle = root / 'android/app/build.gradle.kts'
original = gradle.read_bytes()
committed = subprocess.check_output(['git', 'show', 'HEAD:android/app/build.gradle.kts'])
backup = root / 'build/hydrostatic-candidate-preserved-build.gradle.kts'
backup.parent.mkdir(exist_ok=True)
backup.write_bytes(original)
version = re.search(r'^version:\s*(\S+)\+(\d+)', (root / 'pubspec.yaml').read_text(), re.M)
if version is None:
    raise SystemExit('Missing pubspec release version')
version_name, version_code = version.groups()
if args.allow_uncommitted_candidate and not production_changes:
    raise SystemExit('Candidate flag requires review changes')
source_paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--', 'lib', 'android', 'assets', 'pubspec.yaml', 'pubspec.lock', 'tool/build_hydrostatic_rc.py']).split(b'\0')
def source_hashes():
    return {p.decode(): hashlib.sha256((root / p.decode()).read_bytes()).hexdigest()
            for p in source_paths if p and (root / p.decode()).is_file()}
source_before = source_hashes()
manifest = root / 'build/hydrostatic-candidate-source.json'
source_manifest = {
    'gitHead': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'uncommittedCandidate': args.allow_uncommitted_candidate,
    'versionName': version_name, 'versionCode': int(version_code),
    'files': source_before,
}
# This is the existing official endpoint contract; no requests are made by the build.
endpoint = 'http://cifra.aquafim.com:3002/api/v1'
defines = ['APP_ENV=production', 'API_BASE_URL=' + endpoint,
           'HYDROSTATIC_SYNC_ENABLED=true', 'HYDROSTATIC_PRODUCTION_SYNC_ENABLED=true']
if args.legacy_cabinet_support:
    if not args.allow_uncommitted_candidate:
        raise SystemExit('Legacy support currently requires an explicit review candidate')
    defines.append('CABINET_LEGACY_RECOVERY_ENABLED=true')
if args.auto_historical_sync:
    if not args.legacy_cabinet_support or version_name != '1.5.25-rc.15' or version_code != '53':
        raise SystemExit('Automatic historical support requires RC15+53 and legacy support')
    defines.append('CABINET_LEGACY_AUTO_RC14=true')
source_manifest['publicDefines'] = defines
manifest.write_text(json.dumps(source_manifest, indent=2) + '\n')
command = ['./gradlew', '--no-daemon', ':app:assembleRelease', '-Ptarget=lib/main.dart',
           '-Ptarget-platform=android-arm,android-arm64,android-x64',
           '-Pdart-defines=' + ','.join(base64.b64encode(v.encode()).decode() for v in defines)]
local = root / 'android/local.properties'
local_original = local.read_bytes()
lines = [line for line in local_original.decode().splitlines()
         if not line.startswith(('flutter.buildMode=', 'flutter.versionName=', 'flutter.versionCode='))]
local_rc = ('\n'.join(lines + ['flutter.buildMode=release', 'flutter.versionName=' + version_name,
                             'flutter.versionCode=' + version_code]) + '\n').encode()

registrant = root / 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java'
registrant_original = registrant.read_bytes()
plugins = json.loads((root / '.flutter-plugins-dependencies').read_text())
assert any(p['name'] == 'integration_test' and p.get('dev_dependency') for p in plugins['plugins']['android'])
registrant_rc = re.sub(rb'    try \{\n      flutterEngine.getPlugins\(\).add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\n    \} catch \(Exception e\) \{\n      Log\.e\(TAG, "Error registering plugin integration_test,[^\n]*\n    \}\n', b'', registrant_original)
assert b'IntegrationTestPlugin' not in registrant_rc
try:
    registrant.write_bytes(registrant_rc)
    gradle.write_bytes(original if args.allow_uncommitted_candidate else committed)
    local.write_bytes(local_rc)
    subprocess.run(command, check=True, cwd=root / 'android', timeout=1200)
finally:
    if registrant.read_bytes() == registrant_rc:
        registrant.write_bytes(registrant_original)
    if local.read_bytes() == local_rc:
        local.write_bytes(local_original)
    if gradle.read_bytes() != (original if args.allow_uncommitted_candidate else committed):
        raise RuntimeError('Concurrent Gradle edit detected. Original overlay preserved in build; do not overwrite concurrent work.')
    gradle.write_bytes(original)
    assert gradle.read_bytes() == original
    if source_hashes() != source_before:
        raise RuntimeError('Source changed during build; candidate cannot be certified')
