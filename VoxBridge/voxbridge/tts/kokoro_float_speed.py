"""Narrow input adapter for the pinned kokoro-onnx 0.5.0 Chinese call path."""
from __future__ import annotations

import numpy as np
from kokoro_onnx.config import MAX_PHONEME_LENGTH, SAMPLE_RATE
from .kokoro_chinese import ChineseKokoro


class FloatSpeedKokoro(ChineseKokoro):
    def _create_audio(self, phonemes, voice, speed):
        # Preserve 0.5.0 tokenization, padding and style-row selection exactly.
        # The upstream input_ids branch incorrectly casts speed to int32.
        tokens = self.tokenizer.tokenize(phonemes[:MAX_PHONEME_LENGTH])
        style = voice[len(tokens)]
        inputs = {
            'input_ids': np.asarray([[0, *tokens, 0]], dtype=np.int64),
            'style': np.asarray(style, dtype=np.float32),
            'speed': np.asarray([speed], dtype=np.float32),
        }
        return self.sess.run(None, inputs)[0], SAMPLE_RATE
