"""Stable-prefix support for Chinese recognizers that do not emit punctuation."""

import re

_CJK = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")


def split_unpunctuated_chinese(text: str, *, target_chars: int) -> tuple[list[str], str]:
    if target_chars <= 0:
        return [], text
    units, start, count = [], 0, 0
    for match in _CJK.finditer(text):
        count += 1
        if count >= target_chars and match.end() < len(text):
            units.append(text[start:match.end()])
            start, count = match.end(), 0
    return units, text[start:]


class StablePrefixGate:
    def __init__(self, *, stable_sec: float, stable_hits: int):
        self.stable_sec = stable_sec
        self.stable_hits = stable_hits
        self._seen: dict[int, tuple[str, float, int, int]] = {}

    def clear(self) -> None:
        self._seen.clear()

    def ready_end(self, units: list[str], start: int, end: int, *, seq: int, now: float) -> int:
        # Calls within the same decode cannot manufacture stability observations.
        for index in range(start, len(units)):
            text = units[index]
            old = self._seen.get(index)
            if old is None or old[0] != text:
                self._seen[index] = (text, now, 1, seq)
            elif old[3] != seq:
                self._seen[index] = (text, old[1], old[2] + 1, seq)
        self._seen = {i: value for i, value in self._seen.items() if start <= i < len(units)}
        for index in range(start, end):
            _, since, hits, _ = self._seen[index]
            if hits < self.stable_hits or now - since < self.stable_sec:
                return index
        return end
