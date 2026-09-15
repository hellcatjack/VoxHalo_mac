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
"""Asynchronous translation without HTTP routes, subtitles or audio ownership."""
import asyncio
import hashlib
import inspect
import logging
import time
from typing import Callable
from voxbridge.interpretation.contracts import TranslationRequest
from voxbridge.languages import translation_pair
from .language_checks import (_has_cjk, _has_latin, _is_chinese_label, _is_english_label,
                              _text_matches_source_language, _translation_needs_target_language_retry, _script_matches)

logger = logging.getLogger("voxbridge.cli.demo_streaming_ws")

def _hash8(text: str) -> str:
    src = str(text or "").encode("utf-8", errors="ignore")
    if not src:
        return "00000000"
    return hashlib.md5(src).hexdigest()[:8]


class TranslationService:
    def __init__(self, backend, *, trace: Callable | None = None,
                 on_error: Callable[[str], None] | None = None,
                 zh_label: str = "Chinese", en_label: str = "English", peer: str = "local"):
        self.backend = backend
        self.trace = trace or (lambda event, **fields: None)
        self.on_error = on_error or (lambda message: None)
        self.zh_label, self.en_label, self.peer = zh_label, en_label, peer
        self.accepts_direction = self.accepts_strict = False
        if backend is not None:
            try:
                parameters = list(inspect.signature(backend.translate).parameters.values())
            except (TypeError, ValueError):
                parameters = []
            self.accepts_direction = any(p.name == "translation_direction" or p.kind == inspect.Parameter.VAR_KEYWORD for p in parameters)
            self.accepts_strict = any(p.name == "strict_target_language" or p.kind == inspect.Parameter.VAR_KEYWORD for p in parameters)

    async def translate(self, request: TranslationRequest, *, preflight: bool = False) -> str:
        sentence_id, revision, sentence, language, seq_hint, generation, source_language, target_language, direction = request
        # Configured legacy labels also carry prompt wording. Resolve only
        # their identity here; pass the original strings to the backend.
        def language_identity(label: str) -> str:
            if label == self.zh_label and _is_chinese_label(label):
                return 'zh'
            if label == self.en_label and _is_english_label(label):
                return 'en'
            return label

        pair = translation_pair(language_identity(source_language), language_identity(target_language))
        if direction != pair.direction:
            raise ValueError('translation direction does not match source and target languages')
        if self.backend is None:
            return ""
        src = str(sentence or "").strip()
        if not src:
            return ""
        effective_source_language = str(source_language or "")
        if pair.direction in {'zh2en', 'en2zh'} and not _text_matches_source_language(src, effective_source_language):
            if _has_cjk(src):
                effective_source_language = self.zh_label
            elif _has_latin(src):
                effective_source_language = self.en_label
            else:
                effective_source_language = ""
            self.trace(
                "translation_source_autofallback",
                seq=int(seq_hint or 0),
                language=str(language or ""),
                source_language=str(source_language or ""),
                effective_source_language=str(effective_source_language or ""),
                target_language=str(target_language or ""),
                direction=str(direction or ""),
                sentence_id=str(sentence_id or ""),
                revision=int(revision),
                src_chars=len(src),
                src_hash8=_hash8(src),
            )

        def needs_target_retry(text: str) -> bool:
            if pair.direction in {'zh2en', 'en2zh'}:
                return _translation_needs_target_language_retry(text, target_language)
            return bool(text.strip()) and not _script_matches(text, pair.target.code)

        t0 = time.monotonic()
        try:
            async def _invoke_translator(*, strict_target_language: bool) -> str:
                translate_kwargs = {
                    "source_language": effective_source_language,
                    "target_language": target_language,
                }
                if self.accepts_direction:
                    translate_kwargs["translation_direction"] = direction
                if strict_target_language and self.accepts_strict:
                    translate_kwargs["strict_target_language"] = True
                try:
                    result = await asyncio.to_thread(
                        self.backend.translate,
                        src,
                        **translate_kwargs,
                    )
                except TypeError:
                    result = await asyncio.to_thread(self.backend.translate, src)
                return str(result or "").strip()

            out = await _invoke_translator(strict_target_language=False)
            quality_retry_count = 0
            enforce_target_language = bool(
                getattr(self.backend, "enforce_target_language_output", False)
            )
            if enforce_target_language and needs_target_retry(out):
                self.trace(
                    "translation_target_language_mismatch",
                    seq=int(seq_hint or 0),
                    sentence_id=str(sentence_id or ""),
                    revision=int(revision),
                    direction=str(direction or ""),
                    source_language=str(effective_source_language or ""),
                    target_language=str(target_language or ""),
                    attempt=1,
                    out_chars=len(out),
                    out_hash8=_hash8(out),
                    strict_retry_supported=bool(
                        self.accepts_strict
                    ),
                )
                if self.accepts_strict:
                    quality_retry_count = 1
                    out = await _invoke_translator(strict_target_language=True)
                # The Chinese heuristic cannot distinguish every Latin name
                # from an untranslated sentence. Keep the best retry instead
                # of silently deleting a valid name and its spoken audio.
                if ((pair.direction not in {'zh2en', 'en2zh'} or pair.target.code != 'zh')
                        and needs_target_retry(out)):
                    self.trace(
                        "translation_target_language_rejected",
                        seq=int(seq_hint or 0),
                        sentence_id=str(sentence_id or ""),
                        revision=int(revision),
                        direction=str(direction or ""),
                        source_language=str(effective_source_language or ""),
                        target_language=str(target_language or ""),
                        attempt=2 if quality_retry_count else 1,
                        out_chars=len(out),
                        out_hash8=_hash8(out),
                    )
                    logger.warning(
                        "translation rejected target-language mismatch peer=%s seq=%d "
                        "target=%s out_chars=%d",
                        self.peer,
                        int(seq_hint or 0),
                        str(target_language or ""),
                        len(out),
                    )
                    out = ""
        except Exception as e:
            self.on_error(f"translate failed: {e}")
            logger.warning("translation failed peer=%s err=%s", self.peer, e)
            self.trace(
                "translation_failed",
                seq=int(seq_hint or 0),
                language=str(language or ""),
                source_language=str(source_language or ""),
                target_language=str(target_language or ""),
                direction=str(direction or ""),
                sentence_id=str(sentence_id or ""),
                revision=int(revision),
                src_chars=len(src),
                src_hash8=_hash8(src),
                error=str(e),
            )
            return ""
        latency = time.monotonic() - t0
        self.trace(
            "translation_speculative_done" if preflight else "translation_done",
            seq=int(seq_hint or 0),
            language=str(language or ""),
            source_language=str(source_language or ""),
            effective_source_language=str(effective_source_language or ""),
            target_language=str(target_language or ""),
            direction=str(direction or ""),
            sentence_id=str(sentence_id or ""),
            revision=int(revision),
            src_chars=len(src),
            src_hash8=_hash8(src),
            out_chars=len(out or ""),
            out_hash8=_hash8(str(out or "")),
            latency_ms=int(latency * 1000),
            quality_retry_count=int(quality_retry_count),
        )
        if latency >= 1.0:
            logger.info(
                "translation latency peer=%s sec=%.2f seq=%d src_chars=%d out_chars=%d",
                self.peer,
                latency,
                int(seq_hint or 0),
                len(src),
                len(out or ""),
            )
        return str(out or "").strip()
