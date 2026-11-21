"""Review build only. Requires verified metadata from the ORIGINAL destination.
Never calls adb, installs, reads sessions or sends data. Does not change pubspec.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'com.aquafim.ddr001levantamientos'
CERT = '780f516576d98fff8edaf34be7af6c4488dd8fd57a2c97500c9ff07e60195544'
parser = argparse.ArgumentParser()
parser.add_argument('--verified-target', required=True,
                    help='JSON: package, versionCode, certificateSha256, originalWorkerDevice=true, verifiedAt')
args = parser.parse_args()
os.chdir(ROOT)
evidence = json.loads(Path(args.verified_target).read_text())
if (evidence.get('package') != PACKAGE or evidence.get('certificateSha256') != CERT
        or evidence.get('originalWorkerDevice') is not True
        or not evidence.get('verifiedAt') or type(evidence.get('versionCode')) is not int):
    raise SystemExit('Original target identity/version/signature has not been verified')
if evidence['versionCode'] < 1:
    raise SystemExit('Invalid installed version')
version = max(43, evidence['versionCode']) + 1
name = '1.5.25-recovery.1'
local = ROOT / 'android/local.properties'
registrant = ROOT / 'android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java'
original = local.read_bytes()
registration = registrant.read_bytes()
props = dict(line.split('=', 1) for line in original.decode().splitlines() if '=' in line)
sdk = Path(props['sdk.dir']) / 'build-tools/36.0.0'
updated = ('\n'.join(line for line in original.decode().splitlines()
                      if not line.startswith(('flutter.buildMode=', 'flutter.versionName=', 'flutter.versionCode=')))
           + f'\nflutter.buildMode=release\nflutter.versionName={name}\nflutter.versionCode={version}\n').encode()
reg = re.sub(rb'    try \{\n      flutterEngine.getPlugins\(\).add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\n    \} catch \(Exception e\) \{\n      Log\.e\(TAG, "Error registering plugin integration_test,[^\n]*\n    \}\n', b'', registration)
if b'IntegrationTestPlugin' in reg:
    raise SystemExit('Unexpected generated registrant; no build')
files = subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z','--','lib','android','pubspec.yaml','pubspec.lock','tool']).split(b'\0')
def hashes():
    return {p.decode(): hashlib.sha256((ROOT/p.decode()).read_bytes()).hexdigest()
            for p in files if p and (ROOT/p.decode()).is_file()}
before = hashes()
base = ['./gradlew','--no-daemon','-PcabinetRecovery=true','-Ptarget=lib/recovery_main.dart',
        '-Ptarget-platform=android-arm,android-arm64,android-x64',
        '-Pdart-defines='+base64.b64encode(b'CABINET_RECOVERY_ONLY=true').decode()]
try:
    local.write_bytes(updated)
    registrant.write_bytes(reg)
    subprocess.run(base+[':app:processReleaseMainManifest'],cwd=ROOT/'android',check=True)
    merged = ROOT/'build/app/intermediates/merged_manifest/release/processReleaseMainManifest/AndroidManifest.xml'
    tree = ET.parse(merged).getroot()
    ns = '{http://schemas.android.com/apk/res/android}'
    assert tree.attrib['package'] == PACKAGE
    assert tree.attrib[ns+'versionCode'] == str(version)
    application = tree.find('application')
    assert application.attrib.get(ns+'debuggable', 'false') == 'false'
    assert not any(tree.findall(tag) for tag in ['application/service','application/provider','application/receiver'])
    assert [e.attrib[ns+'name'] for e in tree.findall('application/activity')] == [PACKAGE+'.RecoveryActivity']
    assert not any(e.attrib[ns+'name'] in ['android.permission.INTERNET','android.permission.CAMERA',
        'android.permission.ACCESS_FINE_LOCATION','android.permission.ACCESS_COARSE_LOCATION']
        for e in tree.findall('uses-permission'))
    subprocess.run(base+[':app:assembleRelease'],cwd=ROOT/'android',check=True)
    apk = ROOT/'build/app/outputs/apk/release/app-release.apk'
    signature = subprocess.check_output([str(sdk/'apksigner'),'verify','--print-certs',str(apk)],text=True)
    assert CERT in signature
    badging = subprocess.check_output([str(sdk/'aapt'),'dump','badging',str(apk)],text=True)
    assert f"versionCode='{version}'" in badging and f"name='{PACKAGE}'" in badging
    out = ROOT/f'build/recovery-review-{version}'
    out.mkdir(exist_ok=False)
    shutil.copy2(apk,out/f'ddr001-recovery-{version}.apk')
    shutil.copy2(merged,out/'AndroidManifest.xml')
    (out/'signature.txt').write_text(signature)
    result = {'package':PACKAGE,'versionCode':version,'versionName':name,
              'returnOperationalMinimumCode':version+1,'sourceHashes':before,
              'apkSha256':hashlib.sha256(apk.read_bytes()).hexdigest(),
              'installationPerformed':False}
finally:
    if local.read_bytes() != updated or registrant.read_bytes() != reg:
        raise RuntimeError('Concurrent build file change: preserve originals for manual review')
    local.write_bytes(original)
    registrant.write_bytes(registration)
if hashes() != before:
    raise SystemExit('Sources changed during build: do not distribute artifact')
(out/'build-manifest.json').write_text(json.dumps(result,indent=2)+'\n')
print(out)
