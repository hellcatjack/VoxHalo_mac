import json
import urllib.request

import pytest

from voxbridge.cli.demo_streaming_ws import OpenAIAPITranslator
from voxbridge.cli.demo_streaming_ws import _split_translation_units_and_tail


POLICY_ECHO = (
    "该文本是一段基督教对话场景的描述。根据要求，翻译时应忠实于原文，"
    "不添加任何内容，同时遵循通用的中文圣经译名和教会用语。"
    "最终的输出结果仅为翻译后的文本本身，无需进行解释。"
)


def responses(monkeypatch, outputs, finish_reason='stop'):
    requests = []

    class Response:
        def __init__(self, content):
            self.content = content

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def read(self):
            return json.dumps({"choices": [{"finish_reason": finish_reason, "message": {
                "role": "assistant", "content": self.content,
            }}]}).encode()

    def send(request, timeout):
        requests.append(json.loads(request.data))
        return Response(outputs[min(len(requests) - 1, len(outputs) - 1)])

    monkeypatch.setattr(urllib.request, "urlopen", send)
    return requests


def translator():
    return OpenAIAPITranslator("http://127.0.0.1:8876", "hy-mt", "English", "Chinese",
                               max_new_tokens=256, sampling_profile="mac-verified")


def test_policy_explanation_is_retried_before_it_can_reach_speech(monkeypatch):
    requests = responses(monkeypatch, [POLICY_ECHO, "该隐对他的兄弟亚伯说话。"])
    assert translator().translate("Cain spoke to Abel, his brother.", translation_direction="en2zh") == "该隐对他的兄弟亚伯说话。"
    assert len(requests) == 2
    assert requests[0]["messages"] != requests[1]["messages"]
    assert "Cain spoke to Abel, his brother." in requests[1]["messages"][0]["content"]
    assert requests[1]["temperature"] == requests[0]["temperature"] == 0


def test_persistent_policy_echo_fails_closed_after_one_recovery_attempt(monkeypatch):
    requests = responses(monkeypatch, [POLICY_ECHO])
    with pytest.raises(ValueError, match="translation output"):
        translator().translate("Cain spoke to Abel, his brother.", translation_direction="en2zh")
    assert len(requests) == 2


def test_real_source_about_translation_rules_is_not_censored(monkeypatch):
    requests = responses(monkeypatch, [POLICY_ECHO])
    source = "This text describes a Christian dialogue. Translation must be faithful to the source, without additions; use common Chinese Bible terminology. Only output the translated text."
    assert translator().translate(source) == POLICY_ECHO
    assert len(requests) == 1


def test_ordinary_translation_keeps_original_prompt_and_one_request(monkeypatch):
    requests = responses(monkeypatch, ["耶稣基督"])
    assert translator().translate("Jesus Christ") == "耶稣基督"
    assert len(requests) == 1


def test_incomplete_preposition_is_joined_to_its_following_phrase():
    units, tail = _split_translation_units_and_tail('On your. Belly, you shall go.')
    assert units == ['On your Belly, you shall go.']
    assert tail == ''


def test_incomplete_phrase_stays_pending_without_delaying_complete_short_sentences():
    units, tail = _split_translation_units_and_tail('God spoke. On your.')
    assert units == ['God spoke.']
    assert tail == 'On your'


def test_relative_clause_remains_attached_to_preceding_sentence():
    units, tail = _split_translation_units_and_tail('He rested from all his work. That he had done in creation.')
    assert units == ['He rested from all his work That he had done in creation.']
    assert tail == ''


def test_chinese_conditional_keeps_its_conclusion():
    units, tail = _split_translation_units_and_tail('假如。你认为？他的反应太过激烈。对他的做法不认同，其实是我们不了解圣洁的意义。')
    assert len(units) == 1
    assert '假如' in units[0] and '其实' in units[0]
    assert tail == ''


def test_church_names_use_simple_ordered_hint_and_unhinted_recovery(monkeypatch):
    requests = responses(monkeypatch, [POLICY_ECHO, "该隐对亚伯说话。"])
    assert translator().translate("Cain spoke to Abel.") == "该隐对亚伯说话。"
    prompt = requests[0]['messages'][0]['content']
    assert 'Cain 翻译成 该隐' in prompt
    assert 'Abel 翻译成 亚伯' in prompt
    assert '尼希米' not in prompt
    assert '将以下文本翻译为Chinese' in prompt
    assert '忠实' not in prompt
    recovery = requests[1]['messages'][0]['content']
    assert '参考下面的翻译' not in recovery
    assert 'Cain spoke to Abel.' in recovery


def test_terminology_keeps_source_entity_order_to_avoid_swapping_their_roles():
    from voxbridge.streaming.church_terms import terminology_hint
    hint = terminology_hint('Now Abel was a keeper of sheep, and Cain a worker of the ground.', 'Chinese')
    assert hint.index('Abel 翻译成 亚伯') < hint.index('Cain 翻译成 该隐')


def test_name_terminology_does_not_match_inside_unrelated_words(monkeypatch):
    requests = responses(monkeypatch, ["他能够完成这件事。"])
    translator().translate('He is able to finish it.')
    assert '亚伯' not in requests[0]['messages'][0]['content']


@pytest.mark.parametrize('sentence', ['I saw her.', "This is God's will.", 'That is where he came from.'])
def test_complete_english_sentences_do_not_wait_for_unnecessary_continuation(sentence):
    assert _split_translation_units_and_tail(sentence) == ([sentence], '')


def test_late_addition_ignores_punctuation_and_skips_a_following_row_that_covers_it():
    from voxbridge.streaming.spoken_source import unspoken_extension
    assert unspoken_extension('他发现多比亚。', '他发现多比亚，多比亚是亚扪人。') == '多比亚是亚扪人。'
    assert unspoken_extension('He named her Eve.', 'He named her Eve, because she was their mother.',
                              ['Because she was their mother.']) == ''
    assert unspoken_extension('He named her Eve.', 'He named her EVE!') == ''
    assert unspoken_extension('He did not go.', 'He did go.') == ''


def test_late_addition_tracks_mixed_language_words_without_repeating_the_spoken_prefix():
    from voxbridge.streaming.spoken_source import unspoken_extension
    assert unspoken_extension('这是Adam。', '这是Adam的妻子。') == '的妻子。'
    assert unspoken_extension('God spoke, and they listened.',
                              'God spoke, and they listened, then rested.') == 'then rested.'


def test_token_limit_exhaustion_does_not_publish_an_incomplete_translation(monkeypatch):
    requests = responses(monkeypatch, ['这是一段尚未完成的'], finish_reason='length')
    with pytest.raises(ValueError, match='translation output'):
        translator().translate('This is a complete source sentence.')
    assert len(requests) <= 3


def test_extreme_expansion_is_retried_without_silently_trimming_the_output(monkeypatch):
    requests = responses(monkeypatch, ['无关的长篇文字。' * 50, '上帝说话了。'])
    assert translator().translate('God spoke.') == '上帝说话了。'
    assert len(requests) == 2


def test_a_later_row_keeps_only_the_remainder_after_an_already_spoken_supplement():
    from voxbridge.streaming.spoken_source import after_spoken_prefix
    assert after_spoken_prefix('但是他发现了一个让他非常非常痛心，也让他非常愤怒的事情。',
                               '但是他发现了一个让他非常非常痛心，') == '也让他非常愤怒的事情。'
    assert after_spoken_prefix('She shall be called woman.', 'she shall be called woman') == ''
    assert after_spoken_prefix('She did not go.', 'She did go.') is None
