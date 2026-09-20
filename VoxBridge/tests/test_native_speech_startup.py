from pathlib import Path
import shutil
import subprocess
import sys

import pytest


@pytest.mark.skipif(sys.platform != 'darwin' or not shutil.which('xcrun'), reason='requires macOS Swift')
def test_output_startup_recovery_preserves_speech_and_bounds_retries(tmp_path):
    root = Path(__file__).resolve().parents[1]
    source = root / 'deploy/macos/app'
    executable = tmp_path / 'NativeSpeechStartupChecks'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '5',
                    *[str(source / f'{name}.swift') for name in
                      ('AudioDevices', 'ServiceClient', 'NativeSpeechPlayer')],
                    str(root / 'tests/macos/NativeSpeechStartupChecks.swift'), '-o', str(executable)],
                   check=True, capture_output=True, text=True)
    subprocess.run([str(executable)], check=True, capture_output=True, text=True, timeout=10)
