import io
import wave
from dataclasses import dataclass

import numpy as np
import pytest

from voxbridge.tts.kokoro_onnx import (
    KokoroOnnxSynthesizer,
    KokoroTTSConfig,
    TTSConfigurationError,
    TTSSynthesisError,
)


@dataclass
class FakeCreateCall:
    text: str
    voice: str
    speed: float
    lang: str
    is_phonemes: bool


class FakeKokoro:
    def __init__(self, samples=None, sample_rate: int = 24000) -> None:
        self.samples = np.asarray(
            samples if samples is not None else [0.0, 0.25, -0.25], dtype=np.float32
        )
        self.sample_rate = sample_rate
        self.calls: list[FakeCreateCall] = []

    def create(self, text, *, voice, speed, lang, is_phonemes):
        self.calls.append(FakeCreateCall(text, voice, speed, lang, is_phonemes))
        return self.samples, self.sample_rate


class FakeFactory:
    def __init__(self) -> None:
        self.calls: list[dict] = []
        self.models: list[FakeKokoro] = []

    def __call__(self, **kwargs):
        self.calls.append(kwargs)
        model = FakeKokoro()
        self.models.append(model)
        return model


class FakeChineseG2P:
    def __init__(self) -> None:
        self.calls: list[str] = []

    def __call__(self, text: str):
        self.calls.append(text)
        return "ni↓ xau↓", None


def make_config(tmp_path, **overrides) -> KokoroTTSConfig:
    paths = {}
    for name in (
        "english_model_path",
        "english_voices_path",
        "chinese_model_path",
        "chinese_voices_path",
        "chinese_config_path",
    ):
        path = tmp_path / name
        path.write_bytes(b"asset")
        paths[name] = path
    paths.update(overrides)
    return KokoroTTSConfig(**paths)


def test_english_synthesis_returns_pcm16_wav(tmp_path):
    factory = FakeFactory()
    synth = KokoroOnnxSynthesizer(config=make_config(tmp_path), kokoro_factory=factory)

    audio = synth.synthesize("The translation is stable.", "English")

    assert audio.wav_bytes[:4] == b"RIFF"
    assert audio.sample_rate == 24000
    assert audio.duration_ms == 0
    with wave.open(io.BytesIO(audio.wav_bytes), "rb") as wav:
        assert wav.getnchannels() == 1
        assert wav.getsampwidth() == 2
        assert wav.getframerate() == 24000
        assert wav.getnframes() == 3
    call = factory.models[0].calls[0]
    assert call.voice == "am_michael"
    assert call.lang == "en-us"
    assert call.is_phonemes is False


def test_chinese_synthesis_uses_misaki_phonemes(tmp_path):
    factory = FakeFactory()
    g2p = FakeChineseG2P()
    synth = KokoroOnnxSynthesizer(
        config=make_config(tmp_path),
        kokoro_factory=factory,
        zh_g2p_factory=lambda: g2p,
    )

    synth.synthesize("稳定的译文。", "Chinese")

    assert g2p.calls == ["稳定的译文。"]
    call = factory.models[0].calls[0]
    assert call.text == "ni↓ xau↓"
    assert call.voice == "zf_001"
    assert call.lang == "cmn"
    assert call.is_phonemes is True
    assert factory.calls[0]["vocab_config"].name == "chinese_config_path"


@pytest.mark.parametrize("language", ["English", "Chinese"])
def test_synthesis_accepts_absolute_per_call_speed(tmp_path, language):
    factory = FakeFactory()
    synth = KokoroOnnxSynthesizer(
        config=make_config(tmp_path, speed=1.05),
        kokoro_factory=factory, zh_g2p_factory=FakeChineseG2P,
    )

    synth.synthesize("Catch up now.", language, speed=1.575)
    synth.synthesize("Back at baseline.", language)

    assert factory.models[0].calls[0].speed == pytest.approx(1.575)
    assert factory.models[0].calls[1].speed == pytest.approx(1.05)


@pytest.mark.parametrize("speed", [0.49, 2.01, float("inf"), float("nan")])
def test_synthesis_rejects_invalid_per_call_speed(tmp_path, speed):
    synth = KokoroOnnxSynthesizer(
        config=make_config(tmp_path),
        kokoro_factory=FakeFactory(),
    )

    with pytest.raises(TTSSynthesisError, match="speed"):
        synth.synthesize("Invalid speed.", "English", speed=speed)


def test_adapter_passes_cpu_only_runtime_configuration(tmp_path):
    factory = FakeFactory()
    synth = KokoroOnnxSynthesizer(
        config=make_config(tmp_path, cpu_threads=6), kokoro_factory=factory
    )

    synth.synthesize("Ready.", "English")

    assert factory.calls[0]["providers"] == ("CPUExecutionProvider",)
    assert factory.calls[0]["cpu_threads"] == 6


def test_adapter_rejects_missing_assets_before_runtime_import(tmp_path):
    config = make_config(tmp_path)
    config.english_model_path.unlink()

    with pytest.raises(TTSConfigurationError, match="English model"):
        KokoroOnnxSynthesizer(
            config=config,
            kokoro_factory=lambda **kwargs: pytest.fail("runtime must not be loaded"),
        )


def test_adapter_rejects_unsupported_language_and_oversized_text(tmp_path):
    synth = KokoroOnnxSynthesizer(config=make_config(tmp_path), kokoro_factory=FakeFactory())

    with pytest.raises(TTSSynthesisError, match="target language"):
        synth.synthesize("Stable.", "French")
    with pytest.raises(TTSSynthesisError, match="1000"):
        synth.synthesize("x" * 1001, "English")


