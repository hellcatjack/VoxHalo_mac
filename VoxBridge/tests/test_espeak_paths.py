"""Long installed paths must not trigger eSpeak's native process exit."""
from pathlib import Path
import importlib

import pytest


def test_long_path_copy_preserves_data_reuses_directory_and_cleans_only_owned_copy(tmp_path):
    spec = importlib.util.find_spec('voxbridge.tts.espeak_paths')
    assert spec is not None, 'Portable eSpeak data path helper is missing'
    module = importlib.import_module('voxbridge.tts.espeak_paths')
    source = tmp_path / ('long-' * 35) / 'espeak-ng-data'
    source.mkdir(parents=True)
    (source / 'phontab').write_bytes(b'complete pinned phoneme data\x00\xff')
    (source / 'voices').mkdir()
    (source / 'voices/en').write_bytes(b'exact voice settings')
    outside = tmp_path / 'keep'
    outside.write_bytes(b'untouched')
    try:
        short = module.portable_data_path(source)
        assert len(str(short.resolve()).encode('utf-8')) <= 140
        assert short != source
        assert not short.is_symlink()
        assert (short / 'phontab').read_bytes() == b'complete pinned phoneme data\x00\xff'
        assert (short / 'voices/en').read_bytes() == b'exact voice settings'
        assert module.portable_data_path(source) == short
        assert short.parent.stat().st_mode & 0o777 == 0o700
    finally:
        module.cleanup_copies()
    assert not short.exists()
    assert (source / 'phontab').read_bytes() == b'complete pinned phoneme data\x00\xff'
    assert outside.read_bytes() == b'untouched'


def test_short_path_preserves_existing_data_location():
    import tempfile
    from voxbridge.tts.espeak_paths import portable_data_path
    with tempfile.TemporaryDirectory(prefix='vox-espeak-test-', dir='/tmp') as folder:
        source = Path(folder).resolve() / 'espeak-ng-data'
        source.mkdir()
        assert portable_data_path(source) == source


def test_long_unicode_path_measures_bytes_not_characters(tmp_path):
    from voxbridge.tts.espeak_paths import portable_data_path, cleanup_copies
    source = tmp_path / ('语' * 55)
    source.mkdir()
    (source / 'phontab').write_bytes(b'exact')
    try:
        short = portable_data_path(source)
        assert len(str(short.resolve()).encode('utf-8')) <= 140
        assert (short / 'phontab').read_bytes() == b'exact'
    finally:
        cleanup_copies()


def test_copy_rejects_links_in_data_without_reading_external_file(tmp_path):
    from voxbridge.tts.espeak_paths import portable_data_path
    source = tmp_path / ('long-' * 35)
    source.mkdir()
    outside = tmp_path / 'outside'
    outside.write_bytes(b'private')
    (source / 'phontab').symlink_to(outside)
    with pytest.raises(ValueError, match='symlink'):
        portable_data_path(source)
    assert outside.read_bytes() == b'private'


def test_service_factory_phonemizes_with_long_installed_data_path(tmp_path):
    """Exercise real Tokenizer/native eSpeak; substitute only large ONNX weights."""
    import espeakng_loader
    import numpy as np
    import shutil
    import subprocess
    import sys
    source = tmp_path / ('long-' * 35) / 'espeak-ng-data'
    shutil.copytree(espeakng_loader.get_data_path(), source)
    model = tmp_path / 'fixture.onnx'
    model.write_bytes(b'weights are replaced by the small Session fixture')
    voices = tmp_path / 'voices.bin'
    with voices.open('wb') as out:
        np.savez(out, am_michael=np.ones((8, 1, 256), dtype=np.float32))
    program = '''
from pathlib import Path
from types import SimpleNamespace
import sys, espeakng_loader, onnxruntime
espeakng_loader.get_data_path = lambda: sys.argv[1]
onnxruntime.InferenceSession = lambda *args, **kwargs: SimpleNamespace(
    _model_path=sys.argv[2], get_inputs=lambda: [])
from voxbridge.tts.kokoro_onnx import KokoroOnnxSynthesizer
model = KokoroOnnxSynthesizer._create_cpu_kokoro(
    model_path=Path(sys.argv[2]), voices_path=Path(sys.argv[3]),
    vocab_config=None, cpu_threads=2, providers=('CPUExecutionProvider',))
phonemes = model.tokenizer.phonemize('Hello everyone', 'en-us')
assert phonemes and 'h' in phonemes
print(phonemes)
'''
    result = subprocess.run([sys.executable, '-c', program, str(source), str(model), str(voices)],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip()
