"""Lossless, bounded text slices for incremental speech synthesis."""
import re


_CHINESE_MAX_CHARS = 120
_CLOSERS = r'[”’」』）》】\]"\)\s]*'
# An ASCII period following Han text is also a sentence end. Do not split
# decimal numbers or Latin abbreviations embedded in a Chinese translation.
_CHINESE_SENTENCE_END = re.compile(r'(?:[。！？!?]+|(?<=[\u3400-\u9fff])\.(?![.\d]))' + _CLOSERS)
_CHINESE_CLAUSE_END = re.compile(r'(?:[，；、;]|(?<!\d)[,:：](?!\d))' + _CLOSERS)
_LATIN_OR_NUMBER = re.compile(r'[A-Za-z0-9]+(?:[.:：,\-\u2019\x27][A-Za-z0-9]+)*')


def _bounded_chinese_sentence(text: str) -> list[str]:
    result = []
    while len(text) > _CHINESE_MAX_CHARS:
        # The text limit is soft for a sentence's closing punctuation/spacing;
        # never synthesize a separate period just because it is character 121.
        if len(text) <= _CHINESE_MAX_CHARS + 16 and not re.search(r'\w', text[_CHINESE_MAX_CHARS:]):
            break
        # Keep ordinary sentences intact. Only an oversized sentence needs a
        # clause cut, and use the latest boundary to retain as much prosody as possible.
        boundaries = [m.end() for m in _CHINESE_CLAUSE_END.finditer(text)
                      if m.end() <= _CHINESE_MAX_CHARS]
        if boundaries:
            end = boundaries[-1]
        else:
            import jieba
            # Tokenize the whole remainder so a word spanning the limit is not
            # cut in half (e.g. 扶持). A single pathological token still has a cap.
            ends = [end for _, _, end in jieba.tokenize(text) if end <= _CHINESE_MAX_CHARS]
            end = ends[-1] if ends else _CHINESE_MAX_CHARS
            for token in _LATIN_OR_NUMBER.finditer(text):
                if 0 < token.start() < end < token.end():
                    end = token.start()
                    break
        result.append(text[:end])
        text = text[end:]
    if text:
        result.append(text)
    return result


def _split_chinese_chunks(text: str) -> tuple[str, ...]:
    if not text or not text.strip():
        return ()
    result = []
    start = 0
    for match in _CHINESE_SENTENCE_END.finditer(text):
        result.extend(_bounded_chinese_sentence(text[start:match.end()]))
        start = match.end()
    result.extend(_bounded_chinese_sentence(text[start:]))
    return tuple(result)


def _english_quoted_spans(text: str) -> list[tuple[int, int]]:
    """Complete outer quotations, excluding word-internal apostrophes."""
    pairs = {'"': '"', "'": "'", '“': '”', '‘': '’'}
    # Leading apostrophes are ambiguous until a closing mark arrives. Keep
    # independent candidates so an unpaired 'em cannot hide a double quote.
    openings: dict[str, list[int]] = {}
    spans = []
    elisions = re.compile(r"(?:em|cause|cos|tis|twas|twere|twill|twould|bout|round|til|till|n)\b", re.I)
    for index, char in enumerate(text):
        if char not in '\"\x27“”‘’':
            continue
        before = text[index - 1] if index else ''
        after = text[index + 1] if index + 1 < len(text) else ''
        if char in "'’" and after.isalnum():
            if char == "'" and not before.isalnum():
                openings.setdefault(char, []).append(index)
            # Word-internal apostrophes and leading right-curly elisions are
            # not closing marks (God’s, isn't, ’em).
            continue
        if openings.get(char):
            if char in "'’" and before.lower() == 's' and re.match(r'\s+\w', text[index + 1:]):
                # In 'read the students' notes, and begin.' the first mark is
                # possessive. Require a later punctuated close before any new
                # quotation; do not consume a separately quoted next phrase.
                later = re.search(r'''(?P<open>["“‘]|(?<!\w)'(?=\w))|(?P<close>[.,!?;:]'''
                                  + re.escape(char) + ')', text[index + 1:])
                if later and later.lastgroup == 'close':
                    continue
            candidates = openings.pop(char)
            # Prefer an explicit phrase over a leading elision, but never
            # reject a complete quote merely because it starts with 'cause.
            start = next((left for left in candidates
                          if char != "'" or not elisions.match(text, left + 1)), candidates[0])
            spans.append((start, index + 1))
            for closing in list(openings):
                openings[closing] = [left for left in openings[closing] if left < start]
        elif char in pairs and not (char == "'" and before.isalnum()):
            # A trailing possessive (students') cannot open a quotation.
            openings.setdefault(pairs[char], []).append(index)
    # Inner quotes must not bypass the word cap of a complete outer quote.
    outer = []
    for left, right in sorted(spans, key=lambda span: (span[0], -span[1])):
        if not outer or left >= outer[-1][1]:
            outer.append((left, right))
    return outer


