"""Protect long Chinese phoneme batches in the pinned Kokoro 0.5.0 runtime."""
import re

from kokoro_onnx import Kokoro
from kokoro_onnx.config import MAX_PHONEME_LENGTH


class ChineseKokoro(Kokoro):
    def _split_phonemes(self, phonemes: str) -> list[str]:
        # Preserve the existing normalization and punctuation grouping for all
        # normal inputs. Upstream can emit an empty or oversized batch when one
        # unpunctuated clause exceeds its context, then silently truncate it.
        batches = []
        for batch in super()._split_phonemes(phonemes):
            if not batch.strip():
                continue
            # Upstream may strand the final period after an oversized clause.
            # Attach it before bounding, so it never becomes its own inference.
            if batches and re.fullmatch(r'[.,!?;:\s]+', batch):
                batches[-1] += batch
            else:
                batches.append(batch)
        result = []
        for batch in batches:
            while len(batch) > MAX_PHONEME_LENGTH:
                boundaries = [m.end() for m in re.finditer(r'[/\s]+', batch)
                              if m.end() <= MAX_PHONEME_LENGTH]
                end = boundaries[-1] if boundaries else MAX_PHONEME_LENGTH
                if re.fullmatch(r'[/.,!?;:\s]+', batch[end:]):
                    earlier = [boundary for boundary in boundaries if boundary < end]
                    end = earlier[-1] if earlier else max(1, end - 1)
                result.append(batch[:end])
                batch = batch[end:]
            if batch.strip():
                result.append(batch)
        return result
