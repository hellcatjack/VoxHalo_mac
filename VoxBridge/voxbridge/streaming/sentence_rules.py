# coding=utf-8
# Copyright 2026 The Alibaba Qwen team.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# Extracted into reusable modules in 2026; see the repository change history.
"""Verified source-text boundaries; no model, transport or mutable session state."""
import re
import regex
from typing import Any, List, Optional, Sequence, Tuple
from voxbridge.translation.language_checks import _has_cjk, _has_latin
from .semantic_units import repair_semantic_units, open_conditional

SENTENCE_BOUNDARY_PATTERN = re.compile(
    r"[。！？!?…।॥]+[\"'”’)\]）】》」』]*|\.+[\"'”’)\]）】》」』]*(?=\s|$|[\u3400-\u9fff])"
)


SOFT_CLAUSE_BOUNDARY_PATTERN = re.compile(r"[,，;；:：][\"'”’)\]）】》」』]*")


SENTENCE_CLOSER_CHARS = "\"'”’)]）】》"


INITIALS_ABBREVIATION_PATTERN = re.compile(r"(?:\b[A-Za-z]\.){2,}$")


MIN_CJK_SENTENCE_CHARS = 10


def _split_sentences_and_tail(text: str) -> Tuple[List[str], str]:
    src = str(text or "").strip()
    if not src:
        return [], ""

    raw_sentences: List[str] = []
    last = 0
    for _, end, _ in _iter_sentence_boundaries(src, SENTENCE_BOUNDARY_PATTERN):
        seg = src[last:end].strip()
        if seg:
            raw_sentences.append(seg)
        last = end
    tail = src[last:].strip()

    sentences: List[str] = []
    carry = ""
    for seg in raw_sentences:
        cur = str(seg or "").strip()
        if not cur:
            continue
        if carry:
            cur = _join_segments([carry, cur])
            carry = ""
        if _has_cjk(cur) and len(cur) < MIN_CJK_SENTENCE_CHARS:
            carry = cur
            continue
        sentences.append(cur)

    if carry:
        tail = _join_segments([carry, tail]) if tail else carry

    return sentences, tail


def _translation_unit_size(text: str, *, cjk: bool) -> int:
    src = str(text or "")
    if cjk:
        return len(re.sub(r"\s+", "", src))
    return len(re.findall(r"[A-Za-z0-9]+(?:['’-][A-Za-z0-9]+)*", src))


def _split_long_clause_text(text: str, *, target_size: int, cjk: bool) -> Tuple[List[str], str]:
    src = str(text or "").strip()
    if not src or target_size <= 0 or _translation_unit_size(src, cjk=cjk) <= target_size:
        return [], src

    completed: List[str] = []
    start = 0
    for match in SOFT_CLAUSE_BOUNDARY_PATTERN.finditer(src):
        end = int(match.end())
        prev_char = src[int(match.start()) - 1] if int(match.start()) > 0 else ""
        next_char = src[end] if end < len(src) else ""
        if str(match.group(0) or "").startswith(",") and prev_char.isdigit() and next_char.isdigit():
            continue
        candidate = src[start:end].strip()
        if open_conditional(candidate):
            continue
        candidate_size = _translation_unit_size(candidate, cjk=cjk)
        if candidate_size < target_size:
            continue
        completed.append(candidate)
        start = end

    return completed, src[start:].strip()


def _split_translation_units_and_tail(
    text: str,
    *,
    target_cjk_chars: int = 32,
    target_latin_words: int = 24,
) -> Tuple[List[str], str]:
    """Split long stable text at clause punctuation without rotating ASR state."""
    sentences, tail = repair_semantic_units(*_split_sentences_and_tail(text))
    completed: List[str] = []

    for sentence in sentences:
        use_cjk = _has_cjk(sentence)
        target = int(target_cjk_chars if use_cjk else target_latin_words)
        clauses, remainder = _split_long_clause_text(
            sentence,
            target_size=target,
            cjk=use_cjk,
        )
        completed.extend(clauses)
        if remainder:
            completed.append(remainder)

    if tail:
        use_cjk = _has_cjk(tail)
        target = int(target_cjk_chars if use_cjk else target_latin_words)
        clauses, tail = _split_long_clause_text(
            tail,
            target_size=target,
            cjk=use_cjk,
        )
        completed.extend(clauses)

    return completed, tail


def _text_ends_with_sentence_terminator(text: str) -> bool:
    src = str(text or "").strip()
    if not src:
        return False
    src = re.sub(r"[\"'”’)\]）】》」』\s]+$", "", src).strip()
    return bool(re.search(r"[。！？!?….।॥]$", src))


def _is_abbreviation_period_boundary(text: str, start: int, end: int) -> bool:
    src = str(text or "")
    if not src:
        return False
    if start < 0 or end <= start or end > len(src):
        return False
    token = src[start:end]
    if "." not in token:
        return False

    trimmed_end = int(end)
    while trimmed_end > start and src[trimmed_end - 1] in SENTENCE_CLOSER_CHARS:
        trimmed_end -= 1
    if trimmed_end <= start or src[trimmed_end - 1] != ".":
        return False

    suffix = src[end:].lstrip()
    if not suffix:
        return False

    prev_char = src[trimmed_end - 2] if trimmed_end >= 2 else ""
    next_char = suffix[0] if suffix else ""
    if prev_char.isdigit() and next_char.isdigit():
        return True

    left_tail = src[max(0, trimmed_end - 40):trimmed_end]
    if INITIALS_ABBREVIATION_PATTERN.search(left_tail):
        return True

    token_match = re.search(r"([A-Za-z]+)$", src[: max(0, trimmed_end - 1)])
    token = token_match.group(1) if token_match else ""
    if token and len(token) <= 2 and token[:1].isupper():
        return True
    return False


