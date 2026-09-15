import os
import pytest
from fastapi.testclient import TestClient
from voxbridge.cli.demo_streaming_ws import _create_app
from test_demo_streaming_ws_protocol import _args, _FakeASR, _receive_until_type


def native_app(monkeypatch):
    monkeypatch.setenv('VOXBRIDGE_NATIVE_CONTROL_TOKEN', 'test-native-private-token')
    args = _args()
    args.native_console = True
    args.max_connections = 1
    return _create_app(args, _FakeASR())


def test_native_mode_requires_private_configuration(monkeypatch):
    monkeypatch.delenv('VOXBRIDGE_NATIVE_CONTROL_TOKEN', raising=False)
    args = _args(); args.native_console = True
    with pytest.raises(ValueError, match='native.*token'):
        _create_app(args, _FakeASR())


def test_monitor_does_not_claim_producer_or_enable_tts(monkeypatch):
    app = native_app(monkeypatch)
    with TestClient(app, client=('127.0.0.1', 12345)) as client:
        for _ in range(3):
            state = client.get('/api/monitor/state').json()
            assert state['session']['status'] == 'idle'
            assert state['tts']['listener_count'] == 0
            assert state['tts']['producer_active'] is False
        with client.websocket_connect('/ws', headers={'X-VoxBridge-Control-Token':'test-native-private-token'}) as ws:
            assert ws.receive_json()['type'] == 'ready'
            ws.send_json({'type':'start', 'translation_direction':'zh2en'})
            _receive_until_type(ws, 'started')
            for _ in range(3):
                assert client.get('/api/monitor/state').json()['session']['status'] == 'running'
            ws.send_json({'type':'finish'})
            _receive_until_type(ws, 'final')
        assert client.get('/api/monitor/state').json()['session']['status'] == 'stopped'


@pytest.mark.parametrize('host,headers', [('127.0.0.1',{}), ('192.168.1.12',{'X-VoxBridge-Control-Token':'test-native-private-token'})])
def test_native_producer_rejects_browser_and_lan(monkeypatch,host,headers):
    app=native_app(monkeypatch)
    with TestClient(app,client=(host,12345)).websocket_connect('/ws',headers=headers) as ws:
        assert ws.receive_json() == {'type':'error','message':'native console authorization required'}


def test_native_page_is_passive_and_does_not_expose_token(monkeypatch):
    with TestClient(native_app(monkeypatch)) as client:
        html=client.get('/').text
        assert '/api/monitor/state' in html
        assert 'test-native-private-token' not in html
        assert 'getUserMedia' not in html and 'getDisplayMedia' not in html
        assert 'new WebSocket' not in html
        assert client.post('/api/monitor/state',json={'type':'stop'}).status_code == 405


def test_monitor_revision_reset_and_late_join_snapshot():
    from voxbridge.monitor import MonitorState
    state=MonitorState(max_rows=2)
    state.observe({'type':'started','translation_direction':'zh2en'})
    state.observe({'type':'sentence_committed','sentence_id':'a','revision':1,'text':'旧词。'})
    state.observe({'type':'sentence_translation','sentence_id':'a','revision':1,'translation':'Old.'})
    state.observe({'type':'sentence_updated','sentence_id':'a','revision':2,'text':'新词。'})
    state.observe({'type':'sentence_translation','sentence_id':'a','revision':1,'translation':'Stale.'})
    assert state.snapshot()['rows'] == [{'id':'a','revision':2,'source':'新词。','translation':''}]
    state.observe({'type':'sentence_translation','sentence_id':'a','revision':2,'translation':'New.'})
    state.observe({'type':'partial','text':'新词。下一句','tentative_text':'下一句'})
    snap=state.snapshot(); assert snap['rows'][0]['translation']=='New.' and snap['tentative']=='下一句'
    snap['rows'][0]['translation']='mutated'; assert state.snapshot()['rows'][0]['translation']=='New.'
    for name in ['b','c']: state.observe({'type':'sentence_committed','sentence_id':name,'revision':1,'text':name})
    assert [x['id'] for x in state.snapshot()['rows']]==['b','c']
    state.observe({'type':'sentence_translation','sentence_id':'a','revision':2,'translation':'late evicted'})
    assert [x['id'] for x in state.snapshot()['rows']]==['b','c']
    state.observe({'type':'sentence_reset'}); assert state.snapshot()['rows']==[]
    state.observe({'type':'final'}); assert state.snapshot()['session']['status']=='stopped'


