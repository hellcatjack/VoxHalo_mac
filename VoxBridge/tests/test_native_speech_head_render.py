from pathlib import Path
import json
import os
import shutil
import subprocess
import sys

import pytest


def _compile(root: Path, executable: Path, entry: str = 'NativeSpeechHeadRenderChecks') -> None:
    candidates = [Path(value) for value in [os.environ.get('SDKROOT', '')] if value]
    candidates += [Path('/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk'),
                   Path('/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.sdk')]
    sdk = next((candidate for candidate in candidates if candidate.is_dir()), None)
    assert sdk is not None, 'the render semantic probe requires the macOS 26 SDK'
    source = root / 'deploy/macos/app'
    subprocess.run(
        ['xcrun', 'swiftc', '-swift-version', '5', '-O', '-sdk', str(sdk),
         '-D', 'NATIVE_PLAYBACK_TESTING',
         *[str(source / f'{name}.swift') for name in
           ('AudioDevices', 'ServiceClient', 'NativeSpeechPlayer')],
         str(root / f'tests/macos/{entry}.swift'),
         str(root / 'tests/macos/NativeSpeechOutputProbe.swift'), '-o', str(executable)],
        check=True, capture_output=True, text=True,
    )


@pytest.mark.skipif(sys.platform != 'darwin' or not shutil.which('xcrun'), reason='requires macOS Swift')
def test_explicit_past_sample_start_can_discard_prefix_without_device_output(tmp_path):
    root = Path(__file__).resolve().parents[1]
    executable = tmp_path / 'NativeSpeechHeadRenderChecks'
    _compile(root, executable)
    report = tmp_path / 'offline.json'
    subprocess.run([str(executable), '--output', str(report)],
                   check=True, capture_output=True, text=True, timeout=20)
    result = json.loads(report.read_text())
    assert result['mode'] == 'offline-no-output'
    cases = {case['delta_frames']: case for case in result['cases']}
    assert cases[-2400]['prefix_ratio'] < 0.01
    assert cases[480]['prefix_ratio'] > 0.97
    assert all(case['player_sample_rate'] == 24000 for case in result['cases'])


@pytest.mark.skipif(sys.platform != 'darwin' or not shutil.which('xcrun'), reason='requires macOS Swift')
def test_pcm_head_comparison_calibrates_nonperiodic_voice_range_signal(tmp_path):
    root = Path(__file__).resolve().parents[1]
    executable = tmp_path / 'NativeSpeechOutputProbeChecks'
    _compile(root, executable, 'NativeSpeechOutputProbeChecks')
    subprocess.run([str(executable)], check=True, capture_output=True, text=True, timeout=20)


@pytest.mark.skipif(
    sys.platform != 'darwin' or os.environ.get('VOXBRIDGE_ALLOW_NATIVE_OUTPUT_PROBE') != '1',
    reason='explicit opt-in required: this probe plays synthetic markers through native output',
)
def test_native_realtime_submission_and_main_mixer_marker_observations(tmp_path):
    root = Path(__file__).resolve().parents[1]
    executable = tmp_path / 'NativeSpeechHeadRenderChecks'
    _compile(root, executable)
    report = tmp_path / 'realtime.json'
    subprocess.run([str(executable), '--realtime', '--output', str(report)],
                   check=True, capture_output=True, text=True, timeout=40)
    result = json.loads(report.read_text())
    assert result['drained'] and result['played_sequence'] == 19
    assert result['fully_queued_boundaries_exact']
    assert not result['failures']
    assert len(result['marker_measurements']) == 18
    # Timing and prefix ratios remain observations: forcing a pass threshold
    # here would conceal the exact native scheduling defect this probe seeks.
    assert all('marker_ratio' in marker for marker in result['marker_measurements'])
