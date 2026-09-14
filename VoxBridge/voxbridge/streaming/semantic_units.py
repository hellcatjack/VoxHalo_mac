"""Conservative repairs for ASR punctuation inside dependent phrases."""
from __future__ import annotations

import re


def open_conditional(text: str) -> bool:
    bare = text.strip(' \"“')
    return bool(re.match(r"^(?:假如|如果|倘若|若是)", bare)
                and not re.search(r"那么|那就|就会|就要|就能|则|其实|因此|所以", bare)
                and len(bare) < 120)


def dependent_phrase(text: str) -> bool:
    if open_conditional(text):
        return True
    if re.search(r"[\u3400-\u9fff]", text) or re.search(r"[!?][\"'”’]*$", text):
        return False
    words = re.findall(r"[a-z]+(?:'[a-z]+)?", text.lower())
    if not words:
        return False
    if words[-1] in {'the', 'a', 'an', 'your', 'its', 'their', 'our', 'my', 'every'}:
        return True
    if len(words) <= 4 and words[-1] in {'of', 'for', 'to', 'with', 'from', 'by', 'into', 'and', 'or'}:
        # Object pronouns and stranded prepositions can end real sentences.
        return True
    if len(words) >= 2 and words[-2] in {'i', 'he', 'she', 'we', 'you', 'they', 'it'}:
        if words[-1] in {'shall', 'will', 'could', 'would', 'should', 'must', 'also'}:
            return True
    return bool(re.fullmatch(r"(?:and |but )?(?:the lord god|the lord)|and again", ' '.join(words)))


def _join(left: str, right: str) -> str:
    left = re.sub(r'[。.!?！？][\"”]*$', '', left).rstrip()
    return left + ('' if re.search(r'[\u3400-\u9fff]$', left) else ' ') + right.lstrip()


def repair_semantic_units(sentences: list[str], tail: str) -> tuple[list[str], str]:
    units: list[str] = []
    pending = ''
    for sentence in sentences:
        current = _join(pending, sentence) if pending else sentence
        pending = ''
        relative = re.match(r'^(?:that|which)\s+(?:he|she|they|we|you|it|the)\b', current, re.I)
        if relative and units:
            current = _join(units.pop(), current)
        if dependent_phrase(current):
            pending = re.sub(r'[。.!?！？][\"”]*$', '', current).rstrip()
        else:
            units.append(current)
    if pending:
        tail = _join(pending, tail) if tail else pending
    return units, tail
