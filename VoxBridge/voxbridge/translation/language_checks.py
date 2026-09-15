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
"""Compatibility checks for the verified Chinese/English translation policies."""
import re
import regex
from typing import Any
from voxbridge.languages import language_profile


def _name_or_number(text: str) -> bool:
    words = regex.findall(r"[\p{Latin}]+(?:['’-][\p{Latin}]+)*", text)
    return not regex.search(r'\p{L}', text) or bool(
        words and len(words) <= 4 and all(not word.islower() for word in words)
        and not regex.search(r'[^\p{Latin}\p{N}\p{P}\p{Z}\p{S}\s]', text))


def _script_matches(text: str, language: str) -> bool:
    profile = language_profile(language)
    patterns = {'han': r'\p{Han}', 'japanese': r'[\p{Han}\p{Hiragana}\p{Katakana}]',
                'devanagari': r'\p{Devanagari}', 'latin': r'\p{Latin}'}
    return bool(regex.search(patterns[profile.script], text)) or _name_or_number(text)

def _has_cjk(text: str) -> bool:
    return bool(re.search(r"[\u3400-\u9fff]", str(text or "")))


def _has_latin(text: str) -> bool:
    return bool(re.search(r"[A-Za-z]", str(text or "")))


def _is_chinese_label(text: Any) -> bool:
    ln = str(text or "").strip().lower()
    if not ln:
        return False
    return ("chinese" in ln) or ("中文" in ln) or (ln in {"zh", "zh-cn", "zh-hans", "zh-hant"})


def _is_english_label(text: Any) -> bool:
    ln = str(text or "").strip().lower()
    if not ln:
        return False
    return ("english" in ln) or ("英文" in ln) or (ln in {"en", "en-us", "en-gb"})


def _text_matches_source_language(text: str, source_language: str) -> bool:
    src = str(text or "").strip()
    if not src:
        return False
    if _is_chinese_label(source_language):
        return _has_cjk(src)
    if _is_english_label(source_language):
        return _has_latin(src)
    try:
        return _script_matches(src, source_language)
    except ValueError:
        return True


def _translation_needs_target_language_retry(text: str, target_language: str) -> bool:
    out = str(text or "").strip()
    if not out:
        return False
    if _is_english_label(target_language):
        return _has_cjk(out)
    if _is_chinese_label(target_language) and not _has_cjk(out):
        # Catch clearly untranslated English sentences, while allowing mixed Chinese,
        # acronyms and standalone names such as OpenAI or New York City.
        words = re.findall(r"[A-Za-z]+(?:['’-][A-Za-z]+)*", out)
        return sum(word.islower() for word in words) >= 3
    if not _is_chinese_label(target_language):
        try:
            return not _script_matches(out, target_language)
        except ValueError:
            return False
    return False
