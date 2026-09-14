import sys
import numpy as np
import pytest


def test_native_silero_state_is_local_and_resettable(monkeypatch):
    from voxbridge.streaming.onnx_vad import NumpySilero
    sessions = []
    class Session:
        def __init__(self, *args, **kwargs): sessions.append(self)
        def get_inputs(self):
            return [type('Input', (), {'name': name})() for name in ('x','h','c')]
        def run(self, _, values):
            assert values['x'].shape == (1,512)
            return np.array([[0.75]],np.float32),values['h']+1,values['c']+2
    monkeypatch.setattr('onnxruntime.InferenceSession', Session)
    a,b=NumpySilero('one.onnx'),NumpySilero('one.onnx')
    assert a(np.ones(512,np.float32),16000)==pytest.approx(.75)
    assert np.all(a.h==1) and np.all(b.h==0)
    a.reset_states();assert np.all(a.h==0) and np.all(a.c==0)
    with pytest.raises(ValueError): a(np.zeros(511,np.float32),16000)


def test_silero_observer_accepts_native_numpy_without_torch(monkeypatch):
    from voxbridge.streaming.vad_support import create_silero_onnx_observer
    monkeypatch.setitem(sys.modules,'torch',None)
    class Model:
        def reset_states(self): pass
        def __call__(self,audio,sr): return audio.mean()
    observer=create_silero_onnx_observer(load_model=lambda **kw:Model())
    assert observer.feed(np.full(512,.75,np.float32)).is_speech
