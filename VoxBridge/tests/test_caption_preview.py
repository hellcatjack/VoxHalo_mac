import asyncio

from voxbridge.streaming.caption_preview import CaptionPreview, preview_source


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
