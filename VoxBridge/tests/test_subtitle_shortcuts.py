from pathlib import Path
import shutil
import subprocess
import sys

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.skipif(sys.platform != 'darwin' or not shutil.which('xcrun'), reason='requires macOS Swift')
@pytest.mark.parametrize('check', ['SubtitleShortcutChecks', 'SubtitleHotKeyChecks', 'SubtitleShortcutOverlayChecks', 'SubtitleOverlayChecks'])
def test_subtitle_shortcut_behavior(check, tmp_path):
    source = ROOT / 'deploy/macos/app'
    names = ['NativeLocalization', 'SubtitlePreferences', 'SubtitleShortcuts']
    if check == 'SubtitleHotKeyChecks':
        names.append('SubtitleHotKeys')
    if check == 'SubtitleShortcutOverlayChecks':
        names += ['SubtitleState', 'SubtitleOverlay', 'ServiceClient', 'NativePreferences',
                  'AudioDevices', 'NativeSpeechPlayer']
    if check == 'SubtitleOverlayChecks':
        names += ['SubtitleState', 'SubtitleOverlay']
    executable = tmp_path / check
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-framework', 'AppKit',
                            '-framework', 'Carbon', '-framework', 'AVFoundation',
                            *[str(source / f'{name}.swift') for name in names],
                            str(ROOT / 'tests/macos' / f'{check}.swift'), '-o', str(executable)],
                           capture_output=True, text=True)
    assert built.returncode == 0, built.stdout + built.stderr
    ran = subprocess.run([str(executable)], capture_output=True, text=True, timeout=45)
    assert ran.returncode == 0, ran.stdout + ran.stderr
