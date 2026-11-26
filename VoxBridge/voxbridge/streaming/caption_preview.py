"""Best-effort translation of the current unread source prefix."""

import asyncio
from contextlib import suppress
from dataclasses import dataclass, replace
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
_CHINESE_DEPENDENT_LEAD = re.compile(
    r"^(?:如果|假如|假设|要是|倘若|只要|除非|虽然|尽管|即使|哪怕|因为|由于|至于|对于|关于|随着|"
    r"当(?!然|时|前|地|场|晚|日|中|年|初|下|即))"
)
_CHINESE_CLAUSE_BOUNDARY = re.compile(r"[，；：]|(?<!\d),|,(?!\d)")
_CHINESE_OPEN_TOPIC = re.compile(
    r"(?:方面|层面|过程|时候|而言|之中|当中|之内|期间|以后|之后|之前|"
    r"(?:讲到|提到|谈到|指出)(?:说)?|(?:接下来|下面|现在)(?:来看|看一看|看看|看|来讲|来谈)|"
    r"(?:言语|行为|行动|态度|文字|形式|意义|原则|能力|技术)上|"
    r"作为(?:一个|一名)?[^，。,!?！？的]{1,12}|"
    r"(?:可以|能够|要|应该|需要|就)(?:体会|了解|理解|观察|保卫|维护))$"
)
_SOFT_CLAUSE_MARKS = ",，;；:："
_CLAUSE_MARKS = _SOFT_CLAUSE_MARKS + "。.!?！？"
_HAN_COMMA = regex.compile(r"(?<=\p{Han})[，,](?=\p{Han})")
_CHINESE_PROVISIONAL_END = re.compile(r"(?:体会|理解|了解|明白)[^，。！？]{2,11}(?:的心|的感受)$")
_CHINESE_TIME_CONDITION = re.compile(
    r"(?:如果|假如|当)[^，,。！？；;]{8,}(?:的时候|期间)[，,]"
    r"(?=(?:我|我们|你|你们|他|他们|她|她们|大家)(?:就|可以|会|能|要|应))"
)
_CHINESE_BARE_PROCEDURE = re.compile(
    r"^(?:我|你|他|她)(?:的)?(?:爸爸|妈妈|父亲|母亲|爸|妈)(?:做手){1,2}术$"
)
_CHINESE_BEFORE_CONDITIONAL = regex.compile(
    r"(?<=(?:已经不行|已经老了|他们不行|她们不行))(?=(?:如果|假如)\p{Han}{2,})"
)
_CHINESE_DISCOURSE_BOUNDARY = regex.compile(
    r"(?<=(?:的心心?|心思态度|感受|想法|这一点))"
    r"(?=我(?:的)?(?:父亲|母亲|爸爸|妈妈|爸|妈)(?:\p{Han}|[，,。！？.!?]|$))"
    r"|(?<=(?:的心心?|心思态度|感受|想法|这一点))"
    r"(?=(?:这(?:个)?时候|接下来)[，,]?\p{Han}{2,})"
    r"|(?<=[一二两三四五六七八九十百\d](?:天|周|个月|年|小时|分钟))(?=但(?:是|那|这|在)\p{Han}{2,})"
    r"|(?<=[一二两三四五六七八九十百\d](?:天|周|个月|年|小时|分钟))(?=在那(?:种|段)\p{Han}{2,})"
    r"|(?<=(?:觉得(?:自己)?老了|感到(?:自己)?老了))(?=(?:他|她)们(?:不行|不能|已经))"
    r"|(?<=(?:已经不行|已经老了|他们不行|她们不行))(?=(?:如果|假如|所以|但是)\p{Han}{2,})"
)


def _reading_weight(text: str) -> int:
    characters = len(_IDEOGRAPHS.findall(text))
    words = len(_WORDS.findall(_IDEOGRAPHS.sub(" ", text)))
    return characters + 2 * words


def _clean_source(text: str) -> str:
    return " ".join(text.split()).lstrip(",，；;。!?！？ ")


