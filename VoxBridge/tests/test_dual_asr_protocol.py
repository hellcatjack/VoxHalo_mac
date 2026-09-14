"""Regression contract: former engine-switching clients cannot load XL."""
import numpy as np
import pytest
from fastapi.testclient import TestClient
from voxbridge.asr import ASREngineRegistry
from voxbridge.cli import demo_streaming_ws as demo
from test_demo_streaming_ws_protocol import _args, _FakeASR, _receive_until_type


@pytest.mark.parametrize("direction", ["zh2en", "en2zh"])
def test_old_xl_client_is_rejected_before_registry_and_can_retry_qwen(monkeypatch, direction):
    qwen = _FakeASR()
    registry = ASREngineRegistry(qwen, zipformer_factory=lambda: pytest.fail("XL loaded"))
    original_get = registry.get
    calls = []
    def get(engine_id="qwen3-asr", language=None):
        calls.append(engine_id)
        return original_get(engine_id, language)
    monkeypatch.setattr(registry, "get", get)
    monkeypatch.setattr(demo, "_should_skip_stream_decode", lambda **kwargs: False)
    client = TestClient(demo._create_app(_args(), qwen, asr_registry=registry))
    with client.websocket_connect("/ws") as ws:
        ready = ws.receive_json()
        assert [row["id"] for row in ready["asr_engines"]] == ["qwen3-asr"]
        ws.send_json({"type": "start", "asr_engine": "zipformer-xl", "translation_direction": direction})
        error = ws.receive_json()
        assert error["type"] == "error"
        assert "disabled" in error["message"]
        assert "zipformer-xl" not in calls
        ws.send_json({"type": "start", "asr_engine": "qwen3-asr", "translation_direction": direction})
        assert _receive_until_type(ws, "started")["asr_engine"] == "qwen3-asr"
        ws.send_bytes(np.full(3200, 3000, dtype="<i2").tobytes())
        assert _receive_until_type(ws, "partial")["text"]
        ws.send_json({"type": "finish", "mode": "stop"})
        assert _receive_until_type(ws, "final")["asr_engine"] == "qwen3-asr"


def test_legacy_default_start_and_unknown_engine_leave_qwen_usable():
    client = TestClient(demo._create_app(_args(), _FakeASR()))
    with client.websocket_connect("/ws") as ws:
        ws.receive_json()
        ws.send_json({"type": "start", "asr_engine": "invalid"})
        assert _receive_until_type(ws, "error")["message"]
        ws.send_json({"type": "start"})
        assert _receive_until_type(ws, "started")["asr_engine"] == "qwen3-asr"
        ws.send_json({"type": "finish", "mode": "stop"})
        _receive_until_type(ws, "final")
