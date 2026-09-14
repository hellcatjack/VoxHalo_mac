import pytest


def test_pending_age_survives_growth_and_prefix_consumption():
    from voxbridge.streaming.submission_policy import PendingTextClock
    clock = PendingTextClock()
    clock.update("我们", 1.0)
    clock.update("我们今天", 3.0)
    assert clock.age(8.0) == 7.0
    clock.consume_prefix("我们")
    assert clock.age(8.0) == 5.0


def test_pending_revision_keeps_matched_content_age_but_replacement_resets():
    from voxbridge.streaming.submission_policy import PendingTextClock
    clock = PendingTextClock()
    clock.update("我们愿意帮助大家", 1.0)
    clock.update("我们不愿意帮助大家", 4.0)
    assert clock.age(8.0) == 7.0
    clock.update("下午讨论另外一个问题", 7.0)
    assert clock.age(8.0) == 1.0
    clock.update("", 8.0)
    assert clock.age(9.0) == 0.0


def test_pending_suffix_keeps_its_own_age_after_a_commit():
    from voxbridge.streaming.submission_policy import PendingTextClock
    clock = PendingTextClock()
    clock.update("我们感谢上帝，", 1.0)
    clock.update("我们感谢上帝，今天继续学习", 4.0)
    clock.update("今天继续学习", 6.0)
    assert clock.age(8.0) == 4.0


def test_pending_clock_is_bounded_and_whitespace_does_not_reset_it():
    from voxbridge.streaming.submission_policy import PendingTextClock
    clock = PendingTextClock(max_chars=20)
    clock.update("我们 今天", 1.0)
    clock.update("我们今天" + "学习" * 30, 2.0)
    assert len(clock.text) == 20
    assert clock.age(8.0) == 7.0


def test_same_decode_cannot_inflate_agreement_and_new_segment_resets():
    from voxbridge.streaming.submission_policy import StableCandidate
    candidate = StableCandidate()
    candidate.observe("我们感谢上帝，", (1, 4), 1.0)
    candidate.observe("我们感谢上帝，", (1, 4), 2.0)
    assert candidate.hits == 1
    candidate.observe("我们感谢上帝，", (1, 5), 2.2)
    assert candidate.hits == 2
    assert candidate.age(3.0) == 2.0
    candidate.observe("我们感谢上帝，", (2, 1), 4.0)
    assert candidate.hits == 1
    assert candidate.age(5.0) == 1.0
    candidate.observe("我们感谢上帝。", (2, 2), 5.0)
    assert candidate.hits == 1


def test_decoder_observation_counts_real_chunks_but_only_observed_hypotheses():
    from voxbridge.streaming.submission_policy import DecodeObservation
    observed = DecodeObservation()
    assert not observed.observe(1, 0, "", 0.0)
    assert observed.observe(1, 1, "今天", 1.0)
    assert not observed.observe(1, 1, "今天", 1.2)
    assert observed.observe(1, 4, "今天我们一起学习", 2.0)
    assert observed.actual_decodes == 4
    assert observed.hypotheses == 2
    assert observed.key == (1, 4)
    assert observed.observe(2, 1, "继续", 3.0)
    assert observed.actual_decodes == 5
    assert observed.hypotheses == 3


@pytest.mark.parametrize("chunk", [None, -1, "3", True])
def test_missing_or_invalid_decoder_evidence_does_not_create_agreement(chunk):
    from voxbridge.streaming.submission_policy import DecodeObservation
    observed = DecodeObservation()
    assert not observed.observe(1, chunk, "这里已有文字", 1.0)
    assert observed.key is None
    assert observed.hypotheses == 0


def test_soft_budget_uses_smaller_real_clause_but_not_fixed_character_cut():
    from voxbridge.streaming.submission_policy import PendingClausePolicy
    from voxbridge.cli.demo_streaming_ws import _split_translation_units_and_tail
    policy = PendingClausePolicy(target=32, aged_target=24, budget_sec=8.0)
    clause = "我们今天一起思想圣经当中的教导并且学习如何彼此相爱，"
    text = clause + "并且将这份从上帝而来的盼望带给我们身边所有需要帮助的人"
    def split(text, target):
        return _split_translation_units_and_tail(text, target_cjk_chars=target)
    first = policy.split(text, [], now=1.0, splitter=split)
    assert first.units == []
    aged = policy.split(text, [], now=9.0, splitter=split)
    assert aged.units == [clause]
    assert aged.tail.startswith("并且")
    assert aged.used_small_target
    no_punctuation = text.replace("，", "")
    result = policy.split(no_punctuation, [], now=10.0, splitter=split)
    assert result.units == []
    assert result.tail == no_punctuation


def test_aged_split_never_resegments_processed_prefix():
    from voxbridge.streaming.submission_policy import PendingClausePolicy
    from voxbridge.cli.demo_streaming_ws import _split_translation_units_and_tail
    policy = PendingClausePolicy(target=32, aged_target=24, budget_sec=8.0)
    prefix = "我们今天一起思想圣经当中的教导并且学习如何彼此相爱，也要记得主的恩典，"
    pending = "然后我们继续思想上帝如何在每天的生活当中引导我们，愿我们学习顺服"
    def split(text, target):
        return _split_translation_units_and_tail(text, target_cjk_chars=target)
    policy.split(prefix + pending, [prefix], now=1.0, splitter=split)
    result = policy.split(prefix + pending, [prefix], now=9.0, splitter=split)
    assert result.units[0] == prefix
    assert "".join(result.units) + result.tail == prefix + pending
    assert len(result.units) == 2


