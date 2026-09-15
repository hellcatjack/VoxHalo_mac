"""Install checksum-pinned assets; reuse a verified local installation if requested."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path(__file__).with_name('runtime-assets.json')


def digest(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def asset_path(root: Path, relative: str) -> Path:
    candidate = (root / relative).resolve()
    if not candidate.is_relative_to(root.resolve()):
        raise ValueError(f'Asset path escapes installation: {relative}')
    return candidate


def verified(path: Path, asset: dict) -> bool:
    return (path.is_file() and ('size' not in asset or path.stat().st_size == asset['size'])
            and digest(path) == asset['sha256'])


def install_asset(root: Path, asset: dict, cache: Path | None = None) -> None:
    destination = asset_path(root, asset['path'])
    if destination.exists():
        if not verified(destination, asset):
            raise RuntimeError(f'Existing asset differs; kept unchanged: {destination}')
        print(f"Verified {asset['path']}", flush=True)
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(destination.name + '.part')
    if cache is not None and verified(asset_path(cache, asset['path']), asset):
        shutil.copyfile(asset_path(cache, asset['path']), partial)
    else:
        subprocess.run(['curl', '--fail', '--location', '--silent', '--show-error',
                        '--retry', '3', '--connect-timeout', '20',
                        '--output', str(partial), asset['url']], check=True)
    if not verified(partial, asset):
        raise RuntimeError(f'Download checksum mismatch; not installed: {partial}')
    partial.replace(destination)
    print(f"Installed {asset['path']}", flush=True)


def install_llama(root: Path) -> None:
    destination = root / 'runtime/translation-llama/llama-b10809'
    if (destination / 'llama-server').is_file():
        return
    if destination.exists():
        raise RuntimeError(f'Incomplete llama runtime; kept unchanged: {destination}')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix='.llama-') as temp:
        with tarfile.open(root / 'downloads/llama-b10809-bin-macos-arm64.tar.gz') as archive:
            archive.extractall(temp, filter='data')
        extracted = Path(temp) / 'llama-b10809'
        if not (extracted / 'llama-server').is_file():
            raise RuntimeError('Unexpected llama.cpp archive layout')
        extracted.rename(destination)


def install_japanese_dictionary(root: Path) -> None:
    """Populate pyopenjtalk's offline dictionary from the verified release."""
    import pyopenjtalk
    asset = next(a for a in json.loads(MANIFEST.read_text())['assets']
                 if a['path'] == 'downloads/open_jtalk_dic_utf_8-1.11.tar.gz')
    archive_path = asset_path(root, asset['path'])
    if not verified(archive_path, asset):
        raise RuntimeError('Japanese dictionary archive checksum mismatch')
    destination = Path(os.fsdecode(pyopenjtalk.OPEN_JTALK_DICT_DIR))
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent, prefix='.openjtalk-') as temp:
        with tarfile.open(archive_path) as archive:
            archive.extractall(temp, filter='data')
        extracted = Path(temp) / 'open_jtalk_dic_utf_8-1.11'
        if not (extracted / 'sys.dic').is_file():
            raise RuntimeError('Unexpected Japanese dictionary archive layout')
        if destination.exists():
            for source in extracted.rglob('*'):
                if source.is_file():
                    installed = destination / source.relative_to(extracted)
                    if not installed.is_file() or digest(source) != digest(installed):
                        raise RuntimeError(f'Japanese dictionary differs; kept unchanged: {installed}')
        else:
            extracted.rename(destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--cache', type=Path, default=os.environ.get('VOXHALO_ASSET_CACHE'),
                        help='Existing workspace whose verified assets may be copied')
    parser.add_argument('--verify-only', action='store_true', help='Check all assets without changes')
    parser.add_argument('--repair-python', type=Path, default=ROOT / 'runtime/model-tools/bin/python')
    args = parser.parse_args()
    root = args.root.expanduser().resolve()
    cache = args.cache.expanduser().resolve() if args.cache else None
    manifest = json.loads(MANIFEST.read_text())
    if args.verify_only:
        failures = [a['path'] for a in [*manifest['assets'], manifest['generated']]
                    if not verified(asset_path(root, a['path']), a)]
        if failures:
            raise SystemExit('Missing or different assets:\n' + '\n'.join(failures))
        print('All downloaded assets and the repaired Chinese model match SHA-256.')
        return
    for asset in manifest['assets']:
        install_asset(root, asset, cache)
    install_llama(root)
    install_japanese_dictionary(root)
    repaired = asset_path(root, manifest['generated']['path'])
    if not repaired.exists():
        subprocess.run([str(args.repair_python), str(ROOT / 'VoxBridge/tools/repair_kokoro_speed.py'),
                        str(root / 'models/kokoro/kokoro-v1.1-zh.onnx'), str(repaired)], check=True)
    if not verified(repaired, manifest['generated']):
        raise RuntimeError('Chinese float-speed model differs from the verified build.')
    print('All local runtime assets are ready.')


if __name__ == '__main__':
    main()
