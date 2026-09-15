"""Small HTTP fault fixtures never download or load public models."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/install_desktop.py'

@pytest.fixture
def installer():
    assert SCRIPT.is_file(), 'Desktop installer is not implemented'
    spec = importlib.util.spec_from_file_location('desktop_installer', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

@pytest.fixture
def server():
    payload = bytes(range(256)) * 4096
    state = {'payload': payload, 'ranges': [], 'mode': 'range', 'interrupt': False}
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass
        def do_GET(self):
            start = 0
            requested = self.headers.get('Range')
            state['ranges'].append(requested)
            if requested and state['mode'] != 'ignore':
                start = int(requested.removeprefix('bytes=').split('-')[0])
                self.send_response(206)
                offset = start + 1 if state['mode'] == 'bad-range' else start
                self.send_header('Content-Range', f'bytes {offset}-{len(payload)-1}/{len(payload)}')
            else:
                self.send_response(200)
            body = state['payload'][start:]
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if state['interrupt']:
                state['interrupt'] = False
                self.wfile.write(body[:len(body)//2])
                self.wfile.flush()
                self.connection.shutdown(socket.SHUT_RDWR)
                return
            with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                if state.get('slow'):
                    import time
                    for offset in range(0, len(body), 65536):
                        self.wfile.write(body[offset:offset+65536])
                        self.wfile.flush()
                        time.sleep(.1)
                    return
                self.wfile.write(body)
    http = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=http.serve_forever, daemon=True)
    thread.start()
    yield state, f'http://127.0.0.1:{http.server_port}/model'
    http.shutdown()
    http.server_close()
    thread.join()

def make_install(tmp_path, installer, server, monkeypatch):
    state, url = server
    root = tmp_path / 'version with spaces'
    assets = tmp_path / 'shared assets'
    root.mkdir()
    manifest = root / 'manifest.json'
    manifest.write_text(json.dumps({'assets': [{'path': 'models/tiny/model.bin',
        'url': url, 'size': len(state['payload']),
        'sha256': hashlib.sha256(state['payload']).hexdigest()}]}))
    (root / 'license-consent.json').write_text(json.dumps({'version': '1.8.0',
        'manifest_sha256': hashlib.sha256(manifest.read_bytes()).hexdigest(),
        'accepted': True, 'territory_eligible': True}))
    monkeypatch.setattr(installer, 'prepare_runtime', lambda *args: None)
    monkeypatch.setattr(installer, 'check_runtime', lambda *args: None)
    output = io.StringIO()
    instance = installer.Installer(root, assets, manifest_path=manifest,
        wheel_manifest_path=None,
        events=installer.Events(json_output=True, stream=output), reserve_bytes=0)
    return instance, root, assets, output

def test_ready_is_atomic_after_verified_assets_and_health(tmp_path, installer, server, monkeypatch):
    instance, root, assets, output = make_install(tmp_path, installer, server, monkeypatch)
    def health(*_):
        assert not (root / 'installed.json').exists()
        assert (root / 'models/tiny/model.bin').read_bytes() == server[0]['payload']
    monkeypatch.setattr(installer, 'check_runtime', health)
    instance.run()
    marker = json.loads((root / 'installed.json').read_text())
    assert marker['version'] == '1.8.0'
    assert marker['manifest_sha256'] == hashlib.sha256(instance.manifest_path.read_bytes()).hexdigest()
    assert (root / 'models').resolve() == assets / 'models'
    assert not list(assets.rglob('*.part'))
    events = [json.loads(line) for line in output.getvalue().splitlines()]
    assert events[-1]['phase'] == 'ready'
    assert all(set(('phase', 'message', 'asset', 'completed_bytes', 'total_bytes')) <= set(e) for e in events)

@pytest.mark.parametrize('mode', ['range', 'ignore'])
def test_interrupted_download_resumes_without_duplicating_bytes(tmp_path, installer, server, monkeypatch, mode):
    instance, root, assets, _ = make_install(tmp_path, installer, server, monkeypatch)
    server[0].update(interrupt=True, mode=mode)
    with pytest.raises((OSError, RuntimeError)):
        instance.run()
    partial = assets / 'models/tiny/model.bin.part'
    assert 0 < partial.stat().st_size < len(server[0]['payload'])
    assert not (root / 'installed.json').exists()
    saved_size = partial.stat().st_size
    instance.run()
    assert server[0]['ranges'][-1] == f'bytes={saved_size}-'
    assert (assets / 'models/tiny/model.bin').read_bytes() == server[0]['payload']

def test_incorrect_range_is_rejected_without_appending(tmp_path, installer, server, monkeypatch):
    instance, _, assets, _ = make_install(tmp_path, installer, server, monkeypatch)
    partial = assets / 'models/tiny/model.bin.part'
    partial.parent.mkdir(parents=True)
    partial.write_bytes(server[0]['payload'][:100])
    server[0]['mode'] = 'bad-range'
    with pytest.raises(RuntimeError, match='range'):
        instance.run()
    assert partial.stat().st_size == 100

def test_digest_mismatch_does_not_publish_and_retry_recovers(tmp_path, installer, server, monkeypatch):
    instance, root, assets, _ = make_install(tmp_path, installer, server, monkeypatch)
    good = server[0]['payload']
    server[0]['payload'] = b'x' * len(good)
    with pytest.raises(RuntimeError, match='checksum'):
        instance.run()
    assert not (assets / 'models/tiny/model.bin').exists()
    assert not (root / 'installed.json').exists()
    server[0]['payload'] = good
    instance.run()
    assert (assets / 'models/tiny/model.bin').read_bytes() == good

def test_existing_corruption_is_preserved_and_stale_ready_removed(tmp_path, installer, server, monkeypatch):
    instance, root, assets, _ = make_install(tmp_path, installer, server, monkeypatch)
    installed = assets / 'models/tiny/model.bin'
    installed.parent.mkdir(parents=True)
    installed.write_bytes(b'keep original')
    (root / 'installed.json').write_text('{}')
    with pytest.raises(RuntimeError, match='kept unchanged'):
        instance.run()
    assert installed.read_bytes() == b'keep original'
    assert not (root / 'installed.json').exists()
    assert not server[0]['ranges']

def test_health_failure_never_marks_ready(tmp_path, installer, server, monkeypatch):
    instance, root, _, _ = make_install(tmp_path, installer, server, monkeypatch)
    def fail(*_):
        raise RuntimeError('offline model check failed')
    monkeypatch.setattr(installer, 'check_runtime', fail)
    with pytest.raises(RuntimeError, match='offline model'):
        instance.run()
    assert not (root / 'installed.json').exists()

def test_duplicate_installer_does_not_remove_running_install_ready(tmp_path, installer, server, monkeypatch):
    instance, root, assets, _ = make_install(tmp_path, installer, server, monkeypatch)
    with installer.install_lock(assets):
        (root / 'installed.json').write_text('owned by running installer')
        with pytest.raises(RuntimeError, match='already running'):
            instance.run()
        assert (root / 'installed.json').read_text() == 'owned by running installer'
    assert not server[0]['ranges']

@pytest.mark.parametrize('relative', ['../outside', '/tmp/outside', 'models/../outside', 'runtime/x', 'models//x'])
def test_manifest_rejects_traversal_and_unowned_paths(tmp_path, installer, server, monkeypatch, relative):
    instance, _, _, _ = make_install(tmp_path, installer, server, monkeypatch)
    manifest = json.loads(instance.manifest_path.read_text())
    manifest['assets'][0]['path'] = relative
    instance.manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(ValueError, match='path'):
        instance.run()
    assert not server[0]['ranges']

@pytest.mark.parametrize('kind', ['parent', 'destination', 'partial', 'workspace'])
def test_symlinks_cannot_write_outside_shared_assets(tmp_path, installer, server, monkeypatch, kind):
    instance, root, assets, _ = make_install(tmp_path, installer, server, monkeypatch)
    outside = tmp_path / 'outside'
    outside.mkdir()
    sentinel = outside / 'sentinel'
    sentinel.write_bytes(b'keep')
    model = assets / 'models/tiny/model.bin'
    model.parent.mkdir(parents=True)
    if kind == 'parent':
        model.parent.rmdir()
        model.parent.symlink_to(outside, target_is_directory=True)
    elif kind == 'workspace':
        (root / 'models').symlink_to(outside, target_is_directory=True)
    else:
        (model if kind == 'destination' else model.with_suffix('.bin.part')).symlink_to(sentinel)
    with pytest.raises((ValueError, RuntimeError), match='[Ll]ink|[Ss]ymlink'):
        instance.run()
    assert sentinel.read_bytes() == b'keep'
    assert not server[0]['ranges']

def test_requires_current_explicit_model_consent(tmp_path, installer, server, monkeypatch):
    instance, root, _, _ = make_install(tmp_path, installer, server, monkeypatch)
    (root / 'license-consent.json').unlink()
    with pytest.raises(RuntimeError, match='consent'):
        instance.run()
    assert not server[0]['ranges']

def test_disk_shortage_fails_before_downloading(tmp_path, installer, server, monkeypatch):
    instance, _, _, _ = make_install(tmp_path, installer, server, monkeypatch)
    monkeypatch.setattr(installer.shutil, 'disk_usage', lambda _: type('Usage', (), {'free': 0})())
    with pytest.raises(RuntimeError, match='space'):
        instance.run()
    assert not server[0]['ranges']


def wheel_file(tmp_path, entries):
    import zipfile
    path = tmp_path / 'tiny.whl'
    with zipfile.ZipFile(path, 'w') as archive:
        for name, data, mode in entries:
            info = zipfile.ZipInfo(name)
            info.external_attr = mode << 16
            archive.writestr(info, data)
    return path


def test_wheel_extracts_only_verified_packages_and_preserves_executable(tmp_path, installer):
    wheel = wheel_file(tmp_path, [('imageio_ffmpeg/__init__.py', b'x = 1', 0o100644),
        ('imageio_ffmpeg/binaries/ffmpeg-test', b'binary', 0o100755),
        ('imageio_ffmpeg-0.6.0.dist-info/METADATA', b'Version: 0.6.0', 0o100644)])
    asset = {'name': 'imageio-ffmpeg', 'version': '0.6.0', 'sha256': hashlib.sha256(wheel.read_bytes()).hexdigest()}
    target = tmp_path / 'site-packages'
    installer.install_wheel(wheel, asset, target)
    binary = target / 'imageio_ffmpeg/binaries/ffmpeg-test'
    assert binary.read_bytes() == b'binary'
    assert binary.stat().st_mode & 0o111
    installer.install_wheel(wheel, asset, target)
    binary.write_bytes(b'keep altered file')
    with pytest.raises(RuntimeError, match='kept unchanged'):
        installer.install_wheel(wheel, asset, target)
    assert binary.read_bytes() == b'keep altered file'


@pytest.mark.parametrize('bad_name,mode', [('../escaped', 0o100644),
    ('/tmp/escaped', 0o100644), ('other_package/file.py', 0o100644),
    ('imageio_ffmpeg/linked', 0o120777), ('imageio_ffmpeg/../../escaped', 0o100644)])
def test_wheel_rejects_unsafe_entries_before_publication(tmp_path, installer, bad_name, mode):
    wheel = wheel_file(tmp_path, [('imageio_ffmpeg/__init__.py', b'ok', 0o100644),
                                (bad_name, b'outside', mode)])
    asset = {'name': 'imageio-ffmpeg', 'version': '0.6.0', 'sha256': hashlib.sha256(wheel.read_bytes()).hexdigest()}
    target = tmp_path / 'site-packages'
    with pytest.raises(ValueError, match='wheel'):
        installer.install_wheel(wheel, asset, target)
    assert not (target / 'imageio_ffmpeg').exists()


def test_unverified_wheel_cannot_be_installed(tmp_path, installer):
    wheel = wheel_file(tmp_path, [('imageio_ffmpeg/__init__.py', b'x', 0o100644)])
    with pytest.raises(RuntimeError, match='checksum'):
        installer.install_wheel(wheel, {'name': 'imageio-ffmpeg', 'version': '0.6.0',
                                      'sha256': '0'*64}, tmp_path / 'site-packages')


def test_progress_is_throttled_but_phase_changes_are_reported(installer):
    output = io.StringIO()
    events = installer.Events(True, output)
    events.emit('downloading', 'start')
    for _ in range(100):
        events.emit('downloading', 'progress', progress=True)
    events.emit('verifying', 'digest')
    assert [json.loads(line)['phase'] for line in output.getvalue().splitlines()] == ['downloading', 'verifying']


def test_sigterm_stops_and_reaps_owned_child_group(tmp_path, installer):
    import os
    import signal
    import subprocess
    import sys
    import time
    (tmp_path / 'VoxBridge').mkdir()
    pidfile = tmp_path / 'child.pid'
    command = [sys.executable, '-c',
        'import os, signal, time, pathlib; '
        'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
        f'pathlib.Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(60)']
    program = ('import importlib.util, pathlib, signal; '
        f's=importlib.util.spec_from_file_location("installer", {str(SCRIPT)!r}); '
        'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
        'signal.signal(signal.SIGTERM, lambda *args: (_ for _ in ()).throw(m.Cancelled())); '
        f'm.run_child({command!r}, pathlib.Path({str(tmp_path)!r}))')
    parent = subprocess.Popen([sys.executable, '-c', program], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    child_pid = None
    try:
        deadline = time.monotonic() + 10
        while not pidfile.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        assert pidfile.exists()
        child_pid = int(pidfile.read_text())
        parent.terminate()
        parent.wait(timeout=8)
        with pytest.raises(ProcessLookupError):
            os.kill(child_pid, 0)
    finally:
        if parent.poll() is None:
            parent.kill()
            parent.wait()
        if child_pid:
            with contextlib.suppress(ProcessLookupError):
                os.kill(child_pid, signal.SIGKILL)


def test_cached_assets_are_hashed_before_copy(tmp_path, installer, server, monkeypatch):
    instance, root, assets, _ = make_install(tmp_path, installer, server, monkeypatch)
    instance.cache = tmp_path / 'cache'
    cached = instance.cache / 'models/tiny/model.bin'
    cached.parent.mkdir(parents=True)
    cached.write_bytes(server[0]['payload'])
    instance.run()
    assert not server[0]['ranges']
    assert (assets / 'models/tiny/model.bin').read_bytes() == cached.read_bytes()
    assert (root / 'installed.json').exists()


def test_sigterm_download_keeps_partial_and_emits_json_error(tmp_path, installer, server, monkeypatch):
    import shutil
    import subprocess
    import sys
    import time
    instance, root, assets, _ = make_install(tmp_path, installer, server, monkeypatch)
    scripts = root / 'scripts'
    scripts.mkdir()
    shutil.copyfile(SCRIPT, scripts / SCRIPT.name)
    shutil.copyfile(instance.manifest_path, scripts / 'runtime-assets.json')
    (scripts / 'desktop-wheels.json').write_text('{"assets": []}')
    server[0]['slow'] = True
    process = subprocess.Popen([sys.executable, str(scripts / SCRIPT.name), '--root', str(root),
        '--assets-root', str(assets), '--events-json'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        deadline = time.monotonic() + 10
        partial = assets / 'models/tiny/model.bin.part'
        while (not partial.exists() or partial.stat().st_size == 0) and time.monotonic() < deadline:
            assert process.poll() is None
            time.sleep(.02)
        assert partial.stat().st_size > 0
        process.terminate()
        output, errors = process.communicate(timeout=5)
        assert process.returncode == 130, errors
        assert 'cancelled' in json.loads(output.splitlines()[-1])['message']
        assert not (root / 'installed.json').exists()
        assert 0 < partial.stat().st_size < len(server[0]['payload'])
        with installer.install_lock(assets):
            pass
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()


def test_cancelled_preparation_does_not_leave_grandchildren(tmp_path, installer):
    import os
    import signal
    import subprocess
    import sys
    import time
    (tmp_path / 'VoxBridge').mkdir()
    pidfile = tmp_path / 'grandchild.pid'
    grandchild = ('import os, signal, time, pathlib; '
        'signal.signal(signal.SIGTERM, signal.SIG_IGN); '
        f'pathlib.Path({str(pidfile)!r}).write_text(str(os.getpid())); time.sleep(60)')
    leader = f'import subprocess, time; subprocess.Popen({[sys.executable, "-c", grandchild]!r}); time.sleep(60)'
    command = [sys.executable, '-c', leader]
    program = ('import importlib.util, pathlib, signal; '
        f's=importlib.util.spec_from_file_location("installer", {str(SCRIPT)!r}); '
        'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
        'signal.signal(signal.SIGTERM, lambda *args: (_ for _ in ()).throw(m.Cancelled())); '
        f'm.run_child({command!r}, pathlib.Path({str(tmp_path)!r}))')
    parent = subprocess.Popen([sys.executable, '-c', program], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    child_pid = None
    try:
        deadline = time.monotonic() + 10
        while not pidfile.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        assert pidfile.exists()
        child_pid = int(pidfile.read_text())
        parent.terminate()
        parent.wait(timeout=8)
        time.sleep(.2)
        with pytest.raises(ProcessLookupError):
            os.kill(child_pid, 0)
    finally:
        if parent.poll() is None:
            parent.kill()
            parent.wait()
        if child_pid:
            with contextlib.suppress(ProcessLookupError):
                os.kill(child_pid, signal.SIGKILL)


def test_explicit_repair_preserves_corrupt_asset_as_backup_and_recovers(tmp_path, installer, server, monkeypatch):
    instance, root, assets, output = make_install(tmp_path, installer, server, monkeypatch)
    original = assets / 'models/tiny/model.bin'
    original.parent.mkdir(parents=True)
    original.write_bytes(b'preserve corrupted data')
    instance.repair_corrupt = True
    instance.run()
    backups = list(original.parent.glob('model.bin.invalid-*'))
    assert len(backups) == 1
    assert backups[0].read_bytes() == b'preserve corrupted data'
    assert original.read_bytes() == server[0]['payload']
    assert (root / 'installed.json').exists()
    assert str(backups[0]) in output.getvalue()


def test_failed_preflight_preserves_existing_ready_marker(tmp_path, installer, server, monkeypatch):
    instance, root, _, _ = make_install(tmp_path, installer, server, monkeypatch)
    marker = root / 'installed.json'
    marker.write_text('valid existing installation')
    (root / 'license-consent.json').unlink()
    with pytest.raises(RuntimeError, match='consent'):
        instance.run()
    assert marker.read_text() == 'valid existing installation'


def test_explicit_wheel_repair_preserves_changed_package(tmp_path, installer):
    wheel = wheel_file(tmp_path, [('imageio_ffmpeg/__init__.py', b'x = 1', 0o100644),
        ('imageio_ffmpeg-0.6.0.dist-info/METADATA', b'Version: 0.6.0', 0o100644)])
    asset = {'name': 'imageio-ffmpeg', 'version': '0.6.0', 'sha256': hashlib.sha256(wheel.read_bytes()).hexdigest()}
    target = tmp_path / 'site-packages'
    installer.install_wheel(wheel, asset, target)
    (target / 'imageio_ffmpeg/__init__.py').write_bytes(b'preserve changed package')
    installer.install_wheel(wheel, asset, target, repair_corrupt=True)
    backups = list(target.glob('imageio_ffmpeg.invalid-*'))
    assert len(backups) == 1
    assert (backups[0] / '__init__.py').read_bytes() == b'preserve changed package'
    assert (target / 'imageio_ffmpeg/__init__.py').read_bytes() == b'x = 1'


@pytest.mark.parametrize('relative', ['runtime', '.venv', '.venv/lib/python3.12/site-packages/pyopenjtalk'])
def test_runtime_preparation_rejects_external_directory_links(tmp_path, installer, relative):
    from types import SimpleNamespace
    root = tmp_path / 'root'
    root.mkdir()
    external = tmp_path / 'external'
    external.mkdir()
    link = root / relative
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(external, target_is_directory=True)
    instance = SimpleNamespace(root=root, wheel_assets=[], events=installer.Events(stream=io.StringIO()))
    with pytest.raises(ValueError, match='[Ss]ymlink'):
        installer.prepare_runtime(instance)
    assert not list(external.iterdir())


def test_dictionary_helper_reads_archive_from_shared_asset_root(tmp_path, installer, monkeypatch):
    import shutil
    import subprocess
    import sys
    import tarfile
    from types import SimpleNamespace
    root = tmp_path / 'version'
    scripts = root / 'scripts'
    scripts.mkdir(parents=True)
    (root / 'VoxBridge').mkdir()
    assets = tmp_path / 'shared'
    downloads = assets / 'downloads'
    downloads.mkdir(parents=True)
    (root / 'downloads').symlink_to(downloads, target_is_directory=True)
    llama = root / 'runtime/translation-llama/llama-b10809/llama-server'
    llama.parent.mkdir(parents=True)
    llama.write_bytes(b'already extracted fixture')
    dictionary = root / '.venv/lib/python3.12/site-packages/pyopenjtalk/dictionary'
    (scripts / 'pyopenjtalk.py').write_text(f'OPEN_JTALK_DICT_DIR = {str(dictionary)!r}\n')
    shutil.copyfile(SCRIPT.with_name('setup_assets.py'), scripts / 'setup_assets.py')
    archive_path = downloads / 'open_jtalk_dic_utf_8-1.11.tar.gz'
    with tarfile.open(archive_path, 'w:gz') as archive:
        info = tarfile.TarInfo('open_jtalk_dic_utf_8-1.11/sys.dic')
        info.size = 4
        archive.addfile(info, io.BytesIO(b'dict'))
    (scripts / 'runtime-assets.json').write_text(json.dumps({'assets': [{
        'path': 'downloads/open_jtalk_dic_utf_8-1.11.tar.gz',
        'sha256': hashlib.sha256(archive_path.read_bytes()).hexdigest()}]}))
    # Only substitute the interpreter; run the real helper code and extraction.
    def run(command, version, **kwargs):
        subprocess.run([sys.executable, *map(str, command[1:])], cwd=version / 'VoxBridge', check=True)
    monkeypatch.setattr(installer, 'run_child', run)
    instance = SimpleNamespace(root=root, assets_root=assets, wheel_assets=[], manifest={},
                               events=installer.Events(stream=io.StringIO()))
    installer.prepare_runtime(instance)
    assert (dictionary / 'sys.dic').read_bytes() == b'dict'


def test_retry_recovers_interrupted_no_replace_publication(tmp_path, installer, server, monkeypatch):
    instance, root, assets, _ = make_install(tmp_path, installer, server, monkeypatch)
    link = installer.os.link
    interrupted = False
    def interruption(source, destination, **kwargs):
        nonlocal interrupted
        link(source, destination, **kwargs)
        if not interrupted:
            interrupted = True
            raise installer.Cancelled()
    monkeypatch.setattr(installer.os, 'link', interruption)
    with pytest.raises(installer.Cancelled):
        instance.run()
    destination = assets / 'models/tiny/model.bin'
    assert destination.stat().st_nlink == 2
    assert not (root / 'installed.json').exists()
    instance.run()
    assert destination.stat().st_nlink == 1
    assert destination.read_bytes() == server[0]['payload']
    assert not destination.with_name('model.bin.part').exists()
    assert (root / 'installed.json').exists()
    assert server[0]['ranges'] == [None]


def test_external_hard_link_is_not_treated_as_interrupted_publish(tmp_path, installer, server, monkeypatch):
    instance, _, assets, _ = make_install(tmp_path, installer, server, monkeypatch)
    outside = tmp_path / 'outside'
    outside.write_bytes(b'keep external hard link')
    destination = assets / 'models/tiny/model.bin'
    destination.parent.mkdir(parents=True)
    installer.os.link(outside, destination)
    with pytest.raises(ValueError, match='hard links'):
        instance.run()
    assert outside.read_bytes() == b'keep external hard link'
    assert outside.stat().st_nlink == 2
    assert not server[0]['ranges']
