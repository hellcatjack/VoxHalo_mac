"""Own the standalone Mac services, without changing unrelated local processes."""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import fcntl
import json
import os
from pathlib import Path
import platform
import signal
import secrets
import socket
import struct
import subprocess
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
PYTHON = WORKSPACE / '.venv/bin/python'
STATE = ROOT / 'artifacts/macos-service'
LOGS = ROOT / 'logs'
ASR_MODEL = WORKSPACE / 'models/qwen3-asr-0.6b'
MT_MODEL = WORKSPACE / 'models/translation-experiments/gguf/HY-MT1.5-1.8B-Q8_0.gguf'
LLAMA = WORKSPACE / 'runtime/translation-llama/llama-b10809/llama-server'
KOKORO = WORKSPACE / 'models/kokoro'


def _darwin_process_argv(pid):
    libc = ctypes.CDLL(ctypes.util.find_library('c') or None, use_errno=True)
    mib = (ctypes.c_int * 3)(1, 49, int(pid))  # CTL_KERN, KERN_PROCARGS2, pid
    size = ctypes.c_size_t()
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    if size.value <= struct.calcsize('=i'):
        raise OSError('process argv is unavailable')

    buffer = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    data = buffer.raw[:size.value]
    argc = struct.unpack_from('=i', data)[0]
    if argc <= 0:
        raise OSError('process argv is unavailable')

    cursor = data.find(b'\0', struct.calcsize('=i'))
    if cursor < 0:
        raise OSError('process argv is malformed')
    cursor += 1
    while cursor < len(data) and data[cursor] == 0:
        cursor += 1

    argv = []
    for _ in range(argc):
        end = data.find(b'\0', cursor)
        if end < 0:
            raise OSError('process argv is malformed')
        argv.append(os.fsdecode(data[cursor:end]))
        cursor = end + 1
    return argv


def process_argv(pid):
    if platform.system() == 'Darwin':
        return _darwin_process_argv(pid)
    proc_args = Path(f'/proc/{int(pid)}/cmdline')
    if proc_args.is_file():
        return [os.fsdecode(arg) for arg in proc_args.read_bytes().split(b'\0') if arg]
    raise OSError('argument-preserving process inspection is unavailable')


def build_commands():
    host = os.environ.get('VOXBRIDGE_HOST', '0.0.0.0')
    app = [str(PYTHON), '-m', 'voxbridge.cli.demo_streaming_ws',
           '--backend', 'mlx', '--mlx-precision', 'int8', '--asr-model-path', str(ASR_MODEL),
           '--host', host, '--port', '8024', '--max-connections', '1',
           '--max-new-tokens', '256', '--chunk-size-sec', '2',
           '--client-chunk-ms', '100', '--consumer-batch-sec', '0.5',
           '--slice-mode', 'vad', '--auto-slice-sec', '12',
           '--state-rollover-sec', '12', '--segment-hard-cut-sec', '12',
           '--slice-overlap-sec', '0.32', '--segment-overlap-sec', '0.32',
           '--vad-silence-sec', '0.8', '--vad-min-slice-sec', '2',
           '--vad-min-active-sec', '0.2', '--vad-force-cut-sec', '1.8',
           '--segment-final-redecode', '--silent-decode-pre-roll-sec', '0.4',
           '--silero-vad-shadow', '--silero-vad-rescue',
           '--enable-translation', '--translation-backend', 'openai_api',
           '--translation-api-base-url', 'http://127.0.0.1:8876',
           '--translation-api-model', 'hy-mt', '--translation-max-new-tokens', '256',
           '--translation-api-timeout-sec', '30', '--translation-workers', '1',
           '--translation-sampling-profile', 'mac-verified',
           '--enable-tts', '--tts-en-model-path', str(KOKORO/'kokoro-v1.0.onnx'),
           '--tts-en-voices-path', str(KOKORO/'voices-v1.0.bin'),
           '--tts-zh-model-path', str(KOKORO/'kokoro-v1.1-zh-float-speed.onnx'),
           '--tts-zh-voices-path', str(KOKORO/'voices-v1.1-zh.bin'),
           '--tts-zh-vocab-path', str(KOKORO/'config-v1.1-zh.json'),
           '--tts-en-voice', 'am_michael', '--tts-zh-voice', 'zm_029',
           '--tts-speed', '1.05', '--tts-cpu-threads', '2',
           '--tts-revision-stable-sec', '3', '--tts-latest-revision-grace-sec', '4',
           '--tts-stream-chunks', '--tts-native-pcm', '--tts-confirmed-urgent-stable-sec', '1',
           '--disable-debug-file', '--native-console']
    if os.environ.get('VOXBRIDGE_SPECULATIVE_TRANSLATION') == '1':
        app.append('--translation-speculative')
    app += ['--public-listener-url', os.environ.get('VOXBRIDGE_LISTENER_URL') or 'auto']
    mt = [str(LLAMA), '--model', str(MT_MODEL), '--alias', 'hy-mt',
          '--host', '127.0.0.1', '--port', '8876', '--gpu-layers', '99',
          '--flash-attn', 'on', '--ctx-size', '4096', '--parallel', '1',
          '--threads', '2', '--threads-batch', '2', '--cache-ram', '0']
    return {'app': app, 'translation': mt}