def _iter_sentence_boundaries(text: str, boundary_pattern: Any):
    src = str(text or "")
    if not src:
        return
    for match in boundary_pattern.finditer(src):
        start = int(match.start())
        end = int(match.end())
        token = str(match.group(0) or "")
        if boundary_pattern is SENTENCE_BOUNDARY_PATTERN and _is_abbreviation_period_boundary(src, start, end):
            continue
        yield start, end, token


def _find_first_boundary_after(
    text: str,
    start_chars: int,
    boundary_pattern: Any,
) -> Optional[Tuple[int, str]]:
    src = str(text or "")
    if not src:
        return None
    start = max(0, min(len(src), int(start_chars)))
    latest: Optional[Tuple[int, str]] = None
    for _, end, token in _iter_sentence_boundaries(src, boundary_pattern):
        if end <= start:
            continue
        latest = (int(end), str(token or ""))
    return latest


def _resolve_boundary_for_anchor(
    text: str,
    anchor_end_chars: int,
    boundary_pattern: Any,
) -> Optional[Tuple[int, str]]:
    src = str(text or "")
    if not src:
        return None
    target = max(1, min(len(src), int(anchor_end_chars)))
    before: Optional[Tuple[int, str]] = None
    for _, end, token in _iter_sentence_boundaries(src, boundary_pattern):
        if end >= target:
            return end, token
        before = (end, token)
    return before


def _split_text_at_boundary(text: str, boundary_end_chars: int) -> Tuple[str, str]:
    src = str(text or "")
    if not src:
        return "", ""
    cut = max(0, min(len(src), int(boundary_end_chars)))
    if cut <= 0:
        return "", src.strip()
    left = src[:cut].strip()
    right = src[cut:].strip()
    return left, right


def _normalize_sentence_for_duplicate_compare(text: str) -> str:
    src = str(text or "").strip()
    if not src:
        return ""
    return re.sub(r"\s+", " ", src)


def _english_word_count(text: str) -> int:
    src = str(text or "")
    if not src:
        return 0
    return len(re.findall(r"[A-Za-z]+(?:['-][A-Za-z]+)?|\d+", src))


def _is_short_english_sentence_for_early_commit(
    text: str,
    *,
    min_words: int = 6,
    min_chars: int = 32,
) -> bool:
    src = str(text or "").strip()
    if not src or _has_cjk(src) or not _has_latin(src):
        return False
    words = _english_word_count(src)
    chars = len(src)
    return words < int(max(1, min_words)) and chars < int(max(1, min_chars))


def _is_short_english_slice_fragment(
    text: str,
    *,
    min_words: int = 6,
    min_chars: int = 32,
) -> bool:
    src = str(text or "").strip()
    if not src or _has_cjk(src) or not _has_latin(src):
        return False
    # Periods in very short English partials are often ASR boundary guesses
    # rather than reliable sentence endings. Keep questions and exclamations
    # eligible because they are stronger end-of-sentence signals.
    if not re.search(r"\.[\"'”’)\]）】》」』]*$", src):
        return False
    return _is_short_english_sentence_for_early_commit(
        src,
        min_words=int(min_words),
        min_chars=int(min_chars),
    )


def _strip_short_english_fragment_period(
    text: str,
    *,
    min_words: int = 6,
    min_chars: int = 32,
) -> str:
    src = str(text or "").strip()
    if not _is_short_english_slice_fragment(
        src,
        min_words=int(min_words),
        min_chars=int(min_chars),
    ):
        return src
    return re.sub(r"\.[\"'”’)\]）】》」』]*$", "", src).strip()


def _qwen_cjk_endpoint_defer_reason(text: str, previous_text: str = "") -> str:
    """Conservative endpoint guard, not a general Chinese sentence parser.

    An acoustic pause cannot complete a dependent ending or establish a newly
    decoded short suffix. Keep the existing decoder context in those cases;
    sustained silence and explicit stop still provide bounded finalization.
    """
    if not _has_cjk(text):
        return ""
    bare = str(text or "").strip().rstrip("。！？!?…，,；;：: \"'”’）)]】》")
    dependent = (
        r"(?<![顺服遵听随])从|(?<![既以过来向交往])往|(?<![方朝走倾导意志])向|"
        r"把|(?<!棉)被|(?<![谦退忍礼])让|(?<![参给授])与|(?<![普波触涉不])及|"
        r"因为|由于|为了|包括|例如|比如|以及|如果|虽然|无论|不管|"
        r"总共有|需要|必须|能够|想要|将要|取决于|关于|对于|至于|"
        r"(?:让|使)[^，。！？!?]{1,12}来"
    )
    if re.search(rf"(?:{dependent})$", bare):
        return "dependent_ending"
    previous = re.sub(r"[\W_]+", "", str(previous_text or ""))
    current = re.sub(r"[\W_]+", "", str(text or ""))
    if previous and current.startswith(previous) and 0 < len(current) - len(previous) <= 4:
        return "new_tail_suffix"
    return ""


def _join_segments(segments: List[str]) -> str:
    out = ""
    for seg in segments:
        cur = str(seg or "").strip()
        if not cur:
            continue
        if not out:
            out = cur
            continue
        need_space = bool(regex.search(r"[\p{Latin}\p{Devanagari}0-9]\p{M}*$", out)) and bool(regex.match(r"[\p{Latin}\p{Devanagari}0-9]", cur[:1]))
        out = f"{out} {cur}" if need_space else f"{out}{cur}"
    return out


def _join_recent_segments(segments: List[str], *, max_segments: int) -> str:
    """Join a bounded compatibility snapshot without trimming canonical state."""

    limit = max(1, int(max_segments))
    return _join_segments(list(segments)[-limit:])
