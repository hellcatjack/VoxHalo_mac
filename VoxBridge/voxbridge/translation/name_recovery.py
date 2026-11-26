"""Source-anchored pinyin hints for partially translated names in English."""

import re

import regex

from voxbridge.streaming.church_terms import matched_terms


_HAN = regex.compile(r"\p{Han}+")
_MIXED_NAME = regex.compile(r"(?<![\p{L}\p{N}])([A-Z][a-z]{1,11})(\p{Han}{1,6})(?!\p{Han})")
_NAMED_ENTITY = regex.compile(
    r"\b(?:named|called|(?:city|town|village|province) of|Mr\.|Mrs\.|Ms\.|Dr\.)\s+"
    r"(\p{Han}{1,6})(?!\p{Han})", regex.IGNORECASE,
)


def english_name_spellings(source: str, rejected: str, target: str) -> tuple[tuple[str, str], ...]:
    """Suggest spellings for identifiable names, leaving all source text intact."""
    fragments = [(prefix.lower(), tail) for prefix, tail in _MIXED_NAME.findall(rejected)]
    fragments.extend(("", tail) for tail in _NAMED_ENTITY.findall(rejected))
    if not fragments or len(re.findall(r"[A-Za-z]+", rejected)) < 4:
        return ()

    from pypinyin import lazy_pinyin

    glossary = [term for term, _ in matched_terms(source, target)]
    source_syllables = [(han, lazy_pinyin(han, errors=list)) for han in _HAN.findall(source)]
    names = {}
    for prefix, tail in fragments:
        if not prefix:
            matches = {tail} if tail in source else set()
        else:
            # Example: Sh格拉 is a partial romanization of 史葛拉. The
            # recognizer and translator can choose different Han homophones.
            tail_syllables = lazy_pinyin(tail)
            matches = set()
            for han, syllables in source_syllables:
                for end in range(1, len(han) - len(tail) + 1):
                    if syllables[end:end + len(tail)] != tail_syllables:
                        continue
                    for start in range(max(0, end - 4), end):
                        before = "".join(syllables[start:end - 1])
                        if len(before) < len(prefix) and (before + syllables[end - 1]).startswith(prefix):
                            matches.add(han[start:end + len(tail)])
        if len(matches) != 1:
            continue
        name = matches.pop()
        if any(name in known or known in name for known in glossary):
            continue  # The strict prompt already contains the glossary spelling.
        romanized = "".join(lazy_pinyin(name))
        if re.fullmatch(r"[a-z]+", romanized):
            names[name] = romanized.capitalize()
    return tuple(names.items())
