from pathlib import Path
import os
import shutil
import subprocess
import sys

import pytest


@pytest.mark.skipif(sys.platform != 'darwin' or not shutil.which('xcrun'), reason='requires macOS Swift and AppKit')
def test_full_native_session_history_and_reading_window(tmp_path):
    root = Path(__file__).resolve().parents[1]
    executable = tmp_path / 'SubtitleHistoryChecks'
    sdk = next((path for path in (
        Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk'),
        Path('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.sdk'),
    ) if path.is_dir()), None)
    assert sdk is not None, 'MacOSX26 SDK is required for the native checks'
    environment = dict(os.environ, SDKROOT=str(sdk))
    built = subprocess.run([
        'xcrun', 'swiftc', '-swift-version', '5', '-sdk', str(sdk), '-framework', 'AppKit',
        str(root / 'deploy/macos/app/NativeLocalization.swift'),
        str(root / 'deploy/macos/app/SubtitleHistory.swift'),
        str(root / 'tests/macos/SubtitleHistoryChecks.swift'), '-o', str(executable),
    ], capture_output=True, text=True, env=environment, timeout=90)
    assert built.returncode == 0, built.stdout + built.stderr
    run = subprocess.run([str(executable)], capture_output=True, text=True, env=environment, timeout=30)
    assert run.returncode == 0, run.stdout + run.stderr
