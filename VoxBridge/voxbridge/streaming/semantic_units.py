"""Conservative repairs for ASR punctuation inside dependent phrases."""
from __future__ import annotations

import re
from collections.abc import Iterable


_CARRIED_DISCOURSE_FRAGMENT = re.compile(
    r"(?:(?:yeah|well|so|okay)(?:\s*,\s*|\s+)){1,4}"
    r"(?:first(?:\s+of\s+all)?|secondly)\s*\.",
    re.I,
)


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
    # A quoted word can be a complete object ("The operator is 'and'.").
    if re.search(r'''["'“‘][a-z]+["'”’][.,;:]?$''', text.strip(), re.I):
        return False
    if words[-1] in {'and', 'or', 'but', 'because', 'although', 'if', 'when', 'while'}:
        return True
    if words[-1] in {'the', 'a', 'an', 'your', 'its', 'their', 'our', 'my', 'every'}:
        return True
    # "any" can stand alone ("Do you have any?"). Only hold declarative
    # quantifier tails with a verb that still needs its object in this context.
    if re.search(r"\b(?:need|needs|require|requires)\s+(?:any|some|more|new)$", ' '.join(words)):
        return True
    if re.search(r"\b(?:to be|will be|would be|should be|could be|must be|have been|has been)$", ' '.join(words)):
        return True
    if len(words) <= 4 and words[-1] in {'of', 'for', 'to', 'with', 'from', 'by', 'into', 'and', 'or'}:
        # Object pronouns and stranded prepositions can end real sentences.
        return True
    if len(words) >= 2 and words[-2] in {'i', 'he', 'she', 'we', 'you', 'they', 'it'}:
        if words[-1] in {'shall', 'will', 'could', 'would', 'should', 'must', 'also'}:
            return True
    return bool(re.fullmatch(r"(?:and |but )?(?:the lord god|the lord)|and again", ' '.join(words)))


def open_english_complement(text: str) -> bool:
    """Missing complements at soft boundaries, not a general grammar parser."""
    if re.search(r"[\u3400-\u9fff]", text):
        return False
    words = re.findall(r"[a-z]+(?:['’][a-z]+)?", text.lower())
    if not words:
        return False
    # These verbs/nouns need the following prepositional object. Do not treat
    # ordinary stranded prepositions ("That's what it is for") this way.
    return bool(re.search(
        r"\b(?:confidence in(?: in)?|(?:believe|believes|believed) in|"
        r"(?:depend|depends|depending) on|(?:look|looking) forward to|"
        r"(?:empathetic|sympathetic) to|(?:asking|asked) to be)$",
        ' '.join(words)))


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
        # Qwen sometimes restarts the adjective before its complement. Only
        # merge this adjacent dependency; preserve independent repetitions.
        if units and re.match(r'^(?:empathetic|sympathetic)\s+to\b', current, re.I):
            word = current.split()[0]
            if re.search(r'\b' + re.escape(word) + r'[.!]?$', units[-1], re.I):
                current = _join(units.pop(), current)
        if dependent_phrase(current) or open_english_complement(current):
            pending = re.sub(r'[。.!?！？][\"”]*$', '', current).rstrip()
        else:
            units.append(current)
    if pending:
        tail = _join(pending, tail) if tail else pending
    return units, tail


def repair_carried_discourse_units(
    sentences: list[str],
    tail: str,
    *,
    carried_unit_indexes: Iterable[int],
    unregistered_start: int = 0,
) -> tuple[list[str], str]:
    """Assemble an explicitly carried discourse fragment before registration.

    The caller supplies occurrence indexes proved to be wholly inside the
    carried prefix; text equality alone cannot identify those occurrences.
    Registered units and fresh short sentences keep their existing boundaries.
    This repair neither observes a decoder callback nor grants speech evidence.
    It retains every word, including a genuinely repeated phrase in fresh raw
    text, and should not run during final reconciliation of a stopped source.
    """
    carried = frozenset(carried_unit_indexes)
    first_unregistered = max(0, int(unregistered_start))
    units: list[str] = []
    index = 0

    def carried_fragment(position: int) -> bool:
        return bool(
            position >= first_unregistered
            and position in carried
            and _CARRIED_DISCOURSE_FRAGMENT.fullmatch(sentences[position].strip())
        )

    while index < len(sentences):
        if not carried_fragment(index):
            units.append(sentences[index])
            index += 1
            continue

        run_start = index
        pending = sentences[index]
        index += 1
        while index < len(sentences) and carried_fragment(index):
            pending = _join(pending, sentences[index])
            index += 1

        if index < len(sentences) and index in carried:
            # A different carried sentence still separates the fragment from
            # fresh speech. Preserve order and its boundaries rather than move
            # the fragment past that sentence or silently fold old content.
            units.extend(sentences[run_start:index])
            continue

        if index == len(sentences):
            # No completed fresh neighbour exists yet. Keep the complete
            # fragment in the tail instead of creating an unconfirmable head.
            tail = _join(pending, tail) if tail else re.sub(r'\.$', '', pending).rstrip()
            break

        current = _join(pending, sentences[index])
        index += 1
        if dependent_phrase(current) or open_english_complement(current):
            # Existing semantic safeguards also apply after assembly. Continue
            # only through adjacent fresh units; never pull another carry in.
            while index < len(sentences) and index not in carried:
                current = _join(current, sentences[index])
                index += 1
                if not dependent_phrase(current) and not open_english_complement(current):
                    break
            if dependent_phrase(current) or open_english_complement(current):
                if index < len(sentences):
                    units.extend(sentences[run_start:index])
                    continue
                tail = _join(current, tail) if tail else re.sub(r'\.$', '', current).rstrip()
                break
        units.append(current)

    return units, tail
