import asyncio

from voxbridge.streaming.caption_preview import (
    CaptionPreview, caption_source_remainder, caption_tail_for_translation, committed_caption_remainder, preview_source,
)


def test_chinese_preview_for_english_needs_a_complete_clause():
    assert preview_source("弟兄姐妹要在言语上，", complete_chinese_clause=True) == ""
    assert preview_source("如果这些数字还有变化。", complete_chinese_clause=True) == ""
    assert preview_source("如果这些数字还有变化，那么我们应该重新核对，接着通知各小组。", complete_chinese_clause=True) == (
        "如果这些数字还有变化，那么我们应该重新核对，"
    )
    assert preview_source("我们下周会重新核对数据，", complete_chinese_clause=True) == "我们下周会重新核对数据，"
    assert preview_source("当前各小组都准备好了，", complete_chinese_clause=True) == "当前各小组都准备好了，"
    assert preview_source("弟兄姐妹要在言语上，") == "弟兄姐妹要在言语上，"
    prefix = "最后一点，随着父母年龄的增大，"
    full = prefix + "他们会觉得自己老了，请多给他们一点耐心，"
    assert preview_source(prefix, complete_chinese_clause=True) == ""
    complete = preview_source(full, complete_chinese_clause=True)
    assert complete == prefix + "他们会觉得自己老了，"
    assert preview_source(full, complete_chinese_clause=True, after=complete) == full
    assert preview_source(full.replace("老了", "变了"), complete_chinese_clause=True, after=complete) == ""


def test_chinese_preview_recovers_a_lost_boundary_before_a_new_subject():
    first = "如果你在照顾你年迈的父母的时候，你可以体会他们的心"
    next_clause = "我爸爸做手术，我在医院里面陪了他五天，"
    raw = first + next_clause + "那种近身的陪护当中，"
    assert preview_source(first, complete_chinese_clause=True) == ""
    assert preview_source(raw, complete_chinese_clause=True) == first
    assert preview_source(raw, complete_chinese_clause=True, after=first) == first + next_clause
    assert caption_source_remainder(raw, first) == raw[len(first):]
    assert caption_source_remainder(first + "情会变得平静。", first) is None
    assert caption_source_remainder(first + "。", first + "，") == ""
    hospital = first + "我爸爸做手术，在医院里面陪了他五天"
    assert preview_source(hospital + "但那种近身的陪护当中", complete_chinese_clause=True,
                          after=first) == hospital
    attitudes = "我可以体会他作为一个老年人的心思态度"
    assert preview_source(attitudes + "这时候，圣经教导我们", complete_chinese_clause=True) == attitudes


def test_chinese_preview_consumes_the_same_words_across_comma_edits():
    first = "如果你照顾年迈的父母，你可以体会他们的心"
    remainder = "我爸爸做手术，我在医院陪了他五天，"
    corrected = "如果你照顾年迈的父母，你可以体会，他们的心，"
    formal = corrected + remainder
    assert caption_source_remainder(formal, first) == remainder
    assert preview_source(formal, complete_chinese_clause=True, after=first) == formal
    assert caption_source_remainder(formal.replace("可以", "不可以"), first) is None
    assert caption_source_remainder("系统记录了10,000人，稍后公布。", "系统记录了10000人，") is None
    assert caption_source_remainder("系统记录了10000人，稍后公布。", "系统记录了10,000人，") is None
    assert caption_source_remainder(formal.replace("的心，", "的心情，"), first) is None


def test_caption_tail_keeps_the_unread_condition():
    first = "在英文的，他们会觉得老了。"
    source = "在英文的，他们会觉得老了，他们不行如果你在照顾你年迈的父母的时候，"
    unread = caption_source_remainder(source, first)
    assert caption_tail_for_translation(unread) == "他们不行。如果你在照顾你年迈的父母的时候，"
    assert preview_source("我爸爸做手做手术，", complete_chinese_clause=True) == ""
    assert preview_source("我爸爸做手术，我在医院里陪了他五天，", complete_chinese_clause=True)


def test_formal_cut_before_a_previewed_noun_does_not_replay_its_clause():
    earlier = "当我们父母年龄增大，"
    full = earlier + "我们要学习保卫、维护他们的人格，"
    cut = full.removesuffix("人格，") + "。"
    assert committed_caption_remainder(cut, full) == ""
    assert committed_caption_remainder(cut.replace("维护", "取消"), full) is None
    assert committed_caption_remainder(cut, full.replace("人格", "人格和身心健康")) is None
    captions = CaptionPreview(None, None, lambda: True, complete_chinese_clause=True)
    captions._published_after = "prior"
    captions._published = [(earlier, "As our parents age,"), (full, "Protect their dignity.")]
    assert captions.committed_caption_prefix(cut, "prior") == (full, "Protect their dignity.")
    assert captions.committed_caption_prefix(cut, "different-occurrence") is None
    assert caption_source_remainder(cut, full) is None


