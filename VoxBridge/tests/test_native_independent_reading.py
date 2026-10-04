from pathlib import Path
import ast
import os
import shutil
import subprocess
import sys

import pytest


@pytest.mark.skipif(sys.platform != "darwin" or not shutil.which("xcrun"), reason="requires macOS Swift and AppKit")
def test_native_completed_translation_reading_is_independent_of_audio(tmp_path):
    root = Path(__file__).resolve().parents[1]
    sdk = Path("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.sdk")
    assert sdk.is_dir(), "macOS 26 SDK is required"
    environment = dict(os.environ, SDKROOT=str(sdk))
    builder = ast.parse((root / "tools/build_macos_app.py").read_text())
    source_tuple = next(node for node in ast.walk(builder) if isinstance(node, ast.Tuple) and
                        any(isinstance(value, ast.Constant) and value.value == "main.swift" for value in node.elts))
    sources = [root / "deploy/macos/app" / value.value for value in source_tuple.elts if value.value != "main.swift"]
    executable = tmp_path / "NativeIndependentReadingChecks"
    built = subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-D", "NATIVE_PLAYBACK_TESTING", "-sdk", str(sdk),
        "-framework", "AppKit", "-framework", "AVFoundation", "-framework", "ScreenCaptureKit", "-framework", "CoreAudio",
        "-framework", "CoreImage", "-framework", "Carbon",
        *map(str, sources), str(root / "tests/macos/NativeIndependentReadingChecks.swift"), "-o", str(executable),
    ], capture_output=True, text=True, env=environment, timeout=120)
    assert built.returncode == 0, built.stdout + built.stderr
    run = subprocess.run([str(executable)], capture_output=True, text=True, env=environment, timeout=45)
    assert run.returncode == 0, run.stdout + run.stderr