def _split_english_chunks(text: str) -> tuple[str, ...]:
    if not text or not text.strip():
        return ()
    words = list(re.finditer(r'\S+\s*', text))
    quotes = _english_quoted_spans(text)
    result = []
    start = 0
    word_start = 0
    while word_start < len(words):
        end_word = min(word_start + 18, len(words))
        # Keep an introduction and a short quote in one inference only when
        # they already fit the normal budget. Long/unclosed quotes stay bounded.
        fitting_quotes = [(left, right) for left, right in quotes
                          if start <= left < right <= words[end_word - 1].end()]
        for index in range(word_start + 7, min(word_start + 16, len(words))):
            token = words[index].group().strip()
            # Commas/semicolons are natural clauses; periods inside numbers and
            # abbreviations are never scanned as character-level boundaries.
            sentence_end = (token.endswith('.') and token.lower() not in {'dr.', 'mr.', 'mrs.', 'ms.', 'prof.', 'rev.', 'st.', 'vs.', 'etc.'} and not re.fullmatch(r'(?:[A-Za-z]\.)+', token))
            if sentence_end or re.search(r'[,;:!?][\"\u201d\u2019)]*$', token):
                cut = words[index].end()
                clause_end = bool(re.search(r'[,;:][\"\u201d\u2019)]*$', token))
                if clause_end and any(left < cut < right or (
                    cut == left or (end_word == len(words) and right <= cut
                                    and not text[right:cut].strip(' \t\r\n,;:)\"\u201d\u2019\x27')))
                       for left, right in fitting_quotes):
                    continue
                end_word = index + 1
                break
        end = words[end_word - 1].end()
        result.append(text[start:end])
        start = end
        word_start = end_word
    return tuple(result)


def split_speech_chunks(text: str, target_language: str) -> tuple[str, ...]:
    if not text or not text.strip():
        return ()
    from .policy import speech_policy
    return speech_policy(target_language).split(text)


_MULTILINGUAL_END = re.compile(r'(?:[。！？!?।॥]+|(?<!\d)\.(?![\d.]))' + _CLOSERS)
_ABBREVIATIONS = {'m.', 'mme.', 'mlle.', 'dr.', 'mr.', 'mrs.', 'ms.', 'prof.',
                  'sr.', 'sra.', 'srta.', 'sig.', 'sig.ra.', 'dott.', 'etc.', 'p.ex.'}


def _split_multilingual_chunks(text: str) -> tuple[str, ...]:
    """Sentence-first slices with a 240-codepoint soft cap at grapheme ends."""
    import regex
    if not text or not text.strip():
        return ()
    sentences = []
    start = 0
    for match in _MULTILINGUAL_END.finditer(text):
        if text[match.start()] == '.':
            token = text[:match.start() + 1].rsplit(None, 1)[-1].lower()
            if token in _ABBREVIATIONS or regex.fullmatch(r'(?:\p{L}\.)+', token):
                continue
        sentences.append(text[start:match.end()])
        start = match.end()
    if start < len(text):
        sentences.append(text[start:])
    result = []
    for sentence in sentences:
        while len(sentence) > 240:
            ends = [m.end() for m in regex.finditer(r'\X', sentence) if m.end() <= 240]
            # A pathological grapheme may exceed the cap; retain it intact.
            end = ends[-1] if ends else regex.match(r'\X', sentence).end()
            spaces = [m.end() for m in re.finditer(r'\s+', sentence[:end]) if m.end() > end // 2]
            if spaces:
                end = spaces[-1]
            result.append(sentence[:end])
            sentence = sentence[end:]
        if sentence:
            result.append(sentence)
    return tuple(result)
