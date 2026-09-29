from pathlib import Path
import shutil
import subprocess
import sys

import pytest


@pytest.mark.skipif(sys.platform != 'darwin' or not shutil.which('xcrun'), reason='requires macOS Swift')
def test_ordered_reading_queue_preserves_every_sentence_and_reading_time(tmp_path):
    root = Path(__file__).resolve().parents[1]
    executable = tmp_path / 'ReadingSubtitleChecks'
    built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5',
                            str(root / 'deploy/macos/app/SubtitleState.swift'),
                            str(root / 'deploy/macos/app/SubtitlePreferences.swift'),
                            str(root / 'tests/macos/ReadingSubtitleChecks.swift'), '-o', str(executable)],
                           capture_output=True, text=True)
    assert built.returncode == 0, built.stdout + built.stderr
    run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=30)
    assert run.returncode == 0, run.stdout + run.stderr