def test_models_and_g2p_load_lazily_once(tmp_path):
    factory = FakeFactory()
    g2p_factory_calls = []

    def make_g2p():
        g2p_factory_calls.append(True)
        return FakeChineseG2P()

    synth = KokoroOnnxSynthesizer(
        config=make_config(tmp_path),
        kokoro_factory=factory,
        zh_g2p_factory=make_g2p,
    )

    assert factory.calls == []
    synth.synthesize("One.", "English")
    synth.synthesize("Two.", "English")
    synth.synthesize("一。", "Chinese")
    synth.synthesize("二。", "Chinese")

    assert len(factory.calls) == 2
    assert len(g2p_factory_calls) == 1


def test_chunk_iteration_is_lazy_and_preserves_voice_and_speed(tmp_path):
    factory = FakeFactory()
    synth = KokoroOnnxSynthesizer(config=make_config(tmp_path), kokoro_factory=factory)
    chunks = synth.iter_synthesize('One two three four five six seven eight, nine ten.', 'English', speed=1.1)
    first_text, first_audio = next(chunks)
    assert first_text == 'One two three four five six seven eight, '
    assert first_audio.sample_rate == 24000
    assert len(factory.models[0].calls) == 1
    assert factory.models[0].calls[0].voice == 'am_michael'
    assert factory.models[0].calls[0].speed == 1.1
    assert next(chunks)[0] == 'nine ten.'
    with pytest.raises(StopIteration):
        next(chunks)


def test_float_speed_chinese_export_keeps_fractional_speed_at_onnx_boundary(tmp_path, monkeypatch):
    import json
    from types import SimpleNamespace
    import onnxruntime as ort
    config = make_config(tmp_path)
    with config.chinese_voices_path.open('wb') as f:
        np.savez(f, zm_029=np.ones((512, 1, 256), dtype=np.float32))
    config.chinese_config_path.write_text(json.dumps({'vocab': {'a': 1}}))
    calls = []
    class Session:
        _model_path = str(config.chinese_model_path)
        def get_providers(self): return ['CPUExecutionProvider']
        def get_inputs(self):
            return [SimpleNamespace(name='input_ids', type='tensor(int64)'),
                    SimpleNamespace(name='style', type='tensor(float)'),
                    SimpleNamespace(name='speed', type='tensor(float)')]
        def run(self, names, inputs):
            calls.append(inputs)
            assert inputs['speed'].dtype == np.float32
            return [np.ones(100, dtype=np.float32)]
    monkeypatch.setattr(ort, 'InferenceSession', lambda *args, **kwargs: Session())
    model = KokoroOnnxSynthesizer._create_cpu_kokoro(
        model_path=config.chinese_model_path, voices_path=config.chinese_voices_path,
        vocab_config=config.chinese_config_path, cpu_threads=2, providers=('CPUExecutionProvider',))
    for speed in [0.9, 1.05, 1.26, 1.47, 1.575]:
        model.create('a', voice='zm_029', speed=speed, is_phonemes=True, trim=False)
        assert calls[-1]['speed'][0] == pytest.approx(speed)
        assert calls[-1]['input_ids'].tolist() == [[0, 1, 0]]
        assert calls[-1]['style'].shape == (1, 256)
    calls.clear()
    audio, rate = model.create('a' * 1100, voice='zm_029', speed=1.575,
                               is_phonemes=True, trim=False)
    # Observe the real create -> adapter -> ONNX boundary, not just its planner.
    assert sum(call['input_ids'].shape[1] - 2 for call in calls) == 1100
    assert all(2 < call['input_ids'].shape[1] <= 512 for call in calls)
    assert all(call['speed'][0] == pytest.approx(1.575) for call in calls)
    assert len(audio) == 300 and rate == 24000


@pytest.mark.parametrize('phonemes', ['a/ ' * 400, 'a' * 1100, 'a' * 509, 'a' * 510],
                         ids=['words', 'no-delimiters', '509', '510'])
def test_chinese_long_phonemes_are_not_empty_or_silently_truncated(phonemes):
    from voxbridge.tts.kokoro_float_speed import FloatSpeedKokoro
    model = object.__new__(FloatSpeedKokoro)
    batches = model._split_phonemes(phonemes)
    assert all(0 < len(batch) <= 510 for batch in batches)
    assert ''.join(batches).replace(' ', '') == phonemes.replace(' ', '')
    if '/' in phonemes:
        assert all(batch.rstrip().endswith('/') for batch in batches[:-1])


def test_chinese_normal_phoneme_batching_remains_identical():
    from kokoro_onnx import Kokoro
    from voxbridge.tts.kokoro_float_speed import FloatSpeedKokoro
    phonemes = 'ni↓ xau↓, ʈʂʰuŋ1/ uən2.'
    assert object.__new__(FloatSpeedKokoro)._split_phonemes(phonemes) == object.__new__(Kokoro)._split_phonemes(phonemes)


@pytest.mark.parametrize('phonemes', ['a/ ' * 210 + '.', 'a/ ' * 169 + 'aa/.',
                                    'a/' * 255 + '.', 'a' * 510 + '.'],
                         ids=['long-clause', 'word-at-limit', 'slash-at-limit', 'no-delimiter'])
def test_long_chinese_phoneme_clause_keeps_its_final_period(phonemes):
    from voxbridge.tts.kokoro_float_speed import FloatSpeedKokoro
    batches = object.__new__(FloatSpeedKokoro)._split_phonemes(phonemes)
    assert all(batch.strip('.,!?;: /') for batch in batches)
    assert all(len(batch) <= 510 for batch in batches)
    assert ''.join(batches).replace(' ', '') == phonemes.replace(' ', '')
