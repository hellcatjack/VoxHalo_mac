"""Small, source-matched church glossary shared by both translation directions."""
from __future__ import annotations

import re


CHURCH_TERMS = (
    ("Jesus Christ", "耶稣基督"), ("Holy Spirit", "圣灵"),
    ("Nehemiah", "尼希米"), ("Eliashib", "以利亚实"), ("Tobiah", "多比雅"),
    ("Levites", "利未人"), ("Jerusalem", "耶路撒冷"), ("Ammonite", "亚扪人"),
    ("Genesis", "创世记"), ("Adam", "亚当"), ("Eve", "夏娃"),
    ("Cain", "该隐"), ("Abel", "亚伯"), ("Enoch", "以诺"),
    ("Seth", "塞特"), ("Enosh", "以挪士"), ("Lamech", "拉麦"),
    ("Adah", "亚大"), ("Zillah", "洗拉"), ("Tubal-cain", "土八该隐"),
    ("Jabal", "雅八"), ("Jubal", "犹八"), ("Naamah", "拿玛"),
    ("Eden", "伊甸"), ("Pishon", "比逊"), ("Gihon", "基训"),
    ("Havilah", "哈腓拉"), ("Cush", "古实"), ("Assyria", "亚述"),
    ("Tigris", "底格里斯河"), ("Euphrates", "幼发拉底河"),
)


def terminology_hint(source: str, target_language: str) -> str:
    chinese = target_language.strip().casefold() in {'chinese', '中文', 'zh', 'zh-cn'}
    english = target_language.strip().casefold() in {'english', '英语', '英文', 'en'}
    if not (chinese or english):
        return ''
    pairs = [(en, zh) if chinese else (zh, en) for en, zh in CHURCH_TERMS]
    if english:
        pairs += [('尼西米', 'Nehemiah'), ('多比亚', 'Tobiah'), ('利卫人', 'Levites')]
    selected = []
    occupied = []
    for term, translated in sorted(pairs, key=lambda pair: len(pair[0]), reverse=True):
        pattern = rf'(?<![A-Za-z]){re.escape(term)}(?![A-Za-z])' if chinese else re.escape(term)
        for match in re.finditer(pattern, source):
            if any(match.start() < end and match.end() > start for start, end in occupied):
                continue
            selected.append((match.start(), f'{term} 翻译成 {translated}'))
            occupied.append(match.span())
            break
        if len(selected) >= 8:
            break
    return ('参考下面的翻译：\n' + '\n'.join(line for _, line in sorted(selected)) + '\n\n') if selected else ''
