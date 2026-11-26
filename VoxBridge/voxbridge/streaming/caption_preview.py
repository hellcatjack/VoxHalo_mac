"""Best-effort translation of the current unread source prefix."""

import asyncio
from contextlib import suppress
from dataclasses import dataclass
import re
from typing import Awaitable, Callable

import regex


_IDEOGRAPHS = re.compile(r"[\u3040-\u30ff\u3400-\u9fff\uac00-\ud7af\U00020000-\U0003134f]")
_WORDS = regex.compile(r"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*")
_BREAK = re.compile(r"[，,；;：:。！？!?।॥]|\.(?=\s|$)")
_ABBREVIATION = re.compile(r"\b(?:[A-Za-z]|Mr|Mrs|Ms|Dr|Prof|St|Sr|Jr|vs|etc)$", re.IGNORECASE)
_OPEN_ENGLISH_CLAUSE = re.compile(
    r"\s+(?:before|after|when|while|because|although|unless|until|if|once|so that)"
    r"(?:\s+(?:I|we|you|he|she|they|it))?$",
    re.IGNORECASE,
)
_OPEN_ENGLISH_QUANTITY = re.compile(
    r"\s+(?:the|another|these|those)\s+(?:\d+(?:st|nd|rd|th)?|"
    r"one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|"
    r"first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)$",
    re.IGNORECASE,
)
_COMPLEMENT_AFTER_COMMA = re.compile(r"\s*(?:of|than)\b", re.IGNORECASE)


def _reading_weight(text: str) -> int:
    characters = len(_IDEOGRAPHS.findall(text))
    words = len(_WORDS.findall(_IDEOGRAPHS.sub(" ", text)))
    return characters + 2 * words


def preview_source(text: str) -> str:
    """Return the first readable, punctuated source clause."""
    source = " ".join(text.split()).lstrip(",，；;。!?！？ ")
    for match in _BREAK.finditer(source[:120]):
        clause = source[:match.start()].rstrip()
        if not clause:
            continue
        punctuation = match.group()
        following = source[match.end():match.end() + 1]
        if punctuation in {",", "，"}:
            # Recognizers can add commas inside a clause after a hesitation.
            if clause[-1] in "呢吧嘛啊呀呃嗯" or _COMPLEMENT_AFTER_COMMA.match(source, match.end()):
                continue
        if ((punctuation in {",", "，", ":"} and clause[-1].isdigit()
                and (not following or following.isdigit()))
                or (punctuation == "." and (
                    (following and not following.isspace()) or _ABBREVIATION.search(clause)
                ))):
            continue
        weight = _reading_weight(clause)
        if weight > 42:
            break
        if weight >= 8 and not (
            _OPEN_ENGLISH_CLAUSE.search(clause) or _OPEN_ENGLISH_QUANTITY.search(clause)
        ):
            return source[:match.end()]
    return ""


@dataclass(frozen=True)
class Preview:
    source: str
    after_sentence_id: str
    target: str


class CaptionPreview:
    """At most one in-flight request. Formal work can cancel it immediately."""

    def __init__(
        self,
        translate: Callable[[str, str], Awaitable[str]],
        publish: Callable[[Preview, str], Awaitable[None]],
        idle: Callable[[], bool],
    ) -> None:
        self.translate = translate
        self.publish = publish
        self.idle = idle
        self._latest: Preview | None = None
        self._offered: Preview | None = None
        self._published_after: str | None = None
        self._observation: tuple[int, int, int] | None = None
        self._confirmed = False
        self._task: asyncio.Task | None = None

    def offer(self, text: str, after_sentence_id: str, target: str, *, observation: tuple[int, int, int]) -> None:
        source = preview_source(text)
        if not source:
            self.cancel()
            return
        preview = Preview(source, after_sentence_id, target)
        if observation != self._observation:
            self._confirmed = (
                preview == self._latest and self._observation is not None
                and observation[:2] == self._observation[:2] and observation[2] > self._observation[2]
            )
            self._observation = observation
        elif preview != self._latest:
            self._confirmed = False
        self._latest = preview
        if (
            not self._confirmed
            or self._published_after == after_sentence_id
            or preview == self._offered
            or (self._task is not None and not self._task.done())
            or not self.idle()
        ):
            return
        self._offered = preview
        self._task = asyncio.create_task(self._run(preview))

    async def _run(self, preview: Preview) -> None:
        try:
            if not self.idle():
                self._offered = None
                return
            translated = await asyncio.wait_for(self.translate(preview.source, preview.target), timeout=2.5)
            latest = self._latest
            if not translated or _reading_weight(translated) < 8 or latest is None or not self.idle():
                return
            if (
                latest.after_sentence_id != preview.after_sentence_id
                or latest.target != preview.target
                or latest.source != preview.source
            ):
                return
            await self.publish(preview, translated)
            self._published_after = preview.after_sentence_id
        except Exception:
            # Streaming captions are optional. The formal translation worker
            # owns errors and retries for completed units.
            pass

    def cancel(self) -> None:
        offered = self._offered is not None
        self._latest = self._offered = None
        self._observation = None
        self._confirmed = False
        if offered and self._task is not None and not self._task.done():
            self._task.cancel()

    async def close(self) -> None:
        self.cancel()
        if self._task is not None:
            with suppress(asyncio.CancelledError):
                await self._task
