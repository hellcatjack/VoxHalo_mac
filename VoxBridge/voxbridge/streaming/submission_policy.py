"""Bounded, local-only evidence for conservative Qwen submission decisions.

These helpers propose text boundaries; they never commit subtitles or bypass the
application's rollback, revision, or TTS confirmation guards.
"""
from dataclasses import dataclass
from typing import Callable


def _compact(text: str) -> str:
    return "".join(text.split())


def _processed_prefix_end(text: str, prefix: str) -> int | None:
    """Align previously accepted words across clause-punctuation revisions.

    This tolerance is ONLY for the processed prefix, never for pending boundary
    agreement. Decimal points and punctuation touching digits remain significant.
    """
    def significant(value):
        for index, char in enumerate(value):
            if char.isspace():
                continue
            adjacent_digit = ((index > 0 and value[index - 1].isdigit())
                              or (index + 1 < len(value) and value[index + 1].isdigit()))
            if char in "，。！？；：,!?;:" and not adjacent_digit:
                continue
            yield char, index
    wanted = "".join(char for char, _ in significant(prefix))
    source = list(significant(text))
    if not "".join(char for char, _ in source).startswith(wanted):
        return None
    if not wanted:
        return 0
    return source[len(wanted)][1] if len(source) > len(wanted) else len(text)


class PendingTextClock:
    """First-seen ages for bounded pending text, not the whole transcript."""

    def __init__(self, max_chars: int = 4096):
        self.max_chars = max(1, int(max_chars))
        self.text = ""
        self._times: list[float] = []

    def update(self, text: str, now: float) -> None:
        text = _compact(text)[:self.max_chars]
        old = self.text
        times = [now] * len(text)
        if text and old.endswith(text):
            times = self._times[len(old) - len(text):]
        elif old and text:
            prefix = 0
            limit = min(len(old), len(text))
            while prefix < limit and old[prefix] == text[prefix]:
                prefix += 1
            suffix = 0
            while suffix < limit - prefix and old[-1-suffix] == text[-1-suffix]:
                suffix += 1
            # Keep linear anchors for growth/local edits; incidental single
            # letters in a wholesale rewrite are not evidence of content age.
            if prefix >= 2 or prefix == limit or suffix >= 4:
                times[:prefix] = self._times[:prefix]
                if suffix:
                    times[-suffix:] = self._times[-suffix:]
        self.text, self._times = text, times

    def consume_prefix(self, text: str) -> None:
        prefix = _compact(text)
        if self.text.startswith(prefix):
            self.text = self.text[len(prefix):]
            self._times = self._times[len(prefix):]

    def age(self, now: float) -> float:
        return max(0.0, now - min(self._times)) if self._times else 0.0


class StableCandidate:
    """Agreement on both original words and their exact punctuation boundary."""

    def __init__(self):
        self.text = ""
        self.key: tuple[int, int] | None = None
        self.hits = 0
        self._since = 0.0

    def observe(self, text: str, key: tuple[int, int] | None, now: float) -> None:
        if key is None:
            return
        if text != self.text or self.key is None or key[0] != self.key[0]:
            self.text, self.hits, self._since = text, 1, now
        elif key != self.key:
            self.hits += 1
        self.key = key

    def age(self, now: float) -> float:
        return max(0.0, now - self._since) if self.hits else 0.0


class DecodeObservation:
    """SDK chunk advancement, separate from calls and observed hypotheses."""

    def __init__(self):
        self.key: tuple[int, int] | None = None
        self.actual_decodes = 0
        self.hypotheses = 0

    def observe(self, segment_id: int, chunk_id: object, text: str, now: float) -> bool:
        if type(chunk_id) is not int or chunk_id <= 0:
            return False
        previous = self.key[1] if self.key and self.key[0] == segment_id else 0
        if chunk_id <= previous:
            return False
        self.actual_decodes += chunk_id - previous
        self.hypotheses += 1
        self.key = (segment_id, chunk_id)
        return True


@dataclass(frozen=True)
class ClauseDecision:
    units: list[str]
    tail: str
    pending_age_sec: float
    used_small_target: bool
    prefix_matched: bool


class PendingClausePolicy:
    """Search smaller punctuation-delimited units only in the pending suffix."""

    def __init__(self, target: int = 32, aged_target: int = 24, budget_sec: float = 8.0):
        self.target = max(1, target)
        self.aged_target = max(1, min(aged_target, self.target))
        self.budget_sec = max(0.0, budget_sec)
        self.clock = PendingTextClock()
        self._proposed: list[str] = []

    def reset(self, *, keep_pending_age: bool = False) -> None:
        self._proposed = []
        if not keep_pending_age:
            self.clock.update("", 0.0)

    def split(self, text: str, locked_units: list[str], *, now: float,
              splitter: Callable[[str, int], tuple[list[str], str]]) -> ClauseDecision:
        end = _processed_prefix_end(text, "".join(locked_units))
        if end is None:
            self.clock.update("", now)
            self._proposed = []
            units, tail = splitter(text, self.target)
            return ClauseDecision(units, tail, 0.0, False, False)
        # Map the compact prefix back onto original source positions. Do not
        # reinterpret already submitted boundaries when the budget expires.
        pending = text[end:]
        self.clock.update(pending, now)
        age = self.clock.age(now)
        small = bool(pending.strip()) and age >= self.budget_sec
        frozen = self._proposed
        if (frozen[:len(locked_units)] != locked_units
                or not _compact(text).startswith(_compact("".join(frozen)))):
            frozen = []
        retained = frozen[len(locked_units):] if frozen else []
        retained_chars = len(_compact("".join(retained)))
        retained_end, seen = 0, 0
        while seen < retained_chars:
            if not pending[retained_end].isspace():
                seen += 1
            retained_end += 1
        units, tail = splitter(pending[retained_end:], self.aged_target if small else self.target)
        result = list(locked_units) + retained + units
        self._proposed = result if small else list(locked_units) + retained
        return ClauseDecision(result, tail, age, small, True)
