"""Resumable, checksum-pinned installation for the standalone VoxHalo desktop App.

The native App records explicit model consent in license-consent.json before
launching this script. stdout is exclusively JSON lines with --events-json;
subprocess diagnostics go to install-details.log in the version workspace.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import urllib.parse
import uuid
import zipfile

VERSION = '1.8.0'
MANIFEST = Path(__file__).with_name('runtime-assets.json')
WHEEL_MANIFEST = Path(__file__).with_name('desktop-wheels.json')
CHUNK = 256 * 1024


class Cancelled(KeyboardInterrupt):
    pass


class Events:
    def __init__(self, json_output=False, stream=None):
        self.json_output = json_output
        self.stream = stream if stream is not None else sys.stdout
        self.last_progress = 0.0

    def emit(self, phase, message, asset='', completed_bytes=0, total_bytes=0, *, progress=False):
        now = time.monotonic()
        if progress and now - self.last_progress < .2:
            return
        self.last_progress = now
        event = dict(phase=phase, message=str(message), asset=asset,
                     completed_bytes=int(completed_bytes), total_bytes=int(total_bytes))
        print(json.dumps(event, ensure_ascii=False) if self.json_output else message,
              file=self.stream, flush=True)


def regular_file(path: Path):
    """Never follow a link or write into an aliased, non-regular partial file."""
    if not os.path.lexists(path):
        return False
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode):
        raise ValueError(f'Symlink is not allowed: {path}')
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError(f'Asset must be a regular file without hard links: {path}')
    return True


def safe_path(root: Path, relative: str) -> Path:
    parts = relative.split('/')
    if (len(parts) < 2 or parts[0] not in ('models', 'downloads')
            or any(part in ('', '.', '..') for part in parts) or '\\' in relative):
        raise ValueError(f'Invalid asset path: {relative}')
    candidate = root
    for part in parts:
        candidate /= part
        if candidate.is_symlink():
            raise ValueError(f'Symlink is not allowed in asset path: {candidate}')
    return candidate


def sha256(path: Path) -> str:
    regular_file(path)
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verified(path: Path, asset: dict) -> bool:
    return (regular_file(path) and ('size' not in asset or path.stat().st_size == asset['size'])
            and sha256(path) == asset['sha256'])


@contextlib.contextmanager
def install_lock(assets_root: Path):
    assets_root.mkdir(parents=True, exist_ok=True)
    path = assets_root / '.install.lock'
    regular_file(path)
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a') as lock:
        if os.fstat(lock.fileno()).st_nlink != 1:
            raise ValueError(f'Lock must not have hard links: {path}')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError('Another installation is already running. Retry when it finishes.') from exc
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def publish(partial: Path, destination: Path):
    """Atomic no-replace publication also protects files created by other tools."""
    regular_file(partial)
    with partial.open('rb') as stream:
        os.fsync(stream.fileno())
    os.link(partial, destination, follow_symlinks=False)
    partial.unlink()
    sync_directory(destination.parent)


def recover_publication(destination: Path):
    """A crash between link/unlink leaves exactly these two names of one inode.

    Only remove the known .part alias when no third link exists. The completed
    file is still checked against its manifest before it can become ready.
    """
    partial = destination.with_name(destination.name + '.part')
    if not os.path.lexists(destination) or not os.path.lexists(partial):
        return
    target, source = destination.lstat(), partial.lstat()
    if (stat.S_ISREG(target.st_mode) and stat.S_ISREG(source.st_mode)
            and target.st_nlink == source.st_nlink == 2
            and (target.st_dev, target.st_ino) == (source.st_dev, source.st_ino)):
        partial.unlink()
        sync_directory(destination.parent)


def offline_environment():
    env = os.environ.copy()
    env.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1',
               DO_NOT_TRACK='1', TOKENIZERS_PARALLELISM='false', PYTHONUNBUFFERED='1')
    env.pop('PYTHONPATH', None)
    env.pop('PYTHONHOME', None)
    return env


def run_child(command, root: Path, *, timeout=600):
    """Kill/reap only this installer's process group on cancellation or timeout."""
    log_path = root / 'install-details.log'
    regular_file(log_path)
    fd = os.open(log_path, os.O_CREAT | os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a') as log:
        child = subprocess.Popen([str(arg) for arg in command], cwd=root / 'VoxBridge',
            env=offline_environment(), stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            start_new_session=True)
        try:
            result = child.wait(timeout=timeout)
            if result:
                raise RuntimeError(f'Runtime preparation failed (exit {result}); see {log_path}')
        finally:
            # A group can still contain descendants even when its leader exited.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGTERM)
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                child.poll()  # Reap the leader; descendants may remain in its group.
                try:
                    os.killpg(child.pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(.05)
            with contextlib.suppress(ProcessLookupError):
                os.killpg(child.pid, signal.SIGKILL)
            child.wait()


def quarantine(path: Path, events: Events):
    """Preserve only the explicitly selected, manifest-owned corrupt asset."""
    if path.is_symlink():
        raise ValueError(f'Symlink cannot be repaired: {path}')
    backup = path.with_name(path.name + '.invalid-' + time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())
                            + '-' + uuid.uuid4().hex[:10])
    path.rename(backup)
    sync_directory(path.parent)
    events.emit('preparing', f'Preserved the changed asset at {backup}; installing a verified replacement.')


def install_wheel(wheel: Path, asset: dict, site_packages: Path, *, repair_corrupt=False, events=None):
    """Install the two pinned binary packages without pip or executable hooks."""
    if not verified(wheel, asset):
        raise RuntimeError(f'Wheel checksum mismatch: {wheel}')
    package = {'imageio-ffmpeg': 'imageio_ffmpeg', 'espeakng-loader': 'espeakng_loader'}.get(asset['name'])
    if package is None or not re.fullmatch(r'[0-9]+(?:\.[0-9]+)*', asset['version']):
        raise ValueError('Unsupported desktop wheel package')
    allowed = {package, f'{package}-{asset["version"]}.dist-info'}
    for ancestor in (site_packages, *site_packages.parents):
        if ancestor.is_symlink():
            raise ValueError(f'Symlink in wheel destination: {ancestor}')
    site_packages.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(wheel) as archive, tempfile.TemporaryDirectory(prefix='.wheel-', dir=site_packages) as temp:
        entries = archive.infolist()
        seen = set()
        if sum(info.file_size for info in entries) > 256 * 1024**2:
            raise ValueError('Desktop wheel expands beyond the allowed size')
        for info in entries:
            parts = info.filename.rstrip('/').split('/')
            mode = info.external_attr >> 16
            if (any(part in ('', '.', '..') for part in parts) or '\\' in info.filename
                    or parts[0] not in allowed or info.filename in seen
                    or stat.S_ISLNK(mode) or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
                raise ValueError(f'Unsafe desktop wheel entry: {info.filename}')
            seen.add(info.filename)
        for info in entries:
            target = Path(temp) / info.filename
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as source, target.open('xb') as out:
                shutil.copyfileobj(source, out)
            target.chmod(0o755 if (info.external_attr >> 16) & 0o111 else 0o644)
        if not (Path(temp) / package / '__init__.py').is_file():
            raise ValueError('Desktop wheel is missing its expected package')
        # A previous interrupted run may have published one of the directories.
        # Verify it byte-for-byte; never replace a user's changed package.
        for name in sorted(allowed):
            source, destination = Path(temp) / name, site_packages / name
            if not source.is_dir():
                raise ValueError(f'Desktop wheel is missing {name}')
            if os.path.lexists(destination):
                if destination.is_symlink() or not destination.is_dir():
                    raise ValueError(f'Invalid wheel destination link: {destination}')
                if any(item.is_symlink() for item in destination.rglob('*')):
                    raise ValueError(f'Symlink in installed wheel package: {destination}')
                mismatch = None
                for item in source.rglob('*'):
                    installed = destination / item.relative_to(source)
                    if item.is_file() and (not regular_file(installed) or sha256(item) != sha256(installed)
                            or bool(item.stat().st_mode & 0o111) != bool(installed.stat().st_mode & 0o111)):
                        mismatch = installed
                        break
                if mismatch:
                    if not repair_corrupt:
                        raise RuntimeError(f'Existing wheel file differs; kept unchanged: {mismatch}. Use Repair and Retry in the App.')
                    quarantine(destination, events or Events())
            if not destination.exists():
                source.rename(destination)
        sync_directory(site_packages)


def prepare_runtime(installer):
    root = installer.root
    for relative in ('runtime', 'runtime/translation-llama', 'runtime/translation-llama/llama-b10809',
                     '.venv', '.venv/lib', '.venv/lib/python3.12', '.venv/lib/python3.12/site-packages',
                     '.venv/lib/python3.12/site-packages/pyopenjtalk'):
        directory = root / relative
        if directory.is_symlink():
            raise ValueError(f'Symlink in managed runtime directory: {directory}')
    for relative in ('.venv/bin/python', 'runtime/model-tools/bin/python'):
        executable = root / relative
        if executable.exists() and not executable.resolve().is_relative_to(root):
            raise ValueError(f'Runtime interpreter symlink points outside this version: {executable}')
    for asset in installer.wheel_assets:
        installer.events.emit('preparing', f'Installing the verified {asset["name"]} runtime.', asset['path'])
        install_wheel(safe_path(installer.assets_root, asset['path']), asset,
                      root / '.venv/lib/python3.12/site-packages',
                      repair_corrupt=installer.repair_corrupt, events=installer.events)
    installer.events.emit('preparing', 'Preparing the local translation runtime and Japanese dictionary.')
    # Execute the source-compatible helpers in the version's interpreter so the
    # dictionary is installed into that version's pyopenjtalk package.
    run_child([root / '.venv/bin/python', '-c',
        'import os, sys; from pathlib import Path; '
        'sys.path.insert(0, str(Path(sys.argv[1]) / "scripts")); '
        'import setup_assets, pyopenjtalk; root = Path(sys.argv[1]); '
        'dictionary = Path(os.fsdecode(pyopenjtalk.OPEN_JTALK_DICT_DIR)); '
        'assert dictionary.resolve().is_relative_to(root.resolve()), "Japanese dictionary points outside this version"; '
        'setup_assets.install_llama(root); setup_assets.install_japanese_dictionary(Path(sys.argv[2]))',
        root, installer.assets_root], root)
    generated = installer.manifest.get('generated')
    if not generated:
        return
    destination = safe_path(installer.assets_root, generated['path'])
    if regular_file(destination):
        if verified(destination, generated):
            return
        if not installer.repair_corrupt:
            raise RuntimeError(f'Existing generated model differs; kept unchanged: {destination}. Use Repair and Retry in the App.')
        quarantine(destination, installer.events)
    installer.events.emit('preparing', 'Preparing the verified Chinese speech model.', generated['path'])
    cached = safe_path(installer.cache, generated['path']) if installer.cache else None
    if cached and verified(cached, generated):
        installer.copy_verified(cached, destination, generated)
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    # The repair tool itself publishes atomically. Give it a private directory;
    # only our independent manifest verification may publish to shared models.
    with tempfile.TemporaryDirectory(prefix='.repair-', dir=destination.parent) as temp:
        output = Path(temp) / destination.name
        run_child([root / 'runtime/model-tools/bin/python', root / 'VoxBridge/tools/repair_kokoro_speed.py',
                   root / 'models/kokoro/kokoro-v1.1-zh.onnx', output], root)
        if not verified(output, generated):
            raise RuntimeError('Chinese float-speed model checksum mismatch; not installed.')
        publish(output, destination)


HEALTH_SCRIPT = r'''
import gc, json, socket, sys
from pathlib import Path
# Libraries must use the installed assets even if the computer is online.
def forbidden(*args, **kwargs):
    raise RuntimeError('Network access attempted during offline installation check')
socket.create_connection = forbidden
socket.socket.connect = forbidden
import mlx.core
import mlx_qwen3_asr
import onnxruntime as ort
import kokoro_onnx
import pyopenjtalk
import misaki.zh, misaki.ja
import voxbridge.cli.demo_streaming_ws
from mlx_qwen3_asr.tokenizer import Tokenizer
from tools import macos_service
root = Path(sys.argv[1])
macos_service.check_assets()
tokenizer = Tokenizer(str(root / 'models/qwen3-asr-0.6b'))
assert tokenizer.encode('Hello 你好'), 'The local Qwen tokenizer is unavailable'
assert pyopenjtalk.g2p('こんにちは'), 'Japanese dictionary is unavailable offline'
options = ort.SessionOptions()
options.intra_op_num_threads = 2
options.inter_op_num_threads = 1
for relative in ('models/vad/silero_vad.onnx', 'models/kokoro/kokoro-v1.0.onnx',
                 'models/kokoro/kokoro-v1.1-zh-float-speed.onnx'):
    model = ort.InferenceSession(str(root / relative), sess_options=options,
                                providers=['CPUExecutionProvider'])
    if relative.endswith('float-speed.onnx'):
        assert next(x for x in model.get_inputs() if x.name == 'speed').type == 'tensor(float)'
    del model
    gc.collect()
from voxbridge.tts.kokoro_onnx import KokoroTTSConfig, KokoroOnnxSynthesizer
kokoro = root / 'models/kokoro'
speech = KokoroOnnxSynthesizer(config=KokoroTTSConfig(
    english_model_path=kokoro / 'kokoro-v1.0.onnx',
    english_voices_path=kokoro / 'voices-v1.0.bin',
    chinese_model_path=kokoro / 'kokoro-v1.1-zh-float-speed.onnx',
    chinese_voices_path=kokoro / 'voices-v1.1-zh.bin',
    chinese_config_path=kokoro / 'config-v1.1-zh.json', cpu_threads=2))
audio = speech.synthesize('Hello. Local speech is ready.', 'en')
assert len(audio.wav_bytes) > 44, 'Local English phonemization and synthesis failed'
print('Offline service imports, tokenizer, ONNX models, Japanese dictionary and English speech synthesis passed.')
'''


def check_runtime(installer):
    installer.events.emit('verifying', 'Checking the service and local models with networking disabled.')
    root = installer.root
    run_child([root / '.venv/bin/python', '-c', HEALTH_SCRIPT, root], root)
    run_child([root / 'runtime/translation-llama/llama-b10809/llama-server', '--version'], root, timeout=30)


class Installer:
    def __init__(self, root: Path, assets_root: Path, *, manifest_path=MANIFEST,
                 wheel_manifest_path=WHEEL_MANIFEST, cache=None, events=None, reserve_bytes=1024**3,
                 repair_corrupt=False):
        self.root = Path(root).expanduser().resolve()
        self.assets_root = Path(assets_root).expanduser().resolve()
        self.manifest_path = Path(manifest_path)
        self.wheel_manifest_path = Path(wheel_manifest_path) if wheel_manifest_path else None
        self.cache = Path(cache).expanduser().resolve() if cache else None
        self.events = events or Events()
        self.reserve_bytes = reserve_bytes
        self.repair_corrupt = repair_corrupt
        self.manifest = {}
        self.manifest_sha256 = ''
        self.desktop_wheels_sha256 = ''
        self.wheel_assets = []

    def load_manifest(self):
        raw = self.manifest_path.read_bytes()
        self.manifest_sha256 = hashlib.sha256(raw).hexdigest()
        self.manifest = json.loads(raw)
        if self.wheel_manifest_path:
            wheel_raw = self.wheel_manifest_path.read_bytes()
            self.desktop_wheels_sha256 = hashlib.sha256(wheel_raw).hexdigest()
            self.wheel_assets = json.loads(wheel_raw)['assets']
        paths = set()
        for asset in [*self.manifest['assets'], *self.wheel_assets,
                      *([self.manifest['generated']] if self.manifest.get('generated') else [])]:
            safe_path(self.assets_root, asset['path'])
            if asset['path'] in paths:
                raise ValueError(f'Duplicate asset path: {asset["path"]}')
            paths.add(asset['path'])
            if not re.fullmatch('[0-9a-f]{64}', asset['sha256']):
                raise ValueError(f'Invalid asset checksum: {asset["path"]}')
            if 'size' in asset and (type(asset['size']) is not int or asset['size'] <= 0):
                raise ValueError(f'Invalid asset size: {asset["path"]}')
        for asset in [*self.manifest['assets'], *self.wheel_assets]:
            if 'size' not in asset or urllib.parse.urlsplit(asset['url']).scheme not in ('https', 'http'):
                raise ValueError(f'Invalid download metadata: {asset["path"]}')

    def check_consent(self):
        path = self.root / 'license-consent.json'
        try:
            regular_file(path)
            consent = json.loads(path.read_text())
            if (consent['version'] == VERSION and consent['manifest_sha256'] == self.manifest_sha256
                    and consent['accepted'] is True and consent['territory_eligible'] is True):
                return
        except (OSError, ValueError, KeyError, TypeError):
            pass
        raise RuntimeError('Model license consent is required in the App before installation.')

    def link_assets(self):
        if self.root == self.assets_root or self.assets_root.is_relative_to(self.root):
            raise ValueError('Shared assets must be outside the version workspace.')
        for name in ('models', 'downloads'):
            shared = self.assets_root / name
            if shared.is_symlink():
                raise ValueError(f'Symlink is not allowed: {shared}')
            shared.mkdir(parents=True, exist_ok=True)
            link = self.root / name
            if os.path.lexists(link):
                if not link.is_symlink() or link.resolve() != shared:
                    raise ValueError(f'Workspace link differs; kept unchanged: {link}')
            else:
                link.symlink_to(os.path.relpath(shared, self.root), target_is_directory=True)

    def check_disk(self):
        remaining = 0
        for asset in [*self.manifest['assets'], *self.wheel_assets]:
            destination = safe_path(self.assets_root, asset['path'])
            partial = destination.with_name(destination.name + '.part')
            recover_publication(destination)
            regular_file(destination)
            regular_file(partial)
            if not destination.exists() or (self.repair_corrupt and not verified(destination, asset)):
                resumed = min(partial.stat().st_size, asset['size']) if partial.exists() else 0
                # A complete partial may be corrupt and need to be downloaded again.
                remaining += asset['size'] - resumed if resumed < asset['size'] else asset['size']
        generated = self.manifest.get('generated')
        if generated:
            recover_publication(safe_path(self.assets_root, generated['path']))
        if generated and (not safe_path(self.assets_root, generated['path']).exists() or self.repair_corrupt):
            remaining += 400 * 1024**2
        if shutil.disk_usage(self.assets_root).free < remaining + self.reserve_bytes:
            raise RuntimeError(f'Not enough free disk space; need {(remaining+self.reserve_bytes)/1024**3:.1f} GB.')
        if shutil.disk_usage(self.root).free < self.reserve_bytes:
            raise RuntimeError('Not enough free disk space to prepare the version runtime.')

    def copy_verified(self, source, destination, asset):
        partial = destination.with_name(destination.name + '.part')
        regular_file(partial)
        destination.parent.mkdir(parents=True, exist_ok=True)
        self.events.emit('preparing', 'Copying a verified local asset.', asset['path'], 0, source.stat().st_size)
        fd = os.open(partial, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with source.open('rb') as src, os.fdopen(fd, 'wb') as dst:
            completed = 0
            while chunk := src.read(CHUNK):
                dst.write(chunk)
                completed += len(chunk)
                self.events.emit('preparing', 'Copying a verified local asset.', asset['path'],
                                 completed, source.stat().st_size, progress=True)
        if not verified(partial, asset):
            raise RuntimeError(f'Cached asset checksum changed during copy: {source}')
        publish(partial, destination)

    def download(self, asset, destination):
        partial = destination.with_name(destination.name + '.part')
        regular_file(partial)
        destination.parent.mkdir(parents=True, exist_ok=True)
        offset = partial.stat().st_size if partial.exists() else 0
        if offset >= asset['size']:
            if verified(partial, asset):
                publish(partial, destination)
                return
            offset = 0  # Only our unpublished partial may be restarted.
        headers = {'Accept-Encoding': 'identity', 'User-Agent': 'VoxHalo/1.8.0'}
        if offset:
            headers['Range'] = f'bytes={offset}-'
        self.events.emit('downloading', 'Downloading a pinned model asset.', asset['path'], offset, asset['size'])
        request = urllib.request.Request(asset['url'], headers=headers)
        with urllib.request.urlopen(request, timeout=30) as response:
            if response.status == 206:
                expected = f'bytes {offset}-{asset["size"]-1}/{asset["size"]}'
                if response.headers.get('Content-Range') != expected:
                    raise RuntimeError(f'Server returned an invalid byte range: {asset["path"]}')
            elif response.status == 200:
                offset = 0  # Range ignored: replace the partial, never append the entire file.
            else:
                raise RuntimeError(f'Unexpected HTTP status {response.status}: {asset["path"]}')
            length = response.headers.get('Content-Length')
            if length is not None and int(length) != asset['size'] - offset:
                raise RuntimeError(f'Server returned an unexpected asset size: {asset["path"]}')
            flags = os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | (os.O_APPEND if offset else os.O_TRUNC)
            fd = os.open(partial, flags, 0o600)
            with os.fdopen(fd, 'wb') as stream:
                completed = offset
                while chunk := response.read(CHUNK):
                    if completed + len(chunk) > asset['size']:
                        raise RuntimeError(f'Download exceeds pinned size: {asset["path"]}')
                    stream.write(chunk)
                    completed += len(chunk)
                    self.events.emit('downloading', 'Downloading a pinned model asset.', asset['path'],
                                     completed, asset['size'], progress=True)
                stream.flush()
                os.fsync(stream.fileno())
            if completed != asset['size']:
                raise RuntimeError(f'Download interrupted; retry to resume: {asset["path"]}')
        self.events.emit('verifying', 'Checking the downloaded SHA-256.', asset['path'], completed, asset['size'])
        if not verified(partial, asset):
            raise RuntimeError(f'Download checksum mismatch; not installed: {asset["path"]}')
        publish(partial, destination)

    def install_asset(self, asset):
        destination = safe_path(self.assets_root, asset['path'])
        if regular_file(destination):
            self.events.emit('verifying', 'Checking an existing model asset.', asset['path'], 0, asset['size'])
            if verified(destination, asset):
                return
            if not self.repair_corrupt:
                raise RuntimeError(f'Existing asset differs; kept unchanged: {destination}. Use Repair and Retry in the App.')
            quarantine(destination, self.events)
        cached = safe_path(self.cache, asset['path']) if self.cache else None
        if cached and verified(cached, asset):
            self.copy_verified(cached, destination, asset)
        else:
            self.download(asset, destination)

    def run(self):
        self.root.mkdir(parents=True, exist_ok=True)
        self.events.emit('checking', 'Checking installation, model licenses and available storage.')
        with install_lock(self.assets_root):
            marker = self.root / 'installed.json'
            regular_file(marker)
            self.load_manifest()
            self.check_consent()
            self.link_assets()
            self.check_disk()
            marker.unlink(missing_ok=True)
            for asset in [*self.manifest['assets'], *self.wheel_assets]:
                self.install_asset(asset)
            prepare_runtime(self)
            check_runtime(self)
            record = dict(version=VERSION, manifest_sha256=self.manifest_sha256,
                          installed_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
            if self.desktop_wheels_sha256:
                record['desktop_wheels_sha256'] = self.desktop_wheels_sha256
            with tempfile.NamedTemporaryFile(mode='w', prefix='.installed-', dir=self.root, delete=False) as out:
                temporary = Path(out.name)
                try:
                    json.dump(record, out)
                    out.write('\n')
                    out.flush()
                    os.fsync(out.fileno())
                    # Readiness is an installer-owned record, so one rename is
                    # preferable to a no-replace two-name asset publication.
                    os.replace(temporary, marker)
                    sync_directory(self.root)
                finally:
                    temporary.unlink(missing_ok=True)
            self.events.emit('ready', 'All local models and the desktop runtime are ready.')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--assets-root', type=Path, required=True)
    parser.add_argument('--events-json', action='store_true')
    parser.add_argument('--cache', type=Path, help='Copy assets from a checksum-verified existing workspace')
    parser.add_argument('--repair-corrupt', action='store_true',
                        help='Preserve corrupt managed assets as named backups and install verified replacements')
    args = parser.parse_args(argv)
    events = Events(json_output=args.events_json)
    def cancelled(signum, frame):
        raise Cancelled()
    old = {sig: signal.signal(sig, cancelled) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        Installer(args.root, args.assets_root, cache=args.cache, events=events,
                  repair_corrupt=args.repair_corrupt).run()
    except (Cancelled, KeyboardInterrupt):
        events.emit('error', 'Installation cancelled; retry to resume.')
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
