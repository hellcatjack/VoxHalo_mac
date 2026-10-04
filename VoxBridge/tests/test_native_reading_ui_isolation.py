from pathlib import Path
import ast
import os
import shutil
import subprocess
import sys

import pytest


@pytest.mark.skipif(sys.platform != "darwin" or not shutil.which("xcrun"), reason="requires macOS Swift and AppKit")
def test_native_meter_isolation_and_real_caption_geometry(tmp_path):
    root = Path(__file__).resolve().parents[1]
    sdk = Path("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.sdk")
    assert sdk.is_dir(), "macOS 26 SDK is required"
    environment = dict(os.environ, SDKROOT=str(sdk))
    builder = ast.parse((root / "tools/build_macos_app.py").read_text())
    source_tuple = next(node for node in ast.walk(builder) if isinstance(node, ast.Tuple) and
                        any(isinstance(value, ast.Constant) and value.value == "main.swift" for value in node.elts))
    sources = [root / "deploy/macos/app" / value.value for value in source_tuple.elts if value.value != "main.swift"]
    # Compile the real console class under a neutral name, omitting only the
    # executable launch block so this check cannot start the installed pipeline.
    console_source = tmp_path / "NativeConsoleForTesting.swift"
    console_classes, launch, _ = (root / "deploy/macos/app/main.swift").read_text().rpartition("\nMainActor.assumeIsolated {")
    assert launch
    console_source.write_text(console_classes)
    executable = tmp_path / "NativeReadingUIIsolationChecks"
    built = subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-D", "NATIVE_PLAYBACK_TESTING", "-D", "NATIVE_READING_UI_CHECKS", "-sdk", str(sdk),
        "-framework", "AppKit", "-framework", "AVFoundation", "-framework", "ScreenCaptureKit", "-framework", "CoreAudio",
        "-framework", "CoreImage", "-framework", "Carbon",
        *map(str, sources), str(console_source),
        str(root / "tests/macos/NativeReadingLeadReplay.swift"),
        str(root / "tests/macos/NativeSpeechOutputProbe.swift"),
        str(root / "tests/macos/NativeReadingUIIsolationChecks.swift"), "-o", str(executable),
    ], capture_output=True, text=True, env=environment, timeout=120)
    assert built.returncode == 0, built.stdout + built.stderr
    run = subprocess.run([str(executable)], capture_output=True, text=True, env=environment, timeout=45)
    assert run.returncode == 0, run.stdout + run.stderr