def test_monitor_keeps_spoken_snapshot_when_source_and_translation_are_corrected():
    from voxbridge.monitor import MonitorState
    state = MonitorState()
    state.observe(dict(type='sentence_committed', sentence_id='a', revision=1, text='We can leave.'))
    state.observe(dict(type='speech_committed', sentence_id='a', revision=1,
                       source='We can leave.', translation='我们可以离开。'))
    state.observe(dict(type='sentence_updated', sentence_id='a', revision=2, text='We cannot leave.'))
    state.observe(dict(type='sentence_translation', sentence_id='a', revision=2, translation='我们不能离开。'))
    row = state.snapshot()['rows'][0]
    assert row['translation'] == '我们不能离开。'
    assert row['spoken'] == [dict(sentence_id='a', revision=1, source='We can leave.', text='我们可以离开。')]
    event = dict(type='speech_committed', sentence_id='a:addition:2', revision=2,
                 source='until tomorrow.', translation='直到明天。')
    state.observe(event)
    state.observe(event)
    assert [part['text'] for part in state.snapshot()['rows'][0]['spoken']] == ['我们可以离开。', '直到明天。']


def test_native_control_token_is_stable_private_and_in_environment(monkeypatch,tmp_path):
    from tools import macos_service as service
    monkeypatch.setattr(service,'STATE',tmp_path)
    a=service.native_control_token(); b=service.native_control_token()
    assert a==b and len(a)>=32
    assert (tmp_path/'native-control-token').stat().st_mode & 0o777 == 0o600
    assert service.environment()['VOXBRIDGE_NATIVE_CONTROL_TOKEN']==a
    assert all(a not in word for command in service.build_commands().values() for word in command)
    assert '--native-console' in service.build_commands()['app']


def test_monitor_version_advances_with_frozen_clock_and_across_resets(monkeypatch):
    from voxbridge.monitor import MonitorState, MONITOR_HTML
    monkeypatch.setattr('voxbridge.monitor.time.time', lambda: 1234.5)
    state = MonitorState()
    snapshots = [state.snapshot()]
    for event in [
        {'type': 'sentence_committed', 'sentence_id': 'a', 'revision': 1, 'text': '原文'},
        {'type': 'sentence_translation', 'sentence_id': 'a', 'revision': 1, 'translation': 'Translation'},
        {'type': 'started', 'translation_direction': 'en2zh'},
        {'type': 'sentence_committed', 'sentence_id': 'b', 'revision': 1, 'text': 'Again'},
        {'type': 'sentence_reset'},
    ]:
        state.observe(event)
        snapshots.append(state.snapshot())
    state.reset()
    snapshots.append(state.snapshot())
    assert len({snapshot['updated_at_ms'] for snapshot in snapshots}) == 1
    versions = [snapshot['version'] for snapshot in snapshots]
    assert all(new > old for old, new in zip(versions, versions[1:]))
    assert snapshots[1]['rows'][0]['translation'] == ''
    assert snapshots[2]['rows'][0]['translation'] == 'Translation'
    assert state.snapshot()['version'] == state.snapshot()['version']
    assert 'd.version!==version' in MONITOR_HTML
    assert 'version=d.version' in MONITOR_HTML
    assert 'd.updated_at_ms!==version' not in MONITOR_HTML


def test_monitor_version_advances_when_clock_moves_backwards(monkeypatch):
    from voxbridge.monitor import MonitorState
    monkeypatch.setattr('voxbridge.monitor.time.time', lambda: 2000)
    state = MonitorState()
    before = state.snapshot()
    monkeypatch.setattr('voxbridge.monitor.time.time', lambda: 1000)
    state.observe({'type': 'partial', 'tentative_text': 'new text'})
    after = state.snapshot()
    assert after['updated_at_ms'] < before['updated_at_ms']
    assert after['version'] > before['version']
