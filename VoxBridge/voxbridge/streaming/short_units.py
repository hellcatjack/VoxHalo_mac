"""Group available short source sentences without timers or lost occurrences."""
import re
from collections.abc import Callable


def standalone_short(text: str) -> bool:
    bare = text.strip().rstrip('.。!！?？').strip().casefold()
    return bare in {'yes', 'no', 'stop', 'thanks', 'thank you', 'okay', 'ok',
                    '是', '是的', '不是', '不', '停', '停止', '谢谢', '好的'}


def _size(text: str) -> tuple[int, bool]:
    cjk = re.findall(r'[\u3400-\u9fff]', text)
    return (len(cjk), True) if cjk else (len(re.findall(r"\w+(?:['’]\w+)*", text)), False)


def group_short_units(units: list[str]) -> list[str]:
    """Only combine neighboring, already-complete units; never swallow a tail."""
    result: list[str] = []
    index = 0
    while index < len(units):
        current = units[index]
        index += 1
        size, cjk = _size(current)
        while size < (10 if cjk else 6) and index < len(units):
            following = units[index]
            count, same_script = _size(following)
            if (standalone_short(current) or standalone_short(following)
                    or (not cjk and size < 2)
                    or (not cjk and (not re.match(r'^(?:I|we|you|he|she|it|they|this|that|these|those)\b', current, re.I)
                                     or not re.match(r'^(?:I|we|you|he|she|it|they|this|that|these|those)\b', following, re.I)))
                    or current.strip().casefold() == following.strip().casefold()
                    or count >= (10 if cjk else 6)
                    or re.search(r'[!?！？]["”’\']*$', current)
                    or cjk != same_script or size + count > (32 if cjk else 24)):
                break
            # Preserve all punctuation, negation and genuine repetitions.
            current += ('' if cjk else ' ') + following
            size += count
            index += 1
        result.append(current)
    return result


def split_short_units(text: str, *, splitter: Callable, locked: list[str]) -> tuple[list[str], str]:
    """Published/submitted boundaries remain fixed as following text grows.

    A changed prefix goes through the existing revision reconciler unchanged;
    grouping must never create a second interpretation of a submitted prefix.
    """
    units, tail = splitter(text)
    cursor = 0
    for unit in locked:
        expected = re.sub(r'\s+', '', unit)
        matched = ''
        while len(matched) < len(expected) and cursor < len(units):
            matched += re.sub(r'\s+', '', units[cursor])
            cursor += 1
        if matched != expected:
            return units, tail
    # Split the complete snapshot first. Splitting only the suffix could change
    # the existing CJK short-tail carry rule or a semantic dependency repair.
    pending = units[cursor:]
    # The existing committer holds its newest unit for lookahead. Absorbing that
    # unit into its predecessor would delay both, including a carried final tail.
    # Keep this boundary intact even though both units already have punctuation.
    return list(locked) + group_short_units(pending[:-1]) + pending[-1:], tail
