import asyncio
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient


def test_feedback_expires_and_does_not_use_unplayed_server_estimates():
    from voxbridge.tts.native_routes import NativePlaybackFeedback
    now = [10.0]
    feedback = NativePlaybackFeedback(clock=lambda: now[0])
    wake = asyncio.Event()
    feedback.subscribe(wake)
    feedback.update("native-one", epoch="one", received_seq=3, played_seq=2,
                    buffered_ms=1500, playing=True)
    assert feedback.urgent("one") is True
    assert wake.is_set()
    assert feedback.urgent("two") is False
    now[0] = 12.01
    assert feedback.urgent("one") is False


def test_expired_feedback_cannot_shorten_release_on_translation_completion():
    from voxbridge.tts.native_routes import NativePlaybackFeedback
    from voxbridge.tts.jobs import RevisionStableTTSBuffer
    now=[10.0]
    feedback=NativePlaybackFeedback(clock=lambda:now[0])
    gate=RevisionStableTTSBuffer(stable_sec=3,confirmed_urgent_stable_sec=1,
                                playback_pressure=lambda:feedback.urgent("one"),clock=lambda:now[0])
    gate.register('s',1,0);gate.confirm_through(0)
    feedback.update('n',epoch='one',received_seq=0,played_seq=0,buffered_ms=0,playing=False)
    now[0]=12.1
    gate.mark_ready('s',1,'Ready.','English')
    assert gate.drain()==[]
    now[0]=13.0
    assert gate.drain()[0].release_reason=='rollback_safe'


@pytest.mark.parametrize("field,value", [("buffered_ms",float("nan")), ("buffered_ms",-1),
                                        ("buffered_ms",121000), ("played_seq",4),
                                        ("received_seq",True), ("playing","false")])
def test_feedback_rejects_malformed_values(field,value):
    from voxbridge.tts.native_routes import NativePlaybackFeedback
    body=dict(epoch="one",received_seq=3,played_seq=2,buffered_ms=100,playing=True)
    body[field]=value
    with pytest.raises(ValueError):
        NativePlaybackFeedback().update("native-one",**body)


class FakePublisher:
    def __init__(self):
        self.native_pcm = self
        self.leases = set()
    async def touch_listener(self, listener, owner):
        self.leases.add(listener)
    def snapshot(self, after, epoch=None):
        if epoch not in (None,"one"):
            raise ValueError("epoch mismatch")
        return {"epoch":"one","cursor":0,"chunks":[]}


def route_client(host="127.0.0.1"):
    from voxbridge.tts.native_routes import register_native_pcm_routes
    app=FastAPI()
    app.state.tts_hls=FakePublisher()
    register_native_pcm_routes(app,token="secret",owner_key=lambda x:x,validate_listener=lambda x:x)
    return TestClient(app,client=(host,1234)),app


@pytest.mark.parametrize("host,headers", [("127.0.0.1",{}),("192.168.1.9",{"X-VoxBridge-Control-Token":"secret"})])
def test_pcm_route_rejects_browser_and_lan_before_acquiring_listener(host,headers):
    client,app=route_client(host)
    with client:
        assert client.get('/api/native/tts/native-one/pcm?after=-1',headers=headers).status_code==403
        assert app.state.tts_hls.leases==set()


def test_pcm_join_and_feedback_validate_epoch_and_available_cursor():
    client,app=route_client()
    headers={"X-VoxBridge-Control-Token":"secret"}
    with client:
        assert client.get('/api/native/tts/native-one/pcm?after=-1',headers=headers).json()=={
            "epoch":"one","cursor":0,"chunks":[]}
        body={"epoch":"one","received_seq":0,"played_seq":0,"buffered_ms":0,"playing":False}
        assert client.post('/api/native/tts/native-one/playback',headers=headers,json=body).status_code==200
        assert app.state.native_playback.urgent("one")
        body['received_seq']=4
        assert client.post('/api/native/tts/native-one/playback',headers=headers,json=body).status_code==409


def test_native_app_advertises_pcm_and_joins_without_hls_bootstrap(monkeypatch,tmp_path):
    from voxbridge.cli.demo_streaming_ws import _create_app
    from test_demo_streaming_ws_protocol import _args,_FakeASR,_FakeTTSSynthesizer,_FakeHLSEncoder
    monkeypatch.setenv('VOXBRIDGE_NATIVE_CONTROL_TOKEN','secret')
    args=_args();args.native_console=True;args.tts_native_pcm=True;args.tts_stream_chunks=True
    args.tts_hls_root_dir=str(tmp_path)
    args.tts_hls_encoder_factory=lambda root:_FakeHLSEncoder(root)
    app=_create_app(args,_FakeASR(),tts_synthesizer=_FakeTTSSynthesizer())
    with TestClient(app,client=('127.0.0.1',1234)) as client:
        assert client.get('/api/monitor/state').json().get('native_pcm') is True
        joined=client.get('/api/native/tts/native-test-12345678/pcm?after=-1',headers={'X-VoxBridge-Control-Token':'secret'})
        assert joined.status_code==200
        assert joined.json()['cursor']==0 and joined.json()['epoch'].startswith('epoch-')
