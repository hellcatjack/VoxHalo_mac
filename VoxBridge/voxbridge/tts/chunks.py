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


def _split_english_chunks(text: str) -> tuple[str, ...]:
    if not text or not text.strip():
        return ()
    words = list(re.finditer(r'\S+\s*', text))
    result = []
    start = 0
    word_start = 0
    while word_start < len(words):
        end_word = min(word_start + 18, len(words))
        for index in range(word_start + 7, min(word_start + 16, len(words))):
            token = words[index].group().strip()
            # Commas/semicolons are natural clauses; periods inside numbers and
            # abbreviations are never scanned as character-level boundaries.
            sentence_end = (token.endswith('.') and token.lower() not in {'dr.', 'mr.', 'mrs.', 'ms.', 'prof.', 'rev.', 'st.', 'vs.', 'etc.'} and not re.fullmatch(r'(?:[A-Za-z]\.)+', token))
            if sentence_end or re.search(r'[,;:!?][\"\u201d\u2019)]*$', token):
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