def owned_pid(record: Path):
    try:
        data = json.loads(record.read_text())
        pid, command = int(data['pid']), data['command']
        if (pid <= 1 or not isinstance(command, list)
                or not all(isinstance(arg, str) for arg in command)):
            return None
        if process_argv(pid) == command:
            return pid
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def stop_process(record: Path):
    pid = owned_pid(record)
    if pid:
        os.kill(pid, signal.SIGTERM)
        until = time.monotonic() + 30
        while owned_pid(record) and time.monotonic() < until:
            time.sleep(.1)
        if owned_pid(record):
            raise RuntimeError(f'进程 {pid} 未及时退出，请检查日志；未强制终止。')
    record.unlink(missing_ok=True)


def read_json(url):
    with urllib.request.urlopen(url, timeout=2) as response:
        return json.load(response)


def native_console_capability():
    """True/False for a responding backend; None while it is unreachable."""
    try:
        state = read_json('http://127.0.0.1:8024/api/monitor/state')
        return isinstance(state, dict) and state.get('native_console') is True
    except urllib.error.HTTPError as exc:
        return False if exc.code == 404 else None
    except (OSError, ValueError):
        return None


def native_service_error():
    """An owned old service requires the user's explicit stop/restart action."""
    record = STATE / 'app.json'
    if not owned_pid(record):
        return None
    try:
        command = json.loads(record.read_text())['command']
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if '--native-console' not in command or native_console_capability() is False:
        return '现有服务不支持本机控制台。请先停止现有服务，再重新启动；正在进行的采集不会自动中断。'
    return None


def ready(name):
    if not owned_pid(STATE/f'{name}.json'):
        return False
    try:
        if name == 'translation':
            return read_json('http://127.0.0.1:8876/health').get('status') == 'ok'
        return (read_json('http://127.0.0.1:8024/api/tts/live/status').get('available') is True
                and native_console_capability() is True)
    except (OSError, ValueError):
        return False


def native_control_token():
    STATE.mkdir(parents=True, exist_ok=True)
    path = STATE / 'native-control-token'
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        token = path.read_text().strip()
        if len(token) < 32:
            raise RuntimeError('本机控制凭据损坏，请检查 native-control-token。')
        path.chmod(0o600)
        return token
    with os.fdopen(fd, 'w') as stream:
        token = secrets.token_urlsafe(32)
        stream.write(token)
    return token


def environment():
    env = os.environ.copy()
    env.update(HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1', HF_HUB_DISABLE_TELEMETRY='1',
               DO_NOT_TRACK='1', PYTHONUNBUFFERED='1', TOKENIZERS_PARALLELISM='false')
    env['VOXBRIDGE_NATIVE_CONTROL_TOKEN'] = native_control_token()
    env['VOXBRIDGE_SILERO_ONNX'] = str(WORKSPACE/'models/vad/silero_vad.onnx')
    env['PATH'] = str(PYTHON.parent) + os.pathsep + env.get('PATH', '/usr/bin:/bin')
    return env


def check_assets():
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise RuntimeError('此配置要求 Apple Silicon macOS。')
    assets = [PYTHON, LLAMA, MT_MODEL, ASR_MODEL/'model.safetensors', WORKSPACE/'models/vad/silero_vad.onnx',
              *[KOKORO/name for name in ('kokoro-v1.0.onnx', 'voices-v1.0.bin',
                  'kokoro-v1.1-zh-float-speed.onnx', 'voices-v1.1-zh.bin', 'config-v1.1-zh.json')]]
    missing = [str(path) for path in assets if not path.is_file()]
    if missing:
        raise RuntimeError('缺少本地资源：\n' + '\n'.join(missing))
    import imageio_ffmpeg
    binary = Path(imageio_ffmpeg.get_ffmpeg_exe())
    if not binary.is_file():
        raise RuntimeError('缺少本地 FFmpeg。')
    alias = PYTHON.parent/'ffmpeg'
    if not alias.exists():
        alias.symlink_to(binary)


