import json
from pathlib import Path
import shlex
import socket
import subprocess
import sys
from types import SimpleNamespace

import pytest

from voxbridge.cli.demo_streaming_ws import OpenAIAPITranslator


def test_verified_mac_translation_sampling_preserves_church_prompt(monkeypatch):
    bodies = []
    class Response:
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def read(self):
            return json.dumps({'choices': [{'message': {'content': 'May the Lord bless you.'}, 'finish_reason': 'stop'}]}).encode()
    def request(req, timeout):
        bodies.append(json.loads(req.data))
        return Response()
    monkeypatch.setattr('urllib.request.urlopen', request)
    translator = OpenAIAPITranslator('http://127.0.0.1:8876', 'hy-mt', max_new_tokens=256, sampling_profile='mac-verified')
    assert translator.translate('愿主赐福给你。') == 'May the Lord bless you.'
    body = bodies[0]
    assert {k: body[k] for k in ('temperature', 'top_p', 'top_k', 'repeat_penalty', 'repeat_last_n', 'cache_prompt', 'max_tokens')} == {
        'temperature': 0, 'top_p': 0.6, 'top_k': 20, 'repeat_penalty': 1.05, 'repeat_last_n': 64, 'cache_prompt': False, 'max_tokens': 256}
    assert 'ESV' in body['messages'][0]['content']


def test_unknown_sampling_profile_fails_before_network():
    with pytest.raises(ValueError, match='sampling'):
        OpenAIAPITranslator('http://127.0.0.1:8876', 'hy-mt', sampling_profile='bad')


def test_macos_launch_profile_is_local_and_pinned():
    from tools.macos_service import build_commands
    commands = build_commands()
    app, mt = commands['app'], commands['translation']
    assert app[0].endswith('/.venv/bin/python')
    assert app[app.index('--port')+1] == '8024'
    assert app[app.index('--backend')+1] == 'mlx'
    assert app[app.index('--mlx-precision')+1] == 'int8'
    assert app[app.index('--translation-api-base-url')+1] == 'http://127.0.0.1:8876'
    assert app[app.index('--translation-sampling-profile')+1] == 'mac-verified'
    assert '--enable-tts' in app and '--enable-translation' in app
    assert app[app.index('--host')+1] == '0.0.0.0'
    assert app[app.index('--public-listener-url')+1] == 'auto'
    assert mt[mt.index('--host')+1] == '127.0.0.1'
    assert mt[mt.index('--gpu-layers')+1] == '99'
    assert mt[mt.index('--ctx-size')+1] == '4096'
    assert mt[mt.index('--parallel')+1] == '1'
    assert mt[mt.index('--threads')+1] == '2'
    assert 'Q8_0.gguf' in mt[mt.index('--model')+1]
    assert not any('192.168.1.31' in item or '/data/' in item for cmd in commands.values() for item in cmd)


def test_service_never_signals_unowned_pid(tmp_path, monkeypatch):
    from tools import macos_service as service
    record=tmp_path/'pid.json'
    record.write_text(json.dumps({'pid': 123, 'command': ['/our/python', '-m', 'voxbridge.cli.demo_streaming_ws', '--port', '8024']}))
    monkeypatch.setattr(service, 'process_argv', lambda pid: ['/other/python', '/unrelated.py'])
    calls=[]
    monkeypatch.setattr(service.os, 'kill', lambda *args: calls.append(args))
    assert service.owned_pid(record) is None
    service.stop_process(record)
    assert calls == []


def test_service_owns_actual_process_when_an_argument_contains_spaces(tmp_path):
    from tools import macos_service as service

    command = [
        sys.executable,
        '-c',
        'import time;time.sleep(30)',
        str(tmp_path / 'workspace with spaces' / 'model.gguf'),
    ]
    child = subprocess.Popen(command)
    try:
        actual = subprocess.run(
            ['ps', '-p', str(child.pid), '-o', 'command='],
            capture_output=True,
            text=True,
            check=False,
        ).stdout.strip()
        assert actual
        assert shlex.split(actual) != command

        record = tmp_path / 'owned.json'
        record.write_text(json.dumps({'pid': child.pid, 'command': command}))
        assert service.owned_pid(record) == child.pid

        record.write_text(json.dumps({'pid': child.pid, 'command': command[:-1] + ['different.gguf']}))
        assert service.owned_pid(record) is None
    finally:
        child.terminate()
        child.wait(timeout=5)


def test_port_probe_allows_immediate_restart_after_server_side_close():
    from tools import macos_service as service

    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    port = listener.getsockname()[1]
    listener.listen()
    client = socket.create_connection(('127.0.0.1', port))
    accepted, _ = listener.accept()
    accepted.shutdown(socket.SHUT_WR)
    assert client.recv(1) == b''
    accepted.close()
    client.close()
    listener.close()

    with socket.socket() as plain_probe:
        with pytest.raises(OSError):
            plain_probe.bind(('127.0.0.1', port))

    assert service.port_available('127.0.0.1', port) is True


def test_port_probe_rejects_an_active_listener():
    from tools import macos_service as service

    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
        listener.listen()

        assert service.port_available('127.0.0.1', port) is False


def test_speculation_requires_explicit_mac_environment_opt_in(monkeypatch):
    from tools.macos_service import build_commands
    monkeypatch.delenv('VOXBRIDGE_SPECULATIVE_TRANSLATION', raising=False)
    baseline = build_commands()
    assert '--translation-speculative' not in baseline['app']
    monkeypatch.setenv('VOXBRIDGE_SPECULATIVE_TRANSLATION', '1')
    enabled = build_commands()
    assert '--translation-speculative' in enabled['app']
    assert [arg for arg in enabled['app'] if arg != '--translation-speculative'] == baseline['app']
    assert enabled['translation'] == baseline['translation']
