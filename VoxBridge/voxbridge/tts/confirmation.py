"""Conservative English speech release evidence; no inference or audio work.

These are risk hints, not a grammar or named-entity recognizer. A final source
decode remains the fallback whenever streaming evidence is insufficient.
"""
import re

from voxbridge.streaming.submission_policy import StableCandidate


class SpeechConfirmation:
    def __init__(self):
        self._candidates: dict[int, StableCandidate] = {}

    def reset(self) -> None:
        self._candidates.clear()

    def observe(self, texts: list[str], key: tuple[int, int] | None) -> None:
        # Bound work to a live ASR segment. Repeated callbacks for the same
        # decoder result must never count as additional agreement.
        if key is None:
            self.reset()
            return
        texts = texts[:64]
        for index in list(self._candidates):
            if index >= len(texts):
                del self._candidates[index]
        for index, text in enumerate(texts):
            self._candidates.setdefault(index, StableCandidate()).observe(text, key, 0.0)

    def decision(self, text: str) -> bool | None:
        """None: wait; True: normal/urgent release; False: normal window only."""
        matches = [entry for entry in self._candidates.values() if entry.text == text]
        hits = min((entry.hits for entry in matches), default=0)
        stripped = text.strip().rstrip('"”’\')]}')
        if not stripped.endswith(('.', '?', '!')) or stripped.endswith('...'):
            return None
        if text.count('"') % 2 or text.count('“') != text.count('”'):
            return None
        if any(text.count(left) != text.count(right) for left, right in [('(', ')'), ('[', ']')]):
            return None
        words = re.findall(r"[A-Za-z]+(?:['’][A-Za-z]+)?", text)
        if not words or words[-1].lower() in {
            'and', 'or', 'but', 'because', 'although', 'if', 'when', 'while',
            'to', 'of', 'for', 'with', 'without', 'the', 'a', 'an', 'is', 'are', 'was', 'were',
        }:
            return None
        if words[0].lower() in {'if', 'unless', 'although', 'because', 'when', 'while'} and ',' not in text:
            return None
        sensitive = bool(re.search(r'\d', text)) or any(
            word.lower() in {'no', 'not', 'cannot', 'never', 'neither', 'nor', 'without', 'nobody', 'nothing', 'nowhere'}
            or word.lower().endswith(("n't", 'n’t')) for word in words)
        # Internal capitalization is a conservative proper-name hint; "I" is
        # exempt. It changes release evidence, never the translated words.
        sensitive |= any(word[0].isupper() and word != 'I' for word in words[1:])
        if hits < (3 if sensitive else 2):
            return None
        return not sensitive
