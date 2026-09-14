import fcntl
import json

from tools import macos_service as service


def configure(monkeypatch, tmp_path):
    monkeypatch.setattr(service, 'STATE', tmp_path)
    monkeypatch.setattr(service, 'owned_pid', lambda record: 42 if record.stem == 'app' else 43)
    monkeypatch.setattr(service, 'ready', lambda name: True)
    monkeypatch.setattr('voxbridge.tts.public_listener.detect_lan_ipv4', lambda: '192.168.1.253')


def test_app_status_reports_owned_services_and_lan_url(monkeypatch, tmp_path):
    configure(monkeypatch, tmp_path)
    result = service.app_status()
    assert result['services']['app'] == {'pid': 42, 'ready': True}
    assert result['services']['translation'] == {'pid': 43, 'ready': True}
    assert result['listener_url'] == 'http://192.168.1.253:8024/listen'
    assert result['operator_url'] == 'http://127.0.0.1:8024'
    assert result['busy'] is False


def test_app_status_does_not_wait_for_start_stop_lock(monkeypatch, tmp_path):
    configure(monkeypatch, tmp_path)
    with (tmp_path / 'control.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert service.app_status()['busy'] is True


def test_app_status_no_lan_keeps_service_state(monkeypatch, tmp_path):
    from voxbridge.tts.lan_address import LANAddressUnavailable
    configure(monkeypatch, tmp_path)
    def unavailable():
        raise LANAddressUnavailable('未连接局域网')
    monkeypatch.setattr('voxbridge.tts.public_listener.detect_lan_ipv4', unavailable)
    result = service.app_status()
    assert result['services']['app']['ready'] is True
    assert result['listener_url'] is None
    assert result['lan_error'] == '未连接局域网'


def test_app_status_uses_running_configuration(monkeypatch, tmp_path):
    configure(monkeypatch, tmp_path)
    (tmp_path / 'app.json').write_text(json.dumps({
        'command': ['python', '--public-listener-url', 'https://church.example/listen'],
    }))
    assert service.app_status()['listener_url'] == 'https://church.example/listen'


def test_app_status_does_not_trust_unowned_record(monkeypatch, tmp_path):
    configure(monkeypatch, tmp_path)
    monkeypatch.setattr(service, 'owned_pid', lambda record: None)
    monkeypatch.setattr(service, 'ready', lambda name: False)
    (tmp_path / 'app.json').write_text(json.dumps({
        'command': ['python', '--public-listener-url', 'https://stale.example/listen'],
    }))
    result = service.app_status()
    assert result['services']['app'] == {'pid': None, 'ready': False}
    assert result['listener_url'] == 'http://192.168.1.253:8024/listen'


def configure_owned_backend(monkeypatch, tmp_path, *, native):
    monkeypatch.setattr(service, 'STATE', tmp_path)
    command = ['python', '-m', 'voxbridge.cli.demo_streaming_ws', '--port', '8024']
    if native:
        command.append('--native-console')
    (tmp_path / 'app.json').write_text(json.dumps({'pid': 42, 'command': command}))
    (tmp_path / 'translation.json').write_text(json.dumps({'pid': 43, 'command': ['llama-server']}))
    monkeypatch.setattr(service, 'process_argv', lambda pid: command if pid == 42 else ['llama-server'])
    def response(url):
        if url.endswith('/api/monitor/state'):
            return {'native_console': native}
        return {'available': True, 'status': 'ok'}
    monkeypatch.setattr(service, 'read_json', response)
    monkeypatch.setattr('voxbridge.tts.public_listener.detect_lan_ipv4', lambda: '192.168.1.253')


def test_old_owned_backend_is_not_native_ready_and_has_restart_action(monkeypatch, tmp_path):
    configure_owned_backend(monkeypatch, tmp_path, native=False)
    assert service.ready('app') is False
    status = service.app_status()
    assert status['services']['app'] == {'pid': 42, 'ready': False}
    assert status['restart_required'] is True
    assert '停止' in status['service_error'] and '重新启动' in status['service_error']
    assert not (tmp_path / 'native-control-token').exists()


def test_start_rejects_old_owned_backend_without_stopping_it(monkeypatch, tmp_path):
    import pytest
    configure_owned_backend(monkeypatch, tmp_path, native=False)
    monkeypatch.setattr(service, 'check_assets', lambda: None)
    actions = []
    monkeypatch.setattr(service, 'stop_process', lambda record: actions.append(('stop', record)))
    monkeypatch.setattr(service.subprocess, 'Popen', lambda *a, **k: actions.append(('spawn', a)))
    with pytest.raises(RuntimeError, match='停止.*重新启动'):
        service.start()
    assert actions == []
    assert service.owned_pid(tmp_path / 'app.json') == 42


def test_native_owned_backend_remains_ready(monkeypatch, tmp_path):
    configure_owned_backend(monkeypatch, tmp_path, native=True)
    assert service.ready('app') is True
    status = service.app_status()
    assert status['restart_required'] is False
    assert status['service_error'] is None


def test_unowned_backend_never_becomes_ready_or_requests_owned_upgrade(monkeypatch, tmp_path):
    configure_owned_backend(monkeypatch, tmp_path, native=False)
    monkeypatch.setattr(service, 'process_argv', lambda pid: ['unrelated-service'])
    assert service.ready('app') is False
    status = service.app_status()
    assert status['restart_required'] is False
    assert status['service_error'] is None


def test_missing_monitor_route_is_incompatible_even_if_command_claims_native(monkeypatch, tmp_path):
    import urllib.error
    configure_owned_backend(monkeypatch, tmp_path, native=True)
    def response(url):
        if url.endswith('/api/monitor/state'):
            raise urllib.error.HTTPError(url, 404, 'Not Found', {}, None)
        return {'available': True, 'status': 'ok'}
    monkeypatch.setattr(service, 'read_json', response)
    assert service.ready('app') is False
    status = service.app_status()
    assert status['restart_required'] is True
    assert '重新启动' in status['service_error']


def test_starting_native_backend_is_unready_without_upgrade_action(monkeypatch, tmp_path):
    configure_owned_backend(monkeypatch, tmp_path, native=True)
    def unavailable(url):
        raise ConnectionRefusedError('backend is still starting')
    monkeypatch.setattr(service, 'read_json', unavailable)
    assert service.ready('app') is False
    status = service.app_status()
    assert status['services']['app']['pid'] == 42
    assert status['restart_required'] is False
    assert status['service_error'] is None
