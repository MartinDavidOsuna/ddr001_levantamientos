"""Build signed RC from committed sources in this primary checkout; never install.
Preserves an existing QA-only Gradle overlay byte-for-byte, including on build failure.
No keystore values are read, printed or copied by this script; Gradle uses existing signing.
"""
from pathlib import Path
import os
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
command = ['flutter', 'build', 'apk', '--release', '--no-pub',
           '--build-name=1.5.25-rc.1', '--build-number=39',
           '--dart-define=APP_ENV=production', '--dart-define=API_BASE_URL=' + endpoint,
           '--dart-define=HYDROSTATIC_SYNC_ENABLED=false',
           '--dart-define=HYDROSTATIC_PRODUCTION_SYNC_ENABLED=false']
try:
    gradle.write_bytes(committed)
    subprocess.run(command, check=True)
finally:
    if gradle.read_bytes() != committed:
        raise RuntimeError('Concurrent Gradle edit detected. Original overlay preserved in build; do not overwrite concurrent work.')
    gradle.write_bytes(original)
    assert gradle.read_bytes() == original
