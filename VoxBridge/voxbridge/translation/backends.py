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
"""Translation model adapters. Sampling and prompts retain the verified defaults."""
import json
import logging
import threading
import urllib.request
from contextlib import suppress
from typing import Any, Dict, Optional
from .prompts import _build_translation_prompt
from .language_checks import _text_matches_source_language
from voxbridge.streaming.translation_quality import translation_output_issue, recovery_translation_prompt
from voxbridge.streaming.speculative_translation import TranslationKey

logger = logging.getLogger("voxbridge.cli.demo_streaming_ws")

class LocalTranslator:
    """
    Lightweight local translation wrapper for zh->en real-time subtitles.

    This uses a local causal LM translation model and generates deterministic output.
    """

    enforce_target_language_output = True

    def __init__(
        self,
        model_path: str,
        source_language: str = "Chinese",
        target_language: str = "English",
        max_new_tokens: int = 96,
        device: str = "cpu",
    ) -> None:
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer

        self.model_path = str(model_path)
        self.source_language = str(source_language or "Chinese")
        self.target_language = str(target_language or "English")
        self.max_new_tokens = max(8, int(max_new_tokens))

        resolved_device = str(device or "cpu").strip().lower()
        if resolved_device not in {"cpu", "cuda", "auto"}:
            resolved_device = "cpu"
        if resolved_device == "auto":
            resolved_device = "cuda" if torch.cuda.is_available() else "cpu"
        if resolved_device == "cuda" and not torch.cuda.is_available():
            raise RuntimeError("translation device is cuda but torch.cuda is not available")
        self.device = resolved_device

        model_kwargs: Dict[str, Any] = {"trust_remote_code": True}
        if self.device == "cuda":
            bf16_ok = False
            with suppress(Exception):
                bf16_ok = bool(torch.cuda.is_bf16_supported())
            model_kwargs["dtype"] = torch.bfloat16 if bf16_ok else torch.float16
            model_kwargs["device_map"] = "auto"
        else:
            model_kwargs["dtype"] = torch.float32
            model_kwargs["device_map"] = "cpu"

        self.tokenizer = AutoTokenizer.from_pretrained(self.model_path, trust_remote_code=True)
        self.model = AutoModelForCausalLM.from_pretrained(self.model_path, **model_kwargs)
        self._lock = threading.Lock()

    def _build_prompt(
        self,
        text: str,
        source_language: Optional[str] = None,
        target_language: Optional[str] = None,
        translation_direction: Optional[str] = None,
        strict_target_language: bool = False,
    ) -> str:
        source = str(source_language or self.source_language or "Chinese")
        target = str(target_language or self.target_language or "English")
        return _build_translation_prompt(
            text,
            source,
            target,
            translation_direction,
            strict_target_language,
        )

    def translate(
        self,
        text: str,
        source_language: Optional[str] = None,
        target_language: Optional[str] = None,
        translation_direction: Optional[str] = None,
        strict_target_language: bool = False,
    ) -> str:
        import torch

        src = str(text or "").strip()
        if not src:
            return ""
        source = str(source_language or self.source_language or "Chinese")
        target = str(target_language or self.target_language or "English")
        if not _text_matches_source_language(src, source):
            return ""

        messages = [
            {
                "role": "user",
                "content": self._build_prompt(
                    src,
                    source_language=source,
                    target_language=target,
                    translation_direction=translation_direction,
                    strict_target_language=strict_target_language,
                ),
            }
        ]
        tokenized_chat = self.tokenizer.apply_chat_template(
            messages,
            tokenize=True,
            add_generation_prompt=True,
            return_tensors="pt",
        )
        input_ids = tokenized_chat.to(self.model.device)

        with self._lock, torch.no_grad():
            outputs = self.model.generate(
                input_ids,
                max_new_tokens=self.max_new_tokens,
                do_sample=False,
                temperature=None,
                top_p=None,
                top_k=None,
            )

        new_ids = outputs[0][input_ids.shape[-1]:]
        out = self.tokenizer.decode(new_ids, skip_special_tokens=True).strip()
        if not out:
            out = self.tokenizer.decode(outputs[0], skip_special_tokens=True).strip()

        out = out.replace("<target>", "").replace("</target>", "").strip()
        return out


