from pathlib import Path
import shutil
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.skipif(sys.platform != 'darwin' or not shutil.which('xcrun'), reason='requires macOS Swift')
def test_inventory_detects_deleted_replaced_and_shared_files(tmp_path):
    source = ROOT / 'deploy/macos/app/ModelInventory.swift'
    assert source.is_file(), 'The App must inspect actual model files'
    exe = tmp_path / 'ModelInventoryChecks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(source),
                    str(ROOT / 'tests/macos/ModelInventoryChecks.swift'), '-o', str(exe)],
                   check=True, capture_output=True, text=True)
    result = subprocess.run([str(exe)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


@pytest.mark.skipif(sys.platform != 'darwin' or not shutil.which('xcrun'), reason='requires macOS Swift')
def test_repair_requires_fresh_service_gate_and_respects_cancel(tmp_path):
    source = ROOT / 'deploy/macos/app'
    assert (source / 'ModelManager.swift').is_file(), 'Repair must coordinate with native services'
    exe = tmp_path / 'ModelManagerChecks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5',
                    *[str(source / name) for name in ('NativeLocalization.swift', 'DesktopInstallation.swift',
                                                      'ModelInventory.swift', 'ModelManager.swift')],
                    str(ROOT / 'tests/macos/ModelManagerChecks.swift'), '-o', str(exe)],
                   check=True, capture_output=True, text=True)
    result = subprocess.run([str(exe)], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
