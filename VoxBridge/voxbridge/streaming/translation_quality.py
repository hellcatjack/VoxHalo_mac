"""Checks for model commentary accidentally returned in place of a translation."""
from __future__ import annotations

import re


def translation_output_issue(source: str, output: str) -> str:
    # This deliberately generous threshold is a recovery signal, not a length
    # limit: preserve normal translations and ask the model again for outliers.
    source_units = len(re.findall(r"[\u3400-\u9fff]|[A-Za-z0-9]+(?:['’][A-Za-z]+)*", source))
    output_units = len(re.findall(r"[\u3400-\u9fff]|[A-Za-z0-9]+(?:['’][A-Za-z]+)*", output))
    if output_units > max(180, source_units * 12):
        return "extreme_expansion"
    # A talk about translation may legitimately contain these exact instructions.
    discusses_translation = re.search(r"translat\w*|prompt\w*|翻译|译文|提示词", source, re.I)
    if discusses_translation:
        return ""
    policy_markers = (
        r"(?:翻译时|翻译原则|翻译要求|翻译后的结果|翻译后的文本)",
        r"(?:忠实[于於]?原文|不添加任何内容|不得增删|不删除任何信息)",
        r"(?:无需[进进行]*解释|不要额外解释|只[需需要]*输出|仅为翻译)",
        r"(?:according to (?:the )?(?:requirements|instructions)|translation principles)",
        r"(?:faithful to the (?:original|source)|without (?:adding|omitting))",
        r"(?:only (?:output|provide) the translat|without additional explanation)",
    )
    if sum(bool(re.search(pattern, output, re.I)) for pattern in policy_markers) >= 2:
        return "policy_echo"
    if re.match(r"\s*(?:该文本|这段文本|the (?:provided |source )?text)", output, re.I):
        if re.search(r"翻译|translat", output, re.I) and len(output) > max(80, len(source) * 2):
            return "translation_commentary"
    return ""


def recovery_translation_prompt(source: str, target_language: str) -> str:
    # HY-MT's documented plain translation template avoids repeating the long
    # policy that caused the first response to explain the instructions.
    return (
        f"将以下文本翻译为{target_language}，注意只需要输出翻译后的结果，不要额外解释：\n\n"
        f"{source}"
    )
