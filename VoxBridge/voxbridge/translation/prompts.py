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
"""Verified domain policy and prompt construction; independent of model transport."""
from typing import Optional
from .language_checks import _is_chinese_label, _is_english_label
from voxbridge.streaming.church_terms import terminology_hint
from voxbridge.streaming.translation_quality import recovery_translation_prompt

_ESV_ZH_TO_EN_POLICY = (
    "忠实原文是最高优先级。涉及基督教、圣经或神学内容时，仅对原文中明确出现的"
    "卷名、人名、地名、称谓、神学术语及大小写，必须采用 English Standard Version "
    "(ESV) 的标准英文用法；只有原文完整且语义明确等同于某段经文时，措辞才应尽量"
    "贴近 ESV；若原文是节选、转述、误引或无法确定对应经文时，必须按演讲者实际说法"
    "忠实翻译；不得补写、扩写、解释、纠正或用记忆中的经文替换原文"
)


_CHINESE_CHURCH_POLICY = (
    "忠实原文是最高优先级。涉及基督教、圣经或神学内容时，原文明确出现的卷名、"
    "人名、地名、称谓和神学术语应采用通行的中文圣经译名和中文教会用语；"
    "有明确指定的名称时遵循原文。经文节选、转述、误引或无法确定出处时，"
    "必须按演讲者实际说法忠实翻译；不得补写、扩写、解释、纠正或用记忆中的经文替换原文"
)


def _build_translation_prompt(
    text: str,
    source_language: str,
    target_language: str,
    translation_direction: Optional[str] = None,
    strict_target_language: bool = False,
) -> str:
    source = str(source_language or "Chinese")
    target = str(target_language or "English")
    direction = str(translation_direction or "").strip().lower()
    legacy_pair = (direction in {"zh2en", "en2zh", "zh->en", "en->zh", "chinese->english", "english->chinese", "中文->英文", "英文->中文"}
                   or (_is_chinese_label(source) and _is_english_label(target))
                   or (_is_english_label(source) and _is_chinese_label(target)))
    if not legacy_pair:
        return recovery_translation_prompt(text, target, source_language=source)
    hint = terminology_hint(text, target)
    if hint and not strict_target_language:
        # The documented short template avoids term lists interacting with the
        # long policy (which swapped subjects in the real Genesis replay).
        return hint + recovery_translation_prompt(text, target)
    direction = str(translation_direction or "").strip().lower()
    if direction in {"zh2en", "zh->en", "chinese->english", "中文->英文"}:
        use_esv_policy = True
    elif direction in {"en2zh", "en->zh", "english->chinese", "英文->中文"}:
        use_esv_policy = False
    else:
        use_esv_policy = _is_chinese_label(source) and _is_english_label(target)

    requirements = ["忠实原文，不增删"]
    if use_esv_policy:
        requirements.append(_ESV_ZH_TO_EN_POLICY)
    elif _is_chinese_label(target):
        requirements.append(_CHINESE_CHURCH_POLICY)
        requirements.append("无通行中文译名的专有名词或缩写可保留原文")
    else:
        requirements.append("保留专有名词")
    requirements.append(
        "省略不承载语义、只用于拖延发言的犹豫音和口头填充，"
        "不得把这些成分翻译成目标语言中的填充词；"
        "自我修复只保留修正后的语义；"
        "不得因此省略有语义的感叹、否定、强调或正文内容"
    )
    if strict_target_language:
        if _is_chinese_label(target):
            requirements.append(f"普通语句必须译为{target}，不得整句照抄{source}；无通行中文译名的专有名词或缩写可保留原文")
        else:
            requirements.append(f"译文必须全部使用{target}，不得保留未翻译的{source}字词")
    requirements.append("只输出译文本身，不要解释")
    return (
        hint +
        f"请将以下{source}文本翻译为{target}。\n"
        f"要求：{'；'.join(requirements)}。\n\n"
        f"原文：\n{text}"
    )