def test_reporting_lead_waits_for_what_the_speaker_is_saying():
    for head, rest in [("弟兄姐妹，在《以弗所书》里面讲到十六节讲到", "要爱惜光阴"),
                       ("对父母的爱。我们接下来看", "教导的第二点")]:
        assert not preview_source(head + "。", complete_chinese_clause=True)
        assert preview_source(head + rest + "。", complete_chinese_clause=True) == head + rest + "。"


def test_chinese_preview_prefetches_the_restart_before_the_next_clause():
    async def scenario():
        published = []
        first = "随着父母年纪渐渐增大，他们会觉得自己老了"

        async def translate(source, target):
            return "As their parents age, they may feel that they have grown old."

        async def publish(item, _):
            published.append(item.source)

        captions = CaptionPreview(translate, publish, lambda: True, complete_chinese_clause=True)
        captions.offer(first + "。", "previous-item", "English", observation=(1, 1, 4))
        captions.offer(first + "，他们不行。如果你照顾父母", "previous-item", "English", observation=(1, 1, 5))
        await captions._task
        assert published == [first + "，"]
        assert captions.committed_caption_prefix(first + "他们不行。", "different-item") is None
        await captions.close()

    asyncio.run(scenario())


def test_chinese_preview_prepares_an_unpunctuated_claim_until_the_boundary_arrives():
    async def scenario():
        calls, sent = [], []
        claim = "如果你在照顾你年迈的父母的时候，你可以体会他们的心"

        async def translate(source, target):
            calls.append(source)
            return "If you care for your elderly parents, you can understand their feelings."

        async def publish(item, _):
            sent.append(item.source)

        captions = CaptionPreview(translate, publish, lambda: True, complete_chinese_clause=True)
        captions.offer(claim, "prior", "English", observation=(1, 1, 4))
        await captions._task
        assert calls == [claim] and not sent
        captions.offer(claim, "prior", "English", observation=(1, 1, 5))
        assert not sent
        captions.offer(claim + "我爸。", "prior", "English", observation=(1, 1, 6))
        await captions._task
        assert sent == [claim] and calls == [claim]
        await captions.close()

    asyncio.run(scenario())


def test_chinese_preview_prefetch_waits_for_decode_agreement_then_allows_a_continuation():
    async def scenario():
        calls, published = [], []
        clause = "我们已经检查完需要的数据，"
        extended = clause + "大家明天可以一起公布结果，"

        async def translate(text, target):
            calls.append(text)
            return "We have finished checking the data."

        async def publish(item, _):
            published.append(item.source)

        preview = CaptionPreview(translate, publish, lambda: True, complete_chinese_clause=True)
        preview.offer(clause, "", "English", observation=(0, 1, 1))
        await preview._task
        assert calls == [clause] and not published
        preview.offer(clause, "", "English", observation=(0, 1, 1))
        assert not published
        preview.offer(extended, "", "English", observation=(0, 1, 2))
        await preview._task
        assert published == [clause] and calls == [clause]
        preview.offer(extended, "", "English", observation=(0, 1, 3))
        await preview._task
        assert published == [clause]
        preview.offer(extended, "", "English", observation=(0, 1, 4))
        await preview._task
        assert published == [clause, extended]
        assert calls == [clause, extended[len(clause):]]
        corrected = clause + "大家下周可以公布经过复核的结果。"
        assert preview.committed_caption_prefix(corrected, "") == (clause, "We have finished checking the data.")
        await preview.close()

    asyncio.run(scenario())


