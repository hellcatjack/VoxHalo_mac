"""Repair real files through the resumable downloader, using a tiny local server."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import fcntl
from types import SimpleNamespace

import pytest

from test_desktop_installer import server  # local HTTP failure fixture

SCRIPTS = Path(__file__).resolve().parents[2] / 'scripts'


@pytest.fixture
def manager():
    path = SCRIPTS / 'model_manager.py'
    assert path.is_file(), 'App model recovery is not implemented'
    sys.path.insert(0, str(SCRIPTS))
    try:
        spec = importlib.util.spec_from_file_location('model_manager', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        yield module
    finally:
        sys.path.remove(str(SCRIPTS))


def fixture(tmp_path, manager, server):
    state, url = server
    root = tmp_path / 'local workspace'
    root.mkdir()
    assets = [{'path': 'models/qwen3-asr-0.6b/model.safetensors', 'url': url,
               'size': len(state['payload']), 'sha256': hashlib.sha256(state['payload']).hexdigest()},
              {'path': 'models/vad/silero_vad.onnx', 'url': url, 'size': len(state['payload']),
               'sha256': hashlib.sha256(state['payload']).hexdigest()}]
    manifest = tmp_path / 'manifest.json'
    manifest.write_text(json.dumps({'assets': assets}))
    output = io.StringIO()
    repair = manager.ModelRepair(root, manifest=manifest, events=manager.Events(True, output), reserve_bytes=0)
    return repair, root, output


def test_deleted_file_can_be_downloaded_again_without_changing_other_models(tmp_path, manager, server):
    repair, root, output = fixture(tmp_path, manager, server)
    other = root / 'models/vad/silero_vad.onnx'
    other.parent.mkdir(parents=True)
    other.write_bytes(b'user model left alone')
    selected = 'models/qwen3-asr-0.6b/model.safetensors'
    repair.run([selected])
    assert (root / selected).read_bytes() == server[0]['payload']
    (root / selected).unlink()
    repair.run([selected])
    assert (root / selected).read_bytes() == server[0]['payload']
    assert other.read_bytes() == b'user model left alone'
    assert len(server[0]['ranges']) == 2
    assert json.loads(output.getvalue().splitlines()[-1])['phase'] == 'ready'


def test_changed_model_is_backed_up_before_verified_replacement(tmp_path, manager, server):
    repair, root, _ = fixture(tmp_path, manager, server)
    path = root / 'models/vad/silero_vad.onnx'
    path.parent.mkdir(parents=True)
    path.write_bytes(b'changed')
    repair.run(['models/vad/silero_vad.onnx'])
    assert path.read_bytes() == server[0]['payload']
    assert [p.read_bytes() for p in path.parent.glob('*.invalid-*')] == [b'changed']


def test_interrupted_repair_resumes_and_reports_per_file_progress(tmp_path, manager, server):
    repair, root, output = fixture(tmp_path, manager, server)
    selected = 'models/vad/silero_vad.onnx'
    server[0]['interrupt'] = True
    with pytest.raises((OSError, RuntimeError)):
        repair.run([selected])
    partial = root / (selected + '.part')
    size = partial.stat().st_size
    assert 0 < size < len(server[0]['payload'])
    repair.run([selected])
    assert server[0]['ranges'][-1] == f'bytes={size}-'
    assert not partial.exists()
    events = [json.loads(line) for line in output.getvalue().splitlines()]
    assert any(e['phase'] == 'downloading' and e['asset'] == selected and e['total_bytes'] > 0 for e in events)


def test_shared_release_models_resolve_to_actual_storage(tmp_path, manager, server):
    repair, root, _ = fixture(tmp_path, manager, server)
    shared = tmp_path / 'shared assets/models'
    shared.mkdir(parents=True)
    (root / 'models').symlink_to(shared, target_is_directory=True)
    repair.run(['models/vad/silero_vad.onnx'])
    assert (shared / 'vad/silero_vad.onnx').read_bytes() == server[0]['payload']


def test_inner_symlink_and_unlisted_path_cannot_be_repaired(tmp_path, manager, server):
    repair, root, _ = fixture(tmp_path, manager, server)
    outside = tmp_path / 'outside'; outside.mkdir()
    (root / 'models').mkdir()
    (root / 'models/vad').symlink_to(outside, target_is_directory=True)
    with pytest.raises(ValueError):
        repair.run(['models/vad/silero_vad.onnx'])
    with pytest.raises(ValueError):
        repair.run(['models/../../outside/stolen'])
    assert not list(outside.iterdir())
    assert server[0]['ranges'] == []


def test_generated_model_patch_requires_exact_input_and_output_hash(manager, tmp_path):
    source, target = tmp_path / 'original', tmp_path / 'generated'
    source.write_bytes(b'abc\x06def')
    manager.restore_generated(source, target, source_sha256=hashlib.sha256(b'abc\x06def').hexdigest(),
                             target_sha256=hashlib.sha256(b'abc\x01def').hexdigest(), offset=3)
    assert target.read_bytes() == b'abc\x01def'
    target.unlink()
    with pytest.raises(RuntimeError):
        manager.restore_generated(source, target, source_sha256='0'*64, target_sha256='0'*64, offset=3)
    assert not target.exists()
    with pytest.raises(RuntimeError):
        manager.restore_generated(source, target, source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                                 target_sha256='0'*64, offset=3)
    assert not target.exists()


def test_resume_disk_allowance_counts_only_remaining_bytes(tmp_path, manager, server, monkeypatch):
    repair, root, _ = fixture(tmp_path, manager, server)
    selected = 'models/vad/silero_vad.onnx'
    partial = root / (selected + '.part')
    partial.parent.mkdir(parents=True)
    partial.write_bytes(server[0]['payload'][:-100])
    monkeypatch.setattr(manager.shutil, 'disk_usage', lambda _: SimpleNamespace(free=200))
    repair.run([selected])
    assert (root / selected).read_bytes() == server[0]['payload']


@pytest.mark.parametrize('lock_name', ['bootstrap', 'control'])
def test_maintenance_refuses_bootstrap_and_service_start_locks(tmp_path, manager, lock_name):
    root = tmp_path / 'data/versions/1.8.0'
    service = root / 'VoxBridge/tools'; service.mkdir(parents=True)
    (service / 'macos_service.py').write_text('def owned_pid(path): return None\ndef ready(name): return False\n')
    control = root / 'VoxBridge/artifacts/macos-service/control.lock'
    control.parent.mkdir(parents=True)
    lock_path = root.parent.parent / '.bootstrap.lock' if lock_name == 'bootstrap' else control
    with lock_path.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with pytest.raises(RuntimeError):
            with manager.stopped_services(root):
                pytest.fail('Repair entered while another operation owns the installation')


def test_maintenance_refuses_running_service_even_without_control_lock(tmp_path, manager):
    root = tmp_path / 'workspace'
    service = root / 'VoxBridge/tools'; service.mkdir(parents=True)
    (service / 'macos_service.py').write_text('def owned_pid(path): return 123\ndef ready(name): return False\n')
    with pytest.raises(RuntimeError):
        with manager.stopped_services(root):
            pytest.fail('A loaded model cannot be changed')
