from pathlib import Path
import shutil
import subprocess
import sys

import pytest


@pytest.mark.skipif(sys.platform != "darwin" or not shutil.which("xcrun"), reason="requires macOS Swift")
def test_native_drain_budget_tracks_real_progress_and_has_a_hard_cap(tmp_path):
    root = Path(__file__).resolve().parents[1]
    executable = tmp_path / "NativeSpeechDrainProgressChecks"
    sdk = Path("/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk")
    sdk_args = ["-sdk", str(sdk)] if sdk.is_dir() else []
    built = subprocess.run(
        ["xcrun", "swiftc", "-swift-version", "5", *sdk_args,
         str(root / "deploy/macos/app/NativeSpeechDrainProgress.swift"),
         str(root / "tests/macos/NativeSpeechDrainProgressChecks.swift"), "-o", str(executable)],
        capture_output=True, text=True, timeout=60,
    )
    assert built.returncode == 0, built.stdout + built.stderr
    run = subprocess.run([str(executable)], capture_output=True, text=True, timeout=10)
    assert run.returncode == 0, run.stdout + run.stderr