def port_available(host, port):
    with socket.socket() as probe:
        probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            probe.bind((host, port))
        except OSError:
            return False
    return True


def start():
    check_assets()
    issue = native_service_error()
    if issue:
        raise RuntimeError(issue)
    commands = build_commands()
    started = []
    try:
        for name, port in [('translation', 8876), ('app', 8024)]:
            record = STATE/f'{name}.json'
            if ready(name):
                continue
            if owned_pid(record):
                raise RuntimeError(f'{name} 已运行但尚未就绪，请检查日志。')
            bind_host = commands[name][commands[name].index('--host') + 1]
            if not port_available(bind_host, port):
                raise RuntimeError(f'端口 {port} 被其他服务占用，请先停止对应服务。')
            with (LOGS/f'macos-{name}.log').open('ab') as log:
                child = subprocess.Popen(commands[name], cwd=ROOT, env=environment(),
                    stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
            record.write_text(json.dumps({'pid': child.pid, 'command': commands[name]}))
            started.append(name)
            deadline = time.monotonic()+120
            while time.monotonic() < deadline:
                if ready(name):
                    break
                if child.poll() is not None:
                    raise RuntimeError(f'{name} 启动失败，见 {LOGS/f"macos-{name}.log"}')
                time.sleep(.25)
            else:
                raise RuntimeError(f'{name} 启动超时，见 {LOGS/f"macos-{name}.log"}')
    except BaseException:
        for name in reversed(started):
            stop_process(STATE/f'{name}.json')
        raise
    from voxbridge.tts.public_listener import LANAddressUnavailable, listener_url_for_request
    try:
        listener = listener_url_for_request(
            'http://127.0.0.1:8024', os.environ.get('VOXBRIDGE_LISTENER_URL') or 'auto')
    except LANAddressUnavailable as exc:
        listener = str(exc)
    print(f'VoxBridge 已就绪，监控页面：http://127.0.0.1:8024\n局域网朗读：{listener}', flush=True)


def app_status():
    """Read GUI status without waiting behind a model startup or shutdown."""
    from voxbridge.tts.public_listener import LANAddressUnavailable, listener_url_for_request
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE/'control.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            busy = True
        else:
            busy = False
            fcntl.flock(lock, fcntl.LOCK_UN)
    services = {name: {'pid': owned_pid(STATE/f'{name}.json'), 'ready': ready(name)}
                for name in ('app', 'translation')}
    service_error = native_service_error() if not services['app']['ready'] else None
    configured = os.environ.get('VOXBRIDGE_LISTENER_URL') or 'auto'
    if services['app']['pid']:
        try:
            command = json.loads((STATE/'app.json').read_text())['command']
            configured = command[command.index('--public-listener-url') + 1]
        except (OSError, ValueError, KeyError, IndexError, TypeError):
            pass
    listener, lan_error = None, None
    try:
        listener = listener_url_for_request('http://127.0.0.1:8024', configured)
    except (LANAddressUnavailable, ValueError) as exc:
        lan_error = str(exc)
    return {'services': services, 'busy': busy, 'listener_url': listener,
            'service_error': service_error, 'restart_required': service_error is not None,
            'lan_error': lan_error, 'operator_url': 'http://127.0.0.1:8024',
            'logs_path': str(LOGS)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['start', 'stop', 'status', 'check', 'app-status'])
    args = parser.parse_args()
    STATE.mkdir(parents=True, exist_ok=True)
    LOGS.mkdir(exist_ok=True)
    if args.action == 'app-status':
        print(json.dumps(app_status(), ensure_ascii=False))
        return
    with (STATE/'control.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            if args.action == 'start':
                start()
            elif args.action == 'stop':
                stop_process(STATE/'app.json')
                stop_process(STATE/'translation.json')
                print('VoxBridge 和本机翻译服务已停止。')
            elif args.action == 'check':
                check_assets()
                print('本机模型、Python 与 FFmpeg 资源齐全。')
            else:
                state = {name: {'pid': owned_pid(STATE/f'{name}.json'), 'ready': ready(name)}
                         for name in ('app', 'translation')}
                print(json.dumps(state, ensure_ascii=False, indent=2))
        except (OSError, RuntimeError) as exc:
            parser.exit(1, f'{exc}\n')


if __name__ == '__main__':
    main()