def _caption_prefix_end(source: str, prefix: str) -> int | None:
    if not prefix:
        return None
    interchangeable = "。.,，;；:："
    body = prefix[:-1] if prefix[-1] in interchangeable else prefix
    if not body:
        return None
    if source.startswith(body):
        end = len(body)
    else:
        # Commas may move when the next decode hears the rest of a Chinese
        # clause. Match the words and map the end back into the original text.
        expected = _HAN_COMMA.sub("", body)
        commas = {mark.start() for mark in _HAN_COMMA.finditer(source)}
        end = 0
        for character in expected:
            while end in commas:
                end += 1
            if end == len(source) or source[end] != character:
                return None
            end += 1
    following = source[end:end + 1]
    if prefix != body and following and following in interchangeable:
        if body[-1].isdigit() and following in ".," and source[end + 1:end + 2].isdigit():
            return None
        return end + 1
    if prefix != body and following and not _IDEOGRAPHS.fullmatch(body[-1]):
        return None
    if (following and _IDEOGRAPHS.fullmatch(body[-1]) and _IDEOGRAPHS.match(following)
            and not _CHINESE_DISCOURSE_BOUNDARY.match(source, end)):
        return None
    return end


def caption_source_remainder(source: str, prefix: str) -> str | None:
    """Return the unread text only after proving continuity of this occurrence."""
    source, prefix = _clean_source(source), _clean_source(prefix)
    end = _caption_prefix_end(source, prefix)
    return _clean_source(source[end:]) if end is not None else None


def committed_caption_remainder(source: str, published: str) -> str | None:
    """Prove the part of this formal row not already covered by its preview."""
    tail = caption_source_remainder(source, published)
    if tail is not None:
        return tail
    # A hard cut can commit an earlier decode ending in a possessive, while
    # the displayed decode already includes its noun. Only accept an exact
    # source prefix and a short Han completion, never a changed word.
    formal = _HAN_COMMA.sub("", _clean_source(source).rstrip(_CLAUSE_MARKS))
    preview = _HAN_COMMA.sub("", _clean_source(published).rstrip(_CLAUSE_MARKS))
    if (formal.endswith("的") and len(formal) >= 8 and preview.startswith(formal)
            and regex.fullmatch(r"\p{Han}{1,4}", preview[len(formal):])):
        return ""
    return None


def caption_tail_for_translation(text: str) -> str:
    """Prepare a proven unread span, including a final incomplete clause."""
    if _reading_weight(text) < 4:
        return ""
    return _CHINESE_BEFORE_CONDITIONAL.sub("。", text)


def preview_source(text: str, *, complete_chinese_clause: bool = False, after: str = "") -> str:
    """Return the first readable, punctuated source clause."""
    source = _clean_source(text)
    begin = _caption_prefix_end(source, _clean_source(after)) if after else 0
    if begin is None:
        return ""
    probe = source if complete_chinese_clause else source[:begin + 120]
    boundaries = list(_BREAK.finditer(probe, begin))
    if complete_chinese_clause:
        boundaries.extend(_CHINESE_DISCOURSE_BOUNDARY.finditer(probe, begin))
        boundaries.sort(key=lambda part: part.start())
    for match in boundaries:
        if match.start() < begin:
            continue
        clause = _clean_source(source[begin:match.start()])
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
        if weight > 42 and not (complete_chinese_clause and _IDEOGRAPHS.search(clause)):
            break
        if complete_chinese_clause and _IDEOGRAPHS.search(clause):
            parts = _CHINESE_CLAUSE_BOUNDARY.split(clause)
            last = parts[-1].strip()
            if (
                (len(parts) > 1 and _reading_weight(last) < 4)
                or _CHINESE_DEPENDENT_LEAD.match(last)
                or _CHINESE_OPEN_TOPIC.search(last)
                or _CHINESE_BARE_PROCEDURE.fullmatch(last)
            ):
                continue
        if weight >= (8 if punctuation or after else 12) and not (
            _OPEN_ENGLISH_CLAUSE.search(clause) or _OPEN_ENGLISH_QUANTITY.search(clause)
        ):
            return source[:match.end()]
    return ""


