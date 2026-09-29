"""Conservative English utterance boundaries for early speech confirmation.

This is deliberately a small positive grammar for early comma-clause release,
not a general English parser. Submission retains its existing segmentation;
unsupported clauses wait for the normal final source path before speech.
No source text is discarded or rewritten here.
"""
from dataclasses import dataclass
import re

from .semantic_units import dependent_phrase, open_english_complement

_WORDS = re.compile(r"[-+]?\d+(?:[.,:/-]\d+)*|[^\W\d_]+(?:['’][^\W\d_]+)?")
_CLOSERS = '\"”’\')]} '
_OPEN_END = {'and', 'or', 'but', 'because', 'although', 'if', 'when', 'while',
             'to', 'of', 'for', 'with', 'without', 'the', 'a', 'an',
             'is', 'are', 'was', 'were'}
_OPEN_CLAUSE_END = _OPEN_END | {'from', 'into', 'that', 'which', 'whose', 'than', 'between',
                              'am', 'be', 'been', 'being', 'have', 'has', 'had',
                              'can', 'could', 'will', 'would', 'should', 'must'}
_DEPENDENT_START = re.compile(r'^(?:if|unless|although|because|when|while|before|after|until|whether|since)\b', re.I)
_DISCOURSE = re.compile(r'^(?:(?:and|but|so|well|now|however|therefore|actually)[,\s]+)*', re.I)
# Only positive evidence for a new clause; unknown heads are not a reason to
# remove text. Finite auxiliaries cover most spontaneous interview speech.
_SUBJECT = r"(?:i|we|you|they|he|she|it|this|that|these|those|there|(?:the|these|those|our|their|your|my)\s+[a-z]+(?:\s+[a-z]+){0,3})"
_FINITE = r"(?:am|is|are|was|were|have|has|had|do|does|did|can|could|will|would|should|must|need|needs|work|works|worked|make|makes|made|mean|means|think|thinks|believe|believes|know|knows|want|wants|use|uses|used|help|helps|care|cares|allow|allows|require|requires|support|supports|provide|provides|became|become|becomes|went|said|say|says)\b"
_CLAUSE_HEAD = re.compile(r'^' + _SUBJECT + r"(?:\s+" + _FINITE + r"|['’](?:m|re|s|ve|ll|d)\b)", re.I)


@dataclass(frozen=True)
class EnglishBoundary:
    kind: str
    reason: str = ''


def independent_clause_start(text: str) -> bool:
    return bool(_CLAUSE_HEAD.match(_DISCOURSE.sub('', text.strip())))


def english_boundary(text: str) -> EnglishBoundary:
    core = text.strip().rstrip(_CLOSERS)
    if text.count('"') % 2 or text.count('“') != text.count('”'):
        return EnglishBoundary('open', 'quote_scope')
    if any(text.count(a) != text.count(b) for a, b in [('(', ')'), ('[', ']')]):
        return EnglishBoundary('open', 'bracket_scope')
    if dependent_phrase(text) or open_english_complement(text):
        return EnglishBoundary('open', 'semantic_dependency')
    words = [m.group().lower() for m in _WORDS.finditer(text)]
    if not any(any(char.isalpha() for char in word) for word in words):
        return EnglishBoundary('open', 'terminal_boundary')
    if not words or words[-1] in _OPEN_END:
        return EnglishBoundary('open', 'open_word_tail')
    if core.endswith('...') or not core.endswith(('.', '?', '!', ',', ';')):
        return EnglishBoundary('open', 'terminal_boundary')
    bare = _DISCOURSE.sub('', text.strip().lstrip('\"“'))
    if core.endswith((',', ';')):
        if words[-1] in _OPEN_CLAUSE_END:
            return EnglishBoundary('open', 'open_word_tail')
        if re.fullmatch(r'[-+]?\d+(?:[.,:/-]\d+)*', words[-1]):
            return EnglishBoundary('open', 'number_unit_tail')
        # An if/because/when clause needs its main clause. Quotes and lists are
        # left to sentence finalization even if a fragment contains an auxiliary.
        if _DEPENDENT_START.match(bare) or not independent_clause_start(bare):
            return EnglishBoundary('open', 'dependent_clause')
        if len(words) < 4:
            return EnglishBoundary('open', 'short_clause')
        return EnglishBoundary('clause')
    if re.match(r'^(?:if|unless|although|because|when|while)\b', bare, re.I) and ',' not in text:
        return EnglishBoundary('open', 'dependent_clause')
    return EnglishBoundary('sentence')


def content_key(text: str) -> str:
    # Preserve case, contractions and numeric separators: US/us, can't/can,
    # 1.5/15 and 1,500/1500 are not formatting-equivalent evidence.
    return '\x1f'.join(m.group().replace('’', "'") for m in _WORDS.finditer(text))


def boundary_key(text: str) -> str:
    # Whitespace and typographic apostrophes are formatting; punctuation scope,
    # decimal points and every token position remain part of boundary evidence.
    return re.sub(r'\s+', '', text.replace('’', "'")).strip()
