from itertools import permutations
import pytest
from voxbridge.languages import translation_pair
from voxbridge.translation.service import TranslationService

CODES = ('zh', 'en', 'ja', 'fr', 'es', 'it', 'pt', 'hi')


def test_catalog_defines_eight_languages_and_all_distinct_pairs():
    from voxbridge.languages import LANGUAGES, pair_for_direction, translation_pair
    assert tuple(p.code for p in LANGUAGES) == CODES
    pairs = [translation_pair(a, b) for a, b in permutations(CODES, 2)]
    assert len({p.direction for p in pairs}) == 56
    assert all(pair_for_direction(p.direction) == p for p in pairs)
    for value in ('de2en', 'ja2ja', 'unknown', 'zh2en2fr'):
        with pytest.raises(ValueError):
            pair_for_direction(value)


@pytest.mark.parametrize('source,target,template', [
    ('French', 'Spanish', 'Translate the following segment into Spanish'),
    ('Japanese', 'Hindi', 'Translate the following segment into Hindi'),
    ('Chinese', 'Japanese', '将以下文本翻译为Japanese'),
    ('Hindi', 'Chinese', '将以下文本翻译为Chinese'),
])
def test_added_pairs_use_multilingual_template_without_bilingual_glossary(source, target, template):
    from voxbridge.translation.prompts import _build_translation_prompt
    prompt = _build_translation_prompt('Jesus Christ / 今天 / आज', source, target)
    assert prompt.startswith(template)
    assert 'ESV' not in prompt and '参考下面的翻译' not in prompt
    assert prompt.endswith('Jesus Christ / 今天 / आज')


@pytest.mark.parametrize('label,good,bad', [
    ('Japanese', '今日は晴れです。', 'This is a long untranslated sentence.'),
    ('Hindi', 'यह एक अच्छा दिन है।', 'This is a long untranslated sentence.'),
    ('French', 'Écoutez, où êtes-vous ?', '今日は晴れです。'),
    ('Spanish', '¿Qué estás haciendo?', '这是未翻译的句子。'),
])
def test_script_checks_recognize_each_script_without_dropping_names(label, good, bad):
    from voxbridge.translation.language_checks import _text_matches_source_language, _translation_needs_target_language_retry
    assert _text_matches_source_language(good, label)
    assert not _translation_needs_target_language_retry(good, label)
    assert _translation_needs_target_language_retry(bad, label)
    assert not _translation_needs_target_language_retry('OpenAI', label)
    assert not _translation_needs_target_language_retry('2026', label)


@pytest.mark.parametrize('language,text,units,tail', [
    ('Japanese', '最初の文です。次の文です！続き', ['最初の文です。', '次の文です！'], '続き'),
    ('Hindi', 'यह पहला वाक्य है। बाकी', ['यह पहला वाक्य है।'], 'बाकी'),
    ('French', 'M. Dupont arrive à 3.14 heures. Bonjour ! Suite', ['M. Dupont arrive à 3.14 heures.', 'Bonjour !'], 'Suite'),
    ('Spanish', 'El Sr. Pérez está aquí. ¿Cómo está?', ['El Sr. Pérez está aquí.', '¿Cómo está?'], ''),
    ('Portuguese', 'O Sr. Silva chegou. Até amanhã!', ['O Sr. Silva chegou.', 'Até amanhã!'], ''),
])
def test_language_specific_boundaries_preserve_abbreviations_and_scripts(language, text, units, tail):
    from voxbridge.interpretation.transcript import source_text_policy
    assert source_text_policy(language).split(text) == (units, tail)


@pytest.mark.asyncio
async def test_japanese_and_hindi_are_not_relabelled_as_chinese_or_english():
    from voxbridge.interpretation.contracts import TranslationRequest
    from voxbridge.translation.service import TranslationService
    calls = []
    class Backend:
        def translate(self, text, **kwargs):
            calls.append(kwargs)
            return 'Bonjour à tous.'
    service = TranslationService(Backend())
    for source, code, text in [('Japanese', 'ja', '今日は良い日です。'), ('Hindi', 'hi', 'आज एक अच्छा दिन है।')]:
        request = TranslationRequest('s', 1, text, source, 1, 1, source, 'French', code+'2fr')
        assert await service.translate(request) == 'Bonjour à tous.'
        assert calls[-1]['source_language'] == source


def test_revision_extensions_preserve_unicode_scripts():
    from voxbridge.streaming.spoken_source import after_spoken_prefix, unspoken_extension
    from voxbridge.streaming.text_pool import dedup_segment_join
    assert after_spoken_prefix('नमस्ते दुनिया', 'नमस्ते') == 'दुनिया'
    assert unspoken_extension('नमस्ते', 'नमस्ते दुनिया') == 'दुनिया'
    assert unspoken_extension('今日は', '今日は晴れです。') == '晴れです。'
    assert after_spoken_prefix('café délicieux', 'café') == 'délicieux'
    assert after_spoken_prefix('दीन', 'दिन') is None
    assert dedup_segment_join('नमस्ते', 'दुनिया') == 'नमस्ते दुनिया'
    assert dedup_segment_join('café', 'délicieux') == 'café délicieux'


@pytest.mark.asyncio
@pytest.mark.parametrize('source,target,text', [('hi','en','नमस्ते दुनिया।'),('hi','zh','नमस्ते दुनिया।'),('ja','en','こんにちは。'),('ja','zh','こんにちは。')])
async def test_new_pair_rejects_untranslated_script(source, target, text):
    from voxbridge.interpretation.contracts import TranslationRequest
    class Backend:
        enforce_target_language_output = True
        def translate(self, text, **kwargs): return text
    pair = translation_pair(source, target)
    request = TranslationRequest('s',1,text,pair.source.asr_label,1,1,pair.source.asr_label,pair.target.tts_label,pair.direction)
    assert await TranslationService(Backend()).translate(request) == ''


def test_hindi_and_japanese_sentence_endings():
    from voxbridge.streaming.sentence_rules import _text_ends_with_sentence_terminator
    assert _text_ends_with_sentence_terminator('यह पहला वाक्य है।')
    assert _text_ends_with_sentence_terminator('「晴れです。」')


def test_ellipsis_and_decomposed_accents_do_not_break_units():
    from voxbridge.interpretation.transcript import source_text_policy
    from voxbridge.streaming.text_pool import dedup_segment_join, trim_prefix_overlap
    from voxbridge.streaming.sentence_rules import _join_segments
    from voxbridge.cli.demo_streaming_ws import _translation_unit_boundary_kind
    assert source_text_policy('fr').split('Bonjour... Ensuite.') == (['Bonjour...', 'Ensuite.'], '')
    assert dedup_segment_join('cafe\u0301', 'délicieux') == 'cafe\u0301 délicieux'
    assert _join_segments(['cafe\u0301', 'délicieux']) == 'cafe\u0301 délicieux'
    assert trim_prefix_overlap('नमस्ते दुनिया।', 'दुनिया अच्छी है') == (' अच्छी है', 6)
    assert _translation_unit_boundary_kind('यह पहला वाक्य है।') == 'sentence'

@pytest.mark.parametrize('old,new,extension', [('2026年。','2026年我们相聚。','我们相聚。'),('AI。','AI帮助我们。','帮助我们。'),('コーヒー。','コーヒーを飲みます。','を飲みます。')])
def test_mixed_script_spoken_prefix_can_extend(old,new,extension):
    from voxbridge.streaming.spoken_source import unspoken_extension
    assert unspoken_extension(old,new) == extension