def test_hospital_story_preview_waits_for_the_next_claim_and_translates_only_new_words():
    async def scenario():
        calls = []
        sent = []
        head = "我爸爸做手术，我在医院里面陪了他五天，"
        bridge = "但那种近身的陪护当中，"
        claim = "我就可以体会他作为一个病人的心"
        head_en = "My father had surgery, and I stayed with him in the hospital for five days."
        tail_en = "During that close care, I could understand his feelings as a patient."

        async def translate(text, target):
            calls.append(text)
            return head_en if text == head else tail_en

        async def publish(item, text):
            sent.append((item, text))

        previews = CaptionPreview(translate, publish, lambda: True, complete_chinese_clause=True)
        previews.offer(head, "prior", "English", observation=(1, 1, 1))
        await previews._task
        previews.offer(head + bridge, "prior", "English", observation=(1, 1, 2))
        await previews._task
        assert sent[0][1] == head_en
        previews.offer(head + bridge, "prior", "English", observation=(1, 1, 3))
        assert calls == [head]
        previews.offer(head + bridge + claim + "。", "prior", "English", observation=(1, 1, 4))
        await previews._task
        assert len(sent) == 1 and calls == [head, bridge + claim + "。"]
        assert previews.prepared_for_commit(head + bridge + "我无法体会他的感受。", "prior") is None
        assert previews.prepared_for_commit(head + bridge + claim + "，", "another-row") is None
        item, text = previews.prepared_for_commit(head + bridge + claim + "，", "prior")
        assert item.base_source == head
        assert item.source == head + bridge + claim + "，"
        assert text == head_en + " " + tail_en
        previews.offer(head + bridge + claim + "，他作为一个老年人", "prior", "English",
                       observation=(1, 1, 5))
        # The formal commit can be handled before the accepted preview task runs.
        item, text = previews.prepared_for_commit(head + bridge + claim + "，", "prior")
        assert item.source.endswith("心，") and text == head_en + " " + tail_en
        await previews._task
        assert calls == [head, bridge + claim + "。"]
        await previews.close()

    asyncio.run(scenario())


def test_chinese_preview_crosses_rollover_only_with_new_lookahead():
    async def scenario(lookahead, expected):
        published = []
        prefix = "最后一点，随着父母年龄的增大，他们会觉得自己老了，"

        async def translate(source, target):
            return "One last point: as parents age, they may feel that they are getting old."

        async def publish(item, _):
            published.append(item.source)

        preview = CaptionPreview(translate, publish, lambda: True, complete_chinese_clause=True)
        preview.offer(prefix + "他们不。", "", "English", observation=(1, 2, 8))
        await preview._task
        assert not published
        preview.offer(prefix + lookahead, "", "English", observation=(1, 3, 1))
        if preview._task and not preview._task.done():
            await preview._task
        assert published == ([prefix] if expected else [])
        await preview.close()

    asyncio.run(scenario("他们不。", False))
    asyncio.run(scenario("他们不再需要提醒了。", True))


def test_chinese_comma_inherits_word_agreement_only_with_fresh_following_words():
    async def scenario():
        published = []

        async def translate(source, target):
            return "At this time, the Bible teaches us:"

        async def publish(item, _):
            published.append(item.source)

        preview = CaptionPreview(translate, publish, lambda: True, complete_chinese_clause=True)
        old = "这时候，圣经教导我们。"
        prefix = "这时候，圣经教导我们："
        preview.offer(old, "", "English", observation=(1, 2, 1))
        preview.offer(prefix + "，当我们父母年龄增大", "", "English", observation=(1, 2, 2))
        await preview._task
        assert published == [prefix]
        await preview.close()

    asyncio.run(scenario())


def test_preview_source_is_bounded_and_requires_a_readable_boundary():
    assert preview_source("We need to carefully check") == ""
    assert preview_source("今天我们会仔细检查") == ""
    assert preview_source("After the meeting ends, we can decide.") == "After the meeting ends,"
    assert preview_source("数字已经增加到1,200件，接下来讨论计划。") == "数字已经增加到1,200件，"
    assert preview_source("负责项目的同事在现场呢，") == ""
    assert preview_source("我们先核对数量啊，再把变更的项目确认一下，最后公布结果。") == "我们先核对数量啊，再把变更的项目确认一下，"
    assert preview_source("We will ask Dr. Smith about it, then decide.") == "We will ask Dr. Smith about it,"
    assert preview_source("These are the generations, of the heavens and the earth,") == "These are the generations, of the heavens and the earth,"
    assert preview_source("Yes, we should check these figures today;") == "Yes, we should check these figures today;"
    assert preview_source("Our total has reached 1,200.5 units:") == "Our total has reached 1,200.5 units:"
    assert preview_source("The next step is to verify the figures before we,") == ""
    assert preview_source("We will review the seven,") == ""
    assert preview_source(" ".join(["longerword"] * 32) + ",") == ""


def test_long_chinese_clause_uses_real_boundary_and_preserves_the_unread_cursor():
    first = "今天下午各个小组会把这几周收集到的新资料按照不同年份和主题依次整理好再一起交给负责审核的同事，"
    second = "审核结束之后就可以向大家说明结果，"
    assert preview_source(first[:-1], complete_chinese_clause=True) == ""
    assert preview_source(first + second, complete_chinese_clause=True) == first
    history = first * 8
    assert preview_source(history + second, complete_chinese_clause=True, after=history) == history + second