class OpenAIAPITranslator:
    """
    Translation client using an OpenAI-compatible Chat Completions HTTP API.
    """

    enforce_target_language_output = True

    def __init__(
        self,
        base_url: str,
        model: str,
        source_language: str = "Chinese",
        target_language: str = "English",
        max_new_tokens: int = 96,
        timeout_sec: float = 30.0,
        api_key: str = "",
        sampling_profile: str = "default",
    ) -> None:
        self.base_url = str(base_url or "").strip()
        if not self.base_url:
            raise ValueError("translation api base_url is empty")
        self.model = str(model or "").strip()
        if not self.model:
            raise ValueError("translation api model is empty")
        self.source_language = str(source_language or "Chinese")
        self.target_language = str(target_language or "English")
        self.max_new_tokens = max(8, int(max_new_tokens))
        self.timeout_sec = max(1.0, float(timeout_sec))
        self.api_key = str(api_key or "").strip()
        if sampling_profile not in {"default", "mac-verified"}:
            raise ValueError("Unknown translation sampling profile")
        self.sampling_profile = sampling_profile
        self._lock = threading.Lock()

        normalized = self.base_url.rstrip("/")
        if normalized.endswith("/chat/completions"):
            self.chat_url = normalized
        elif normalized.endswith("/v1"):
            self.chat_url = f"{normalized}/chat/completions"
        else:
            self.chat_url = f"{normalized}/v1/chat/completions"

    def _build_prompt(
        self,
        text: str,
        source_language: Optional[str] = None,
        target_language: Optional[str] = None,
        translation_direction: Optional[str] = None,
        strict_target_language: bool = False,
    ) -> str:
        source = str(source_language or self.source_language or "Chinese")
        target = str(target_language or self.target_language or "English")
        return _build_translation_prompt(
            text,
            source,
            target,
            translation_direction,
            strict_target_language,
        )

    def _extract_content(self, payload: Dict[str, Any]) -> str:
        choices = payload.get("choices")
        if isinstance(choices, list) and choices:
            message = choices[0].get("message", {}) if isinstance(choices[0], dict) else {}
            content = message.get("content")
            if isinstance(content, str):
                return content.strip()
            if isinstance(content, list):
                chunks = []
                for item in content:
                    if isinstance(item, str):
                        chunks.append(item)
                    elif isinstance(item, dict):
                        txt = item.get("text")
                        if isinstance(txt, str):
                            chunks.append(txt)
                return "".join(chunks).strip()
        return ""

    def _extract_finish_reason(self, payload: Dict[str, Any]) -> str:
        choices = payload.get("choices")
        if isinstance(choices, list) and choices and isinstance(choices[0], dict):
            return str(choices[0].get("finish_reason") or "").strip().lower()
        return ""

    def translate(
        self,
        text: str,
        source_language: Optional[str] = None,
        target_language: Optional[str] = None,
        translation_direction: Optional[str] = None,
        strict_target_language: bool = False,
    ) -> str:
        src = str(text or "").strip()
        if not src:
            return ""
        source = str(source_language or self.source_language or "Chinese")
        target = str(target_language or self.target_language or "English")
        if not _text_matches_source_language(src, source):
            return ""

        messages = [
            {
                "role": "user",
                "content": self._build_prompt(
                    src,
                    source_language=source,
                    target_language=target,
                    translation_direction=translation_direction,
                    strict_target_language=strict_target_language,
                ),
            }
        ]
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        max_tokens = int(self.max_new_tokens)
        retry_limit = max(max_tokens, min(512, max(128, max_tokens * 4)))
        quality_retried = False
        while True:
            body = {
                "model": self.model,
                "messages": messages,
                "max_tokens": max_tokens,
                "temperature": 0,
                "top_p": 1,
                "stream": False,
            }
            if self.sampling_profile == "mac-verified":
                body.update(top_p=0.6, top_k=20, repeat_penalty=1.05,
                            repeat_last_n=64, cache_prompt=False)
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            req = urllib.request.Request(self.chat_url, data=data, headers=headers, method="POST")
            with self._lock:
                with urllib.request.urlopen(req, timeout=self.timeout_sec) as resp:
                    raw = resp.read().decode("utf-8", errors="replace")
            payload = json.loads(raw)
            out = self._extract_content(payload)
            out = out.replace("<target>", "").replace("</target>", "").strip()
            finish_reason = self._extract_finish_reason(payload)
            issue = translation_output_issue(src, out)
            if issue:
                if quality_retried:
                    raise ValueError(f"translation output rejected: {issue}")
                quality_retried = True
                logger.warning("translation output retry reason=%s source_chars=%d output_chars=%d",
                               issue, len(src), len(out))
                messages = [{"role": "user", "content": recovery_translation_prompt(src, target,
                            source_language=None if translation_direction in {'zh2en', 'en2zh'} else source)}]
                max_tokens = int(self.max_new_tokens)
                continue
            if finish_reason != "length":
                return out
            next_tokens = min(int(retry_limit), max(max_tokens * 2, 128))
            if next_tokens <= max_tokens:
                raise ValueError("translation output incomplete at token limit")
            max_tokens = next_tokens


def _speculative_translation_key(translator, source, source_language, target_language,
                                 direction, generation, revision):
    # Only the known stateless translators have a complete, enumerable context.
    if not isinstance(translator, (LocalTranslator, OpenAIAPITranslator)):
        return None
    if not _text_matches_source_language(source, source_language):
        return None  # Formal language autofallback remains authoritative.
    prompts = tuple(translator._build_prompt(
        source, source_language=source_language, target_language=target_language,
        translation_direction=direction, strict_target_language=strict,
    ) for strict in (False, True))
    settings = tuple((name, getattr(translator, name, None)) for name in (
        "model_path", "device", "chat_url", "sampling_profile", "max_new_tokens",
        "timeout_sec", "source_language", "target_language", "enforce_target_language_output",
    ))
    model = translator.model if isinstance(translator, OpenAIAPITranslator) else id(translator.model)
    tokenizer = getattr(translator, "tokenizer", None)
    chat_template = str(getattr(tokenizer, "chat_template", ""))
    return TranslationKey(source, direction, source_language, target_language,
                          generation, revision, (id(translator), model, prompts, settings, id(tokenizer), chat_template))