def test_revised_processed_prefix_falls_back_without_forcing_old_words():
    from voxbridge.streaming.submission_policy import PendingClausePolicy
    from voxbridge.cli.demo_streaming_ws import _split_translation_units_and_tail
    policy = PendingClausePolicy(target=32, aged_target=24, budget_sec=0)
    def split(text, target):
        return _split_translation_units_and_tail(text, target_cjk_chars=target)
    text = "新的识别纠正了前面的内容，后文还在继续"
    result = policy.split(text, ["旧的识别原文。"], now=1.0, splitter=split)
    assert not result.prefix_matched
    assert not result.used_small_target
    assert "".join(result.units) + result.tail == text


def test_smaller_candidate_boundary_survives_consumption_until_source_revision():
    from voxbridge.streaming.submission_policy import PendingClausePolicy
    from voxbridge.cli.demo_streaming_ws import _split_translation_units_and_tail
    policy = PendingClausePolicy(target=32, aged_target=24, budget_sec=8)
    first = "我们今天一起思想圣经当中的教导并且学习如何彼此相爱，"
    second = "然后我们继续思想上帝如何在每天的生活当中引导我们，"
    third = "愿我们在生活当中继续学习顺服上帝"
    def split(text, target):
        return _split_translation_units_and_tail(text, target_cjk_chars=target)
    policy.split(first, [], now=0, splitter=split)
    aged = policy.split(first + second + third, [], now=9, splitter=split)
    assert aged.units == [first, second]
    consumed = policy.split(first + second + third, [first], now=10, splitter=split)
    assert consumed.units == [first, second]
    assert consumed.pending_age_sec == 1
    revised = (first + second + third).replace("引导我们，", "带领我们并且")
    result = policy.split(revised, [first], now=11, splitter=split)
    assert "".join(result.units) + result.tail == revised
    assert second not in result.units


@pytest.mark.parametrize("text", [
    "这并不是说我们不需要悔改而是要相信上帝始终爱我们",
    "约翰福音三章十六节告诉我们上帝的爱是何等长阔高深",
    "奉献并不是一千二百三十四点五元而是另外一个数目",
])
def test_aged_budget_never_splits_unpunctuated_negation_names_or_numbers(text):
    from voxbridge.streaming.submission_policy import PendingClausePolicy
    from voxbridge.cli.demo_streaming_ws import _split_translation_units_and_tail
    result = PendingClausePolicy(budget_sec=0).split(text, [], now=100,
        splitter=lambda value, target: _split_translation_units_and_tail(value, target_cjk_chars=target))
    assert result.units == []
    assert result.tail == text


def test_new_session_resets_policy_but_segment_rotation_keeps_pending_age():
    from voxbridge.streaming.submission_policy import PendingClausePolicy
    from voxbridge.cli.demo_streaming_ws import _split_translation_units_and_tail
    policy = PendingClausePolicy()
    def split(text, target):
        return _split_translation_units_and_tail(text, target_cjk_chars=target)
    text = "我们今天一起思想圣经当中的教导并且学习如何彼此相爱，后续仍在继续"
    policy.split(text, [], now=1, splitter=split)
    policy.reset(keep_pending_age=True)
    assert policy.split(text, [], now=10, splitter=split).used_small_target
    policy.reset()
    decision = policy.split(text, [], now=11, splitter=split)
    assert not decision.used_small_target
    assert decision.units == []


def test_retracted_punctuation_in_processed_prefix_cannot_swallow_pending_sentence():
    from voxbridge.streaming.submission_policy import PendingClausePolicy
    from voxbridge.cli.demo_streaming_ws import _split_translation_units_and_tail
    policy = PendingClausePolicy(budget_sec=0)
    first = "那当中我们可能有很多爷爷奶奶，或是家长很喜欢陪小孩子玩这个积木，"
    question = "对不对？"
    new_sentence = "乐高这个积木，都是一小块一小块不同的颜色的方块，那可以有千变万化的组合。"
    rewritten = first.rstrip("，") + question + new_sentence
    result = policy.split(rewritten, [first, question], now=10,
        splitter=lambda value, target: _split_translation_units_and_tail(value, target_cjk_chars=target))
    assert result.prefix_matched
    assert result.units[:2] == [first, question]
    assert "".join(result.units[2:]) + result.tail == new_sentence


def test_service_environment_can_enable_shadow_and_cli_can_roll_it_back(monkeypatch):
    import sys
    from voxbridge.cli.demo_streaming_ws import parse_args
    monkeypatch.setenv("VOXBRIDGE_QWEN_SUBMISSION_MODE", "shadow")
    monkeypatch.setattr(sys, "argv", ["voxbridge"])
    assert parse_args().qwen_submission_mode == "shadow"
    monkeypatch.setattr(sys, "argv", ["voxbridge", "--qwen-submission-mode", "off"])
    assert parse_args().qwen_submission_mode == "off"


def test_invalid_submission_environment_fails_at_configuration(monkeypatch):
    import sys
    from voxbridge.cli.demo_streaming_ws import parse_args
    monkeypatch.setenv("VOXBRIDGE_QWEN_SUBMISSION_MODE", "unknown")
    monkeypatch.setattr(sys, "argv", ["voxbridge"])
    with pytest.raises(SystemExit) as exc:
        parse_args()
    assert exc.value.code == 2


def test_production_cli_rejects_unqualified_adaptive_candidate(monkeypatch):
    import sys
    from voxbridge.cli.demo_streaming_ws import parse_args
    monkeypatch.setattr(sys, "argv", ["voxbridge", "--qwen-submission-mode", "adaptive"])
    with pytest.raises(SystemExit) as exc:
        parse_args()
    assert exc.value.code == 2
