from concurrent.futures import ThreadPoolExecutor
import pytest
from voxbridge.asr import ASREngineRegistry


def test_default_qwen_does_not_load_or_advertise_xl():
    calls = []
    model = object()
    registry = ASREngineRegistry(model, zipformer_factory=lambda: calls.append(1))
    assert registry.get().asr is model
    assert [row["id"] for row in registry.describe()] == ["qwen3-asr"]
    assert registry.describe()[0]["languages"] == ["Chinese", "English"]
    assert calls == []


@pytest.mark.parametrize("language", [None, "Chinese", "English"])
def test_disabled_xl_cannot_load_even_with_injected_factory(language):
    calls = []
    registry = ASREngineRegistry(object(), zipformer_factory=lambda: calls.append(1))
    with pytest.raises(ValueError, match="disabled"):
        registry.get("zipformer-xl", language)
    assert calls == []
    assert registry.get().id == "qwen3-asr"


def test_old_model_directory_does_not_enable_xl_or_inspect_files(tmp_path, monkeypatch):
    from pathlib import Path
    registry = ASREngineRegistry(object(), zipformer_model_dir=str(tmp_path))
    def forbidden(*args, **kwargs):
        pytest.fail("disabled registry must not inspect XL model files")
    monkeypatch.setattr(Path, "is_file", forbidden)
    assert [row["id"] for row in registry.describe()] == ["qwen3-asr"]
    with pytest.raises(ValueError, match="disabled"):
        registry.get("zipformer-xl", "Chinese")


def test_concurrent_disabled_requests_cannot_construct_model():
    calls = []
    registry = ASREngineRegistry(object(), zipformer_factory=lambda: calls.append(1))
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(registry.get, "zipformer-xl", "Chinese") for _ in range(8)]
        for future in futures:
            with pytest.raises(ValueError, match="disabled"):
                future.result(timeout=3)
    assert calls == []


def test_unknown_engine_is_rejected_without_changing_qwen():
    registry = ASREngineRegistry(object())
    binding = registry.get()
    with pytest.raises(ValueError, match="Unknown"):
        registry.get("wrong", "Chinese")
    assert registry.get() is binding
