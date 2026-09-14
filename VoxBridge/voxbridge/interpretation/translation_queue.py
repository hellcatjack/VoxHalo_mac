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
"""Bounded translation work and cancellation lifecycle, independent of transport."""
import asyncio
from contextlib import suppress
from typing import Awaitable, Callable
from .contracts import TranslationRuntime


async def run_translation_queue(runtime: TranslationRuntime, translate: Callable[..., Awaitable[str]]) -> None:
    active_tasks = set()
    try:
        while True:
            try:
                (
                    sentence_id,
                    revision,
                    sentence_text,
                    language,
                    seq_hint,
                    state_gen_hint,
                    source_language,
                    target_language,
                    direction,
                ) = await asyncio.wait_for(
                    runtime.queue.get(),
                    timeout=0.2,
                )
            except asyncio.TimeoutError:
                if runtime.queue.empty() and not active_tasks:
                    break
                if active_tasks:
                    done, pending = await asyncio.wait(
                        active_tasks,
                        timeout=0.05,
                        return_when=asyncio.FIRST_COMPLETED,
                    )
                    for task in done:
                        with suppress(Exception):
                            task.result()
                    active_tasks = set(pending)
                continue

            while len(active_tasks) >= int(runtime.parallelism):
                done, pending = await asyncio.wait(
                    active_tasks,
                    return_when=asyncio.FIRST_COMPLETED,
                )
                for task in done:
                    with suppress(Exception):
                        task.result()
                active_tasks = set(pending)

            task = asyncio.create_task(
                translate(
                    str(sentence_id),
                    int(revision),
                    str(sentence_text),
                    str(language),
                    int(seq_hint or 0),
                    int(state_gen_hint or 0),
                    str(source_language or ""),
                    str(target_language or ""),
                    str(direction or ""),
                )
            )
            active_tasks.add(task)

        if active_tasks:
            await asyncio.gather(*active_tasks, return_exceptions=True)
    finally:
        if active_tasks:
            for task in active_tasks:
                task.cancel()
            await asyncio.gather(*active_tasks, return_exceptions=True)
        runtime.task = None
