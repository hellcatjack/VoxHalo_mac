"""Keep the pinned eSpeak data below its native 160-byte path buffer limit.

phonemizer resolves symlinks before calling eSpeak, so a short symlink cannot
solve this. A process-owned private copy preserves the exact bundled data and
is removed on normal exit. Source installations with short paths use their
original package data directly.
"""
from __future__ import annotations

import atexit
from pathlib import Path
import shutil
import sys
import tempfile
import threading

# Leave room for the native helper's appended '/espeak-ng-data' and NUL.
MAX_DATA_PATH_BYTES = 140
_copies: dict[Path, tuple[tempfile.TemporaryDirectory, Path]] = {}
_lock = threading.Lock()


def portable_data_path(source: Path) -> Path:
    source = Path(source).resolve(strict=True)
    if not source.is_dir():
        raise ValueError(f'eSpeak data is not a directory: {source}')
    if len(str(source).encode('utf-8')) <= MAX_DATA_PATH_BYTES:
        return source
    with _lock:
        if source in _copies:
            return _copies[source][1]
        if any(item.is_symlink() for item in source.rglob('*')):
            raise ValueError(f'eSpeak data contains a symlink: {source}')
        temporary_root = '/private/tmp' if sys.platform == 'darwin' else '/tmp'
        temporary = tempfile.TemporaryDirectory(prefix='voxhalo-espeak-', dir=temporary_root)
        destination = Path(temporary.name) / 'espeak-ng-data'
        try:
            if len(str(destination.resolve()).encode('utf-8')) > MAX_DATA_PATH_BYTES:
                raise RuntimeError('Temporary eSpeak data path exceeds the native path limit')
            shutil.copytree(source, destination)
        except BaseException:
            temporary.cleanup()
            raise
        _copies[source] = temporary, destination
        return destination


def cleanup_copies():
    """Release only private temporary directories created by this process."""
    with _lock:
        for temporary, _ in _copies.values():
            temporary.cleanup()
        _copies.clear()


def espeak_config():
    import espeakng_loader
    from kokoro_onnx.config import EspeakConfig

    return EspeakConfig(lib_path=espeakng_loader.get_library_path(),
                        data_path=str(portable_data_path(Path(espeakng_loader.get_data_path()))))


atexit.register(cleanup_copies)
