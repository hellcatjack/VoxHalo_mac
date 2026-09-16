"""Repair only manifest-owned models in an existing local installation.

The native App owns consent for first installation. This maintenance command
never installs a runtime, edits configuration, or downloads outside its manifest.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import importlib.util
import os
from pathlib import Path
import shutil
import signal
import sys
import tempfile

from install_desktop import (Cancelled, Events, Installer, install_lock, publish,
                             quarantine, recover_publication, regular_file, safe_path, sha256, verified)


def restore_generated(source, target, *, source_sha256, target_sha256, offset):
    """Reproduce the pinned ONNX float-speed artifact without loading ONNX.

    The published source and generated graph differ only at the speed input's
    TensorProto.elem_type byte (INT32=6 -> FLOAT=1). Both full SHA-256 values
    must match; an upstream graph change can never silently use this delta.
    """
    if sha256(source) != source_sha256:
        raise RuntimeError('Chinese source model checksum mismatch.')
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.restore-', dir=target.parent) as directory:
        temporary = Path(directory) / target.name
        shutil.copyfile(source, temporary)
        with temporary.open('r+b') as stream:
            stream.seek(offset)
            if stream.read(1) != b'\x06':
                raise RuntimeError('Chinese model does not match the pinned speed input.')
            stream.seek(offset); stream.write(b'\x01')
            stream.flush(); os.fsync(stream.fileno())
        if sha256(temporary) != target_sha256:
            raise RuntimeError('Restored Chinese model checksum mismatch; kept uninstalled.')
        publish(temporary, target)


class ModelRepair:
    def __init__(self, root, *, manifest=None, events=None, reserve_bytes=1024**3):
        self.root = Path(root).resolve()
        # The version's top-level models symlink is intentional. Inner links
        # are still rejected by the downloader's safe_path/regular_file guards.
        self.models = (self.root / 'models').resolve()
        if self.models.name != 'models':
            raise ValueError('The model storage folder must be named models.')
        self.events = events or Events(True)
        self.installer = Installer(self.root, self.models.parent,
            manifest_path=manifest or Path(__file__).with_name('runtime-assets.json'),
            wheel_manifest_path=None, events=self.events, reserve_bytes=reserve_bytes,
            repair_corrupt=True)

    def run(self, selected=None):
        installer = self.installer
        self.models = (self.root / 'models').resolve()
        if self.models.name != 'models':
            raise ValueError('The model storage folder must be named models.')
        installer.assets_root = self.models.parent
        installer.load_manifest()
        downloadable = [a for a in installer.manifest['assets'] if a['path'].startswith('models/')]
        generated = installer.manifest.get('generated')
        catalog = {a['path']: a for a in downloadable + ([generated] if generated else [])}
        paths = list(dict.fromkeys(selected or catalog))
        if any(path not in catalog for path in paths):
            raise ValueError('Only model files listed in the bundled manifest may be repaired.')
        if generated and generated['path'] in paths:
            source = 'models/kokoro/kokoro-v1.1-zh.onnx'
            if source not in catalog:
                raise ValueError('The generated model source is missing from the manifest.')
            if source not in paths:
                paths.insert(0, source)
        with install_lock(installer.assets_root):
            chosen = [catalog[path] for path in paths]
            # Preflight every selected path before performing any mutations.
            for asset in chosen:
                destination = safe_path(installer.assets_root, asset['path'])
                recover_publication(destination)
                regular_file(destination)
                regular_file(destination.with_name(destination.name + '.part'))
            required = 0
            for asset in chosen:
                destination = safe_path(installer.assets_root, asset['path'])
                if verified(destination, asset):
                    continue
                size = asset.get('size', 343_605_188)
                partial = destination.with_name(destination.name + '.part')
                resumed = partial.stat().st_size if partial.exists() and asset is not generated else 0
                # A complete partial may need restarting if its checksum fails.
                required += size - resumed if resumed < size else (0 if verified(partial, asset) else size)
            if shutil.disk_usage(installer.assets_root).free < required + installer.reserve_bytes:
                raise RuntimeError('Not enough free disk space to restore the selected models.')
            for asset in chosen:
                if asset is not generated:
                    installer.install_asset(asset)
                    self.events.emit('asset_ready', 'Model checksum verified.', asset['path'], asset['size'], asset['size'])
            if generated and generated['path'] in paths:
                target = safe_path(installer.assets_root, generated['path'])
                if not verified(target, generated):
                    if regular_file(target):
                        quarantine(target, self.events)
                    self.events.emit('preparing', 'Restoring the verified Chinese speech model.', generated['path'])
                    source_asset = catalog['models/kokoro/kokoro-v1.1-zh.onnx']
                    restore_generated(safe_path(installer.assets_root, source_asset['path']), target,
                        source_sha256=source_asset['sha256'], target_sha256=generated['sha256'], offset=343_605_097)
                self.events.emit('asset_ready', 'Model checksum verified.', generated['path'], target.stat().st_size, target.stat().st_size)
            self.events.emit('ready', 'Selected model files are ready.')


@contextlib.contextmanager
def maintenance_lock(path):
    regular_file(path)
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError('Another installation or service operation is running. Retry when it finishes.') from exc
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


@contextlib.contextmanager
def stopped_services(root):
    """Lock in bootstrap -> service -> assets order, as the installer does.

    The standalone App's version folder can be replaced during bootstrap before
    the Python installer takes the shared asset lock. Exclude that phase too.
    """
    bootstrap = maintenance_lock(root.parent.parent / '.bootstrap.lock') if root.parent.name == 'versions' else contextlib.nullcontext()
    with bootstrap:
        with _stopped_services(root):
            yield


@contextlib.contextmanager
def _stopped_services(root):
    service_root = root / 'VoxBridge'
    state = service_root / 'artifacts/macos-service'
    state.mkdir(parents=True, exist_ok=True)
    with maintenance_lock(state / 'control.lock'):
        try:
            sys.path.insert(0, str(service_root))
            spec = importlib.util.spec_from_file_location('voxhalo_model_service', service_root / 'tools/macos_service.py')
            service = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(service)
            if any(service.owned_pid(state / f'{name}.json') or service.ready(name) for name in ('app', 'translation')):
                raise RuntimeError('Stop interpretation and services before repairing models.')
            yield
        finally:
            sys.path.remove(str(service_root))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--asset', action='append', help='Manifest model path; omitted means all model files')
    args = parser.parse_args(argv)
    events = Events(True)
    def cancel(*_):
        raise Cancelled()
    old = {sig: signal.signal(sig, cancel) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        with stopped_services(args.root.resolve()):
            ModelRepair(args.root, events=events).run(args.asset)
    except (Cancelled, KeyboardInterrupt):
        events.emit('cancelled', 'Download paused; completed and partial files are retained.')
        return 130
    except Exception as exc:
        events.emit('error', str(exc))
        return 1
    finally:
        for sig, handler in old.items():
            signal.signal(sig, handler)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