def test_timeout_retries_once_only_after_a_new_confirmed_decode():
    async def scenario(always_fails):
        attempts, published = [], []
        source = "明天下午我们会一起公布审核结果，"

        async def translate(text, target):
            attempts.append(text)
            if always_fails or len(attempts) == 1:
                raise TimeoutError
            return "We will announce the review results tomorrow afternoon."

        async def publish(item, text):
            published.append(item.source)

        captions = CaptionPreview(translate, publish, lambda: True, complete_chinese_clause=True)
        for chunk in (1, 1, 2, 2, 3, 4, 5):
            captions.offer(source + "随后通知相关小组", "one", "English", observation=(1, 1, chunk))
            await captions._task
            if chunk == 1:
                assert len(attempts) == 1 and not published
        assert attempts == [source, source]
        assert published == ([] if always_fails else [source])
        await captions.close()

    asyncio.run(scenario(True))
    asyncio.run(scenario(False))


def test_time_condition_displays_once_then_only_translates_the_consequence():
    async def scenario():
        calls, sent = [], []
        first = "如果你在照顾年迈的父母的时候，"
        next_part = "你可以体会他们的心"

        async def translate(source, target):
            calls.append(source)
            return ("When you care for your aging parents," if source == first
                    else "you can understand their feelings.")

        async def publish(preview, _):
            sent.append(preview)

        captions = CaptionPreview(translate, publish, lambda: True, complete_chinese_clause=True)
        for chunk, text in enumerate([first+"你可以", first+"你可以体会", first+next_part+"我爸。",
                                      first+next_part+"我爸爸做了手术。"], start=1):
            captions.offer(text, "previous", "English", observation=(0, 1, chunk))
            await captions._task
        assert calls == [first, next_part]
        assert [item.base_source for item in sent] == ["", first]
        await captions.close()

    asyncio.run(scenario())


def test_formal_translation_can_cancel_preview_and_prevents_publication():
    async def scenario():
        entered = asyncio.Event()
        exited = asyncio.Event()
        published = []

        async def translate(source, target):
            entered.set()
            try:
                await asyncio.sleep(30)
            finally:
                exited.set()

        async def publish(preview, text):
            published.append(text)

        preview = CaptionPreview(translate, publish, lambda: True)
        preview.offer("We should meet on Friday,", "", "Chinese", observation=(0, 1, 1))
        preview.offer("We should meet on Friday,", "", "Chinese", observation=(0, 1, 2))
        await asyncio.wait_for(entered.wait(), timeout=1)
        preview.cancel()
        await asyncio.wait_for(exited.wait(), timeout=1)
        await preview.close()
        assert not published

    asyncio.run(scenario())


def test_draft_for_replaced_source_cannot_publish_and_busy_model_declines():
    async def scenario():
        entered = asyncio.Event()
        release = asyncio.Event()
        published = []
        busy = True

        async def translate(source, target):
            entered.set()
            await release.wait()
            return "我们会在周五见面"

        async def publish(preview, text):
            published.append(text)

        preview = CaptionPreview(translate, publish, lambda: not busy)
        preview.offer("We should meet on Friday,", "", "Chinese", observation=(0, 1, 1))
        preview.offer("We should meet on Friday,", "", "Chinese", observation=(0, 1, 2))
        await asyncio.sleep(0)
        assert not entered.is_set()
        busy = False
        preview.offer("We should meet on Friday,", "", "Chinese", observation=(0, 1, 3))
        await asyncio.wait_for(entered.wait(), timeout=1)
        preview.offer("We should meet on Monday,", "", "Chinese", observation=(0, 1, 4))
        release.set()
        await preview._task
        assert not published

    asyncio.run(scenario())


def test_distinct_decoder_updates_confirm_punctuation_and_only_one_preview_is_published():
    async def scenario():
        calls, published = [], []

        async def translate(source, target):
            calls.append((source, target))
            return "第一次讨论结束后"

        async def publish(value, text):
            published.append((value.after_sentence_id, text))

        preview = CaptionPreview(translate, publish, lambda: True)
        for observation in [(0, 1, 1), (0, 1, 1), (1, 2, 1)]:
            preview.offer("After the first discussion ends,", "", "Chinese", observation=observation)
        assert preview._task is None
        preview.offer("After the first discussion ends, we will act", "", "Chinese", observation=(1, 2, 2))
        await preview._task
        for chunk in (3, 4):
            preview.offer("After the second discussion ends,", "", "Chinese", observation=(1, 2, chunk))
        assert calls == [("After the first discussion ends,", "Chinese")]
        assert published == [("", "第一次讨论结束后")]
        await preview.close()

    asyncio.run(scenario())
