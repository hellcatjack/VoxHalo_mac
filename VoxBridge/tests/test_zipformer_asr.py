from types import SimpleNamespace

import numpy as np
import pytest


class Stream:
    def __init__(self):
        self.parts = []
        self.pending = 0
        self.finished_calls = 0
        self.result = ""

    def accept_waveform(self, rate, wav):
        assert rate == 16000
        self.parts.append(wav.copy())
        self.pending += 1

    def input_finished(self):
        self.finished_calls += 1


class Recognizer:
    def create_stream(self):
        return Stream()

    def is_ready(self, stream):
        return stream.pending > 0

    def decode_stream(self, stream):
        stream.pending -= 1
        stream.result = "  最终结果 " if stream.finished_calls else " 当前结果 "

    def get_result(self, stream):
        return stream.result


def test_incremental_input_and_finish_are_private_and_idempotent():
    from voxbridge.asr.zipformer import ZipformerASR

    asr = ZipformerASR("", recognizer=Recognizer())
    first = asr.init_streaming_state(language="Chinese", context="ignored Qwen context")
    second = asr.init_streaming_state(language="Chinese")
    wav = np.full(3200, 0.25, dtype=np.float32)
    asr.streaming_transcribe(wav, first)
    assert first.text == "当前结果"
    assert second.text == ""
    assert second.stream.parts == []
    asr.finish_streaming_transcribe(first)
    asr.finish_streaming_transcribe(first)
    assert first.text == "最终结果"
    assert first.finished
    assert first.stream.finished_calls == 1
    assert [part.size for part in first.stream.parts] == [3200, 12800]
    np.testing.assert_array_equal(first.stream.parts[0], wav)
    assert not np.any(first.stream.parts[1])
    with pytest.raises(ValueError, match="finished"):
        asr.streaming_transcribe(wav, first)


def test_empty_stream_does_not_decode_padding_into_hallucinated_text():
    from voxbridge.asr.zipformer import ZipformerASR

    asr = ZipformerASR("", recognizer=Recognizer())
    state = asr.init_streaming_state(language="Chinese")
    asr.streaming_transcribe(np.empty(0, dtype=np.float32), state)
    asr.finish_streaming_transcribe(state)
    assert state.text == ""
    assert state.stream.parts == []
    assert state.finished


@pytest.mark.parametrize("language", ["English", "French"])
def test_xl_cannot_be_started_with_non_chinese_language(language):
    from voxbridge.asr.zipformer import ZipformerASR

    with pytest.raises(ValueError, match="Chinese"):
        ZipformerASR("", recognizer=Recognizer()).init_streaming_state(language=language)


def test_native_configuration_uses_cpu_without_automatic_endpoints_or_hotwords(tmp_path, monkeypatch):
    from voxbridge.asr.zipformer import ZipformerASR

    for name in ("encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx", "tokens.txt"):
        (tmp_path / name).write_bytes(b"model fixture")
    calls = []

    def factory(**kwargs):
        calls.append(kwargs)
        return Recognizer()

    monkeypatch.setitem(__import__("sys").modules, "sherpa_onnx", SimpleNamespace(
        OnlineRecognizer=SimpleNamespace(from_transducer=factory)))
    asr = ZipformerASR(str(tmp_path), num_threads=2)
    state = asr.init_streaming_state(language="Chinese")
    asr.streaming_transcribe(np.ones(3200, dtype=np.float32), state)
    assert state.text == "当前结果"
    assert calls[0]["provider"] == "cpu"
    assert calls[0]["model_type"] == "zipformer2"
    assert calls[0]["num_threads"] == 2
    assert calls[0]["sample_rate"] == 16000
    assert calls[0]["decoding_method"] == "modified_beam_search"
    assert calls[0]["max_active_paths"] == 4
    assert calls[0]["enable_endpoint_detection"] is False
    assert not calls[0].get("hotwords_file")
