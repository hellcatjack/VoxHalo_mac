def test_unpunctuated_units_preserve_all_characters_and_keep_short_tail():
    from voxbridge.asr.text import split_unpunctuated_chinese

    text = "我们今天一起思想圣经中的教导并且学习在日常生活当中彼此关心互相帮助感谢上帝赐给我们平安"
    units, tail = split_unpunctuated_chinese(text, target_chars=16)
    assert "".join([*units, tail]) == text
    assert len(units) == 2
    assert units[0] == "我们今天一起思想圣经中的教导并且"
    assert tail
    assert split_unpunctuated_chinese("short English phrase", target_chars=4) == ([], "short English phrase")


def test_native_prefix_gate_requires_time_and_distinct_decodes_and_resets_on_revision():
    from voxbridge.asr.text import StablePrefixGate

    gate = StablePrefixGate(stable_sec=0.8, stable_hits=3)
    assert gate.ready_end(["第一句"], 0, 1, seq=1, now=10) == 0
    assert gate.ready_end(["第一句"], 0, 1, seq=1, now=11) == 0
    assert gate.ready_end(["第一句"], 0, 1, seq=2, now=11.1) == 0
    assert gate.ready_end(["第一句"], 0, 1, seq=3, now=11.2) == 1
    assert gate.ready_end(["修订句"], 0, 1, seq=4, now=12) == 0
    gate.clear()
    assert gate.ready_end(["第一句"], 0, 1, seq=5, now=20) == 0
