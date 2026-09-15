from __future__ import annotations
import json
from pathlib import Path
import shutil
import subprocess
import sys
import re
import pytest

ROOT = Path(__file__).resolve().parents[1]

@pytest.mark.skipif(sys.platform != 'darwin' or not shutil.which('xcrun'), reason='requires macOS Swift')
def test_desktop_installation_contract(tmp_path):
    executable = tmp_path / 'DesktopInstallationChecks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-framework', 'AppKit',
                    str(ROOT / 'deploy/macos/app/NativeLocalization.swift'),
                    str(ROOT / 'deploy/macos/app/DesktopInstallation.swift'),
                    str(ROOT / 'tests/macos/DesktopInstallationChecks.swift'),
                    '-o', str(executable)], check=True, capture_output=True, text=True)
    subprocess.run([str(executable)], check=True, capture_output=True, text=True)

def test_installer_translations_are_complete():
    path = ROOT / 'voxbridge/ui_locales/installer.json'
    assert path.is_file(), 'first-run installer needs its localized catalog'
    catalog = json.loads(path.read_text())
    assert catalog['version'] == 1
    for source, translations in catalog['messages'].items():
        assert set(translations) == {'zh', 'en', 'ja', 'fr', 'es', 'it', 'pt', 'hi'}
        assert translations['zh'] == source
        assert all(translations.values())
        for value in translations.values():
            assert sorted(re.findall(r'\{\d+\}', value)) == sorted(re.findall(r'\{\d+\}', source))
    known = set(catalog['messages'])
    known.update(json.loads((ROOT / 'voxbridge/ui_locales/native.json').read_text())['messages'])
    for name in ('DesktopInstallation.swift', 'InstallationWindow.swift'):
        source = (ROOT / 'deploy/macos/app' / name).read_text()
        for literal in re.findall(r'"([^"\n]*[\u4e00-\u9fff][^"\n]*)"', source):
            assert literal in known, (name, literal)

@pytest.mark.skipif(sys.platform != 'darwin' or not shutil.which('xcrun'), reason='requires macOS Swift')
def test_desktop_installation_window_start_gate(tmp_path):
    executable = tmp_path / 'InstallationWindowChecks'
    source = ROOT / 'deploy/macos/app'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-framework', 'AppKit',
                    *[str(source / name) for name in ('NativeLocalization.swift', 'NativeLocalizedViews.swift',
                        'DesktopInstallation.swift', 'InstallationWindow.swift')],
                    str(ROOT / 'tests/macos/InstallationWindowChecks.swift'), '-o', str(executable)],
                   check=True, capture_output=True, text=True)
    subprocess.run([str(executable)], check=True, capture_output=True, text=True)

@pytest.mark.skipif(sys.platform != 'darwin' or not shutil.which('xcrun'), reason='requires macOS Swift')
def test_native_bootstrap_acceptance_ready_gate_requires_matching_payload(tmp_path):
    executable = tmp_path / 'DesktopBootstrapAcceptance'
    source = ROOT / 'deploy/macos/app'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5',
                    str(source / 'NativeLocalization.swift'), str(source / 'DesktopInstallation.swift'),
                    str(ROOT / 'tests/macos/DesktopBootstrapAcceptance.swift'), '-o', str(executable)],
                   check=True, capture_output=True, text=True)
    resources, home = tmp_path / 'payload', tmp_path / 'Fixture Data'
    resources.mkdir(); home.mkdir()
    metadata = {'version': '1.8.0', 'runtime_sha256': 'a' * 64, 'runtime_unpacked_bytes': 100,
                'model_bytes': 200, 'manifest_sha256': 'b' * 64, 'desktop_wheels_sha256': 'c' * 64}
    (resources / 'release.json').write_text(json.dumps(metadata))
    root = home / 'versions/1.8.0'
    for path in ('.venv/bin', 'VoxBridge', 'scripts'):
        (root / path).mkdir(parents=True, exist_ok=True)
    (root / '.venv/bin/python').write_text('#!/bin/sh\nexit 99\n')
    (root / '.venv/bin/python').chmod(0o755)
    (root / 'VoxBridge/macos.sh').touch()
    (root / 'scripts/install_desktop.py').touch()
    (root / 'installed.json').write_text(json.dumps(metadata))
    stamp = root / 'runtime-installed.json'
    stamp.write_text(json.dumps({'runtime_sha256': 'a' * 64}))
    args = [str(executable), '--resources', str(resources), '--data-home', str(home),
            '--fixture-required', '--check-ready-only']
    refused = subprocess.run(args, capture_output=True, text=True)
    assert refused.returncode != 0
    assert 'fixture' in refused.stdout.lower()
    (home / '.voxhalo-bootstrap-fixture.json').write_text(json.dumps({
        'purpose': 'desktop-bootstrap-acceptance', 'synthetic_license_consent': True}))
    accepted = subprocess.run(args, capture_output=True, text=True)
    assert accepted.returncode == 0, accepted.stdout + accepted.stderr
    assert any(line.get('event') == 'ready-check' and line.get('ready') is True
               for line in map(json.loads, accepted.stdout.splitlines()))
    stamp.write_text(json.dumps({'runtime_sha256': 'd' * 64}))
    mismatch = subprocess.run(args, capture_output=True, text=True)
    assert mismatch.returncode != 0
    assert not (root / 'license-consent.json').exists(), 'readiness-only QA must never synthesize consent or start an installer'
