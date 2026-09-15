import unicodedata
import pytest
from test_kokoro_tts import FakeFactory, FakeChineseG2P, make_config
from voxbridge.tts.kokoro_onnx import KokoroOnnxSynthesizer, TTSConfigurationError
from voxbridge.tts.chunks import split_speech_chunks

CASES = [('ja', 'jm_kumo', 'ja'), ('fr', 'ff_siwis', 'fr-fr'), ('es', 'em_alex', 'es'), ('it', 'im_nicola', 'it'), ('pt', 'pm_alex', 'pt-br'), ('hi', 'hm_omega', 'hi')]

@pytest.mark.parametrize('code,voice,tag', CASES)
def test_target_voice_and_phonemizer_routing(tmp_path, code, voice, tag):
    factory = FakeFactory()
    synth = KokoroOnnxSynthesizer(config=make_config(tmp_path), kokoro_factory=factory, ja_g2p_factory=lambda: lambda text: ('konn iʨiwa', None))
    synth.synthesize('こんにちは。' if code == 'ja' else 'Bonjour.', code)
    call = factory.models[0].calls[0]
    assert (call.voice, call.lang, call.is_phonemes) == (voice, tag, code == 'ja')
    assert call.text == ('konn iʨiwa' if code == 'ja' else 'Bonjour.')
    assert factory.calls[0]['model_path'].name == 'english_model_path'


def test_all_non_chinese_targets_share_one_model(tmp_path):
    factory = FakeFactory()
    synth = KokoroOnnxSynthesizer(config=make_config(tmp_path), kokoro_factory=factory, zh_g2p_factory=FakeChineseG2P, ja_g2p_factory=lambda: lambda text: 'a')
    for code in ['zh', 'en', 'ja', 'fr', 'es', 'it', 'pt', 'hi'] * 2:
        synth.synthesize('Sample.', code)
    assert len(factory.models) == 2
    assert len(factory.models[1].calls) == 14

@pytest.mark.parametrize('code,text,expected', [('ja', '今日は晴れです。明日も晴れです！', ('今日は晴れです。', '明日も晴れです！')), ('hi', 'यह अच्छा है। फिर मिलेंगे॥', ('यह अच्छा है। ', 'फिर मिलेंगे॥')), ('fr', 'M. Dupont paie 3.14 euros. À demain !', ('M. Dupont paie 3.14 euros. ', 'À demain !'))])
def test_new_chunks_prefer_sentences(code, text, expected):
    assert split_speech_chunks(text, code) == expected

@pytest.mark.parametrize('code,unit', [('ja', 'か\u3099'), ('hi', 'कि'), ('fr', 'e\u0301'), ('es','ñ'), ('it','è'), ('pt','ã')])
def test_long_chunks_preserve_graphemes_and_all_text(code, unit):
    text = '  ' + unit * 600 + '。'
    chunks = split_speech_chunks(text, code)
    assert ''.join(chunks) == text
    assert all(len(chunk) <= 260 for chunk in chunks)
    assert all(not unicodedata.category(chunk[0]).startswith('M') for chunk in chunks)


def test_chinese_complete_sentence_keeps_clauses():
    text = '现在我们一起祷告，求主赐给我们平安，让我们听见祂的话语。'
    assert split_speech_chunks(text, 'zh') == (text,)


def test_validation_rejects_missing_voice_without_audio(tmp_path):
    factory = FakeFactory()
    def create(**kwargs):
        model = factory(**kwargs)
        model.get_voices = lambda: ['am_michael']
        return model
    synth = KokoroOnnxSynthesizer(config=make_config(tmp_path), kokoro_factory=create)
    with pytest.raises(TTSConfigurationError, match='ff_siwis'):
        synth.validate_language('fr')
    assert not factory.models[0].calls


def test_offline_dictionary_installer_rejects_unverified_archive(tmp_path):
    import importlib.util
    from pathlib import Path
    spec = importlib.util.spec_from_file_location('setup_assets', Path(__file__).resolve().parents[2] / 'scripts/setup_assets.py')
    setup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(setup)
    archive = tmp_path / 'downloads/open_jtalk_dic_utf_8-1.11.tar.gz'
    archive.parent.mkdir()
    archive.write_bytes(b'not the pinned dictionary')
    with pytest.raises(RuntimeError, match='dictionary.*checksum'):
        setup.install_japanese_dictionary(tmp_path)