@dataclass(frozen=True)
class Preview:
    source: str
    after_sentence_id: str
    target: str
    base_source: str = ""
    base_translation: str = ""

    @property
    def untranslated_source(self) -> str:
        return (caption_source_remainder(self.source, self.base_source) or "") if self.base_source else self.source

    def combined_translation(self, translated: str) -> str:
        return " ".join(part for part in (self.base_translation, translated) if part)


class CaptionPreview:
    """At most one in-flight request. Formal work can cancel it immediately."""

    def __init__(
        self,
        translate: Callable[[str, str], Awaitable[str]],
        publish: Callable[[Preview, str], Awaitable[bool | None]],
        idle: Callable[[], bool],
        *,
        complete_chinese_clause: bool = False,
    ) -> None:
        self.translate = translate
        self.publish = publish
        self.idle = idle
        self._complete_chinese_clause = complete_chinese_clause
        self._latest: Preview | None = None
        self._offered: Preview | None = None
        self._prepared: tuple[Preview, str] | None = None
        self._published_after: str | None = None
        self._published: list[tuple[str, str]] = []
        self._observation: tuple[int, int, int] | None = None
        self._following = ""
        self._confirmed = False
        self._task: asyncio.Task | None = None
        self._timeout_anchor: str | None = None
        self._timeouts: dict[Preview, tuple[int, tuple[int, int, int] | None]] = {}

    def offer(self, text: str, after_sentence_id: str, target: str, *, observation: tuple[int, int, int]) -> None:
        published = self._published_after == after_sentence_id
        if published and not self._complete_chinese_clause:
            return
        cleaned = _clean_source(text)
        base, base_translation = self._published[-1] if published else ("", "")
        source = preview_source(cleaned, complete_chinese_clause=self._complete_chinese_clause, after=base)
        if self._complete_chinese_clause and not base:
            condition = _CHINESE_TIME_CONDITION.match(cleaned)
            if condition:
                prefix = cleaned[:condition.end()]
                if ((not source and not _CHINESE_PROVISIONAL_END.search(cleaned))
                        or (self._latest and self._latest.source == prefix)):
                    source = prefix
        has_boundary = bool(source)
        if not source and self._complete_chinese_clause and _CHINESE_PROVISIONAL_END.search(cleaned):
            unread = caption_source_remainder(cleaned, base) if base else cleaned
            if unread and 8 <= _reading_weight(unread) <= 42:
                # This may be the end of a claim or the start of a longer
                # phrase. Prepare MT, then wait for independently decoded
                # punctuation or the start of a recognizably new clause.
                source = cleaned
        if not source:
            self.cancel()
            return
        preview = Preview(source, after_sentence_id, target, base, base_translation)
        if observation != self._observation:
            following = cleaned[len(source):].rstrip("。！？.!? ")
            previous = self._observation
            self._confirmed = False
            prior = self._latest
            same_words = (
                self._complete_chinese_clause and prior is not None and prior.target == target
                and prior.after_sentence_id == after_sentence_id and has_boundary
                and caption_source_remainder(source, prior.source) == ""
                and _reading_weight(following.lstrip(_SOFT_CLAUSE_MARKS + " ")) >= 2
            )
            if previous is not None and (preview == prior or same_words):
                same_window = observation[:2] == previous[:2] and observation[2] > previous[2]
                # A rollover carries forward the old source. Count it only
                # when the next window genuinely adds words beyond the same
                # clause and lookahead observed before the rollover.
                next_window = (
                    self._complete_chinese_clause
                    and preview == prior
                    and observation[:2] == (previous[0], previous[1] + 1)
                    and bool(self._following) and following.startswith(self._following)
                    and _reading_weight(following[len(self._following):]) >= 4
                )
                self._confirmed = has_boundary and (same_window or next_window)
            self._observation = observation
            self._following = following
        elif preview != self._latest:
            self._confirmed = False
        self._latest = preview
        prepared = self._prepared
        reusable = prepared is not None and (
            prepared[0] == preview or (
                self._confirmed and source[-1] in _CLAUSE_MARKS
                and caption_source_remainder(source, prepared[0].source) == ""
                and replace(prepared[0], source=source) == preview
            )
        )
        # Work on the first independently decoded clause while waiting for the
        # next decode. The translation is private until both decodes agree.
        prefetch = self._complete_chinese_clause and (
            source[-1] in _CLAUSE_MARKS
            or bool(_IDEOGRAPHS.fullmatch(source[-1]))
        )
        if self._timeout_anchor != after_sentence_id:
            self._timeouts.clear()
            self._timeout_anchor = after_sentence_id
        failures, failed_at = self._timeouts.get(preview, (0, None))
        if failures and (failures >= 2 or observation == failed_at or not self._confirmed):
            return
        if (
            (not self._confirmed and (not prefetch or reusable))
            or (preview == self._offered and not reusable)
            or (self._task is not None and not self._task.done())
            or not self.idle()
        ):
            return
        self._offered = preview
        translated = prepared[1] if reusable else ""
        # Keep the completed MT available until the preview is delivered. A
        # formal source event in the same decode can otherwise take it first.
        self._prepared = (preview, translated) if reusable else None
        self._task = asyncio.create_task(self._run(preview, translated))

    async def _run(self, preview: Preview, translated: str = "") -> None:
        try:
            if not self.idle():
                self._offered = None
                return
            if not translated:
                translated = await asyncio.wait_for(
                    self.translate(preview.untranslated_source, preview.target), timeout=2.5,
                )
            latest = self._latest
            if not translated or _reading_weight(translated) < 8 or latest is None or not self.idle():
                return
            if (
                latest.after_sentence_id != preview.after_sentence_id
                or latest.target != preview.target
                or (latest.source != preview.source and (
                    not self._confirmed or caption_source_remainder(latest.source, preview.source) != ""
                    or replace(preview, source=latest.source) != latest
                ))
            ):
                return
            preview = latest
            if not self._confirmed:
                self._prepared = (preview, translated)
                return
            combined = preview.combined_translation(translated)
            if await self.publish(preview, combined) is False:
                self._offered = None
                return
            self._prepared = None
            if self._published_after != preview.after_sentence_id:
                self._published.clear()
            self._published_after = preview.after_sentence_id
            self._published.append((preview.source, combined))
        except TimeoutError:
            if self._timeout_anchor == preview.after_sentence_id:
                failures, _ = self._timeouts.get(preview, (0, None))
                self._timeouts[preview] = (failures + 1, self._observation)
                self._offered = None
        except Exception:
            # Streaming captions are optional. The formal translation worker
            # owns errors and retries for completed units.
            pass

    def prepared_for_commit(self, source: str, after_sentence_id: str) -> tuple[Preview, str] | None:
        # A final source span can confirm the outstanding visual continuation.
        # Its MT was already prepared and never enters the formal speech queue.
        if not self._complete_chinese_clause or self._prepared is None:
            return None
        preview, translated = self._prepared
        if preview.after_sentence_id != after_sentence_id or (not self._confirmed and not preview.base_source):
            return None
        formal = _clean_source(source)
        end = _caption_prefix_end(formal, preview.source)
        if end is not None:
            return replace(preview, source=formal[:end]), preview.combined_translation(translated)
        return None

    def committed_caption_prefix(self, source: str, anchor: str) -> tuple[str, str] | None:
        if self._complete_chinese_clause and self._published_after == anchor:
            for prefix, translation in reversed(self._published):
                if committed_caption_remainder(source, prefix) is not None:
                    return prefix, translation
        return None

    def yield_inference(self) -> None:
        self._offered = None
        if self._task is not None and not self._task.done():
            self._task.cancel()

    def cancel(self) -> None:
        self.yield_inference()
        self._latest = None
        self._prepared = None
        self._observation = None
        self._following = ""
        self._confirmed = False

    async def close(self) -> None:
        self.cancel()
        if self._task is not None:
            with suppress(asyncio.CancelledError):
                await self._task
