"""Private local PCM transport and short-lived actual playback feedback."""
from __future__ import annotations

import hmac
import math
import time
import weakref
from typing import Callable

from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse

from .hls import HLSListenerCapacityExceeded, HLSUnavailable


class NativePlaybackFeedback:
    def __init__(self, *, clock: Callable[[], float] = time.monotonic):
        self.clock = clock
        self.entries: dict[str, dict] = {}
        self.events = weakref.WeakSet()

    def subscribe(self, event) -> None:
        self.events.add(event)

    def remove(self, listener: str) -> None:
        self.entries.pop(listener, None)
        for event in self.events:
            event.set()

    def update(self, listener: str, *, epoch: str, received_seq: int,
               played_seq: int, buffered_ms: float, playing: bool) -> None:
        if (not isinstance(epoch, str) or not epoch
            or type(received_seq) is not int or type(played_seq) is not int
            or not 0 <= played_seq <= received_seq or type(playing) is not bool
            or type(buffered_ms) not in (int, float) or not math.isfinite(buffered_ms)
            or not 0 <= buffered_ms <= 120000):
            raise ValueError("invalid native playback feedback")
        now = self.clock()
        self.entries = {key: value for key, value in self.entries.items()
                        if now - value["at"] < 2}
        previous = self.entries.get(listener)
        if previous and previous["epoch"] == epoch and (
            received_seq < previous["received_seq"] or played_seq < previous["played_seq"]
        ):
            raise ValueError("native playback sequence regressed")
        self.entries[listener] = dict(epoch=epoch, received_seq=received_seq,
                                     played_seq=played_seq, buffered_ms=buffered_ms,
                                     playing=playing, at=now)
        for event in self.events:
            event.set()

    def urgent(self, epoch: str) -> bool:
        now = self.clock()
        return any(value["epoch"] == epoch and now - value["at"] < 2
                   and value["buffered_ms"] <= 2000 for value in self.entries.values())

    def next_expiry(self, epoch: str) -> float | None:
        now = self.clock()
        deadlines = [value["at"] + 2 for value in self.entries.values()
                     if value["epoch"] == epoch and value["at"] + 2 > now]
        return min(deadlines) if deadlines else None


def register_native_pcm_routes(app, *, token: str, owner_key, validate_listener) -> None:
    feedback = NativePlaybackFeedback()
    app.state.native_playback = feedback
    joined: dict[str, float] = {}

    def authorize(request: Request, listener_id: str) -> str:
        if (not request.client or request.client.host not in {"127.0.0.1", "::1"}
            or not hmac.compare_digest(request.headers.get("x-voxbridge-control-token", ""), token)):
            raise HTTPException(403, "native console authorization required")
        return validate_listener(listener_id)

    @app.get("/api/native/tts/{listener_id}/pcm")
    async def native_pcm(request: Request, listener_id: str, after: int = -1,
                         epoch: str | None = None):
        listener = authorize(request, listener_id)
        if after < -1 or (after >= 0 and not epoch):
            raise HTTPException(400, "PCM cursor requires an epoch")
        publisher = app.state.tts_hls
        try:
            await publisher.touch_listener(listener, owner_key(listener))
            result = publisher.native_pcm.snapshot(after, epoch)
        except HLSListenerCapacityExceeded as exc:
            raise HTTPException(429, "listener capacity reached") from exc
        except HLSUnavailable as exc:
            raise HTTPException(503, "PCM stream unavailable") from exc
        except ValueError as exc:
            raise HTTPException(409, "PCM epoch or cursor discontinuity") from exc
        if not result["epoch"]:
            raise HTTPException(503, "PCM stream unavailable")
        now = time.monotonic()
        for key in list(joined):
            if now - joined[key] > 90:
                joined.pop(key, None)
                feedback.remove(key)
        joined[listener] = now
        return JSONResponse(result, headers={"Cache-Control": "no-store"})

    @app.post("/api/native/tts/{listener_id}/playback")
    async def native_playback(request: Request, listener_id: str):
        listener = authorize(request, listener_id)
        if listener not in joined or time.monotonic() - joined[listener] > 90:
            raise HTTPException(409, "PCM listener is not joined")
        try:
            body = await request.json()
            if not isinstance(body, dict):
                raise ValueError("invalid feedback")
            # Validate before comparing cursors or recording pressure.
            probe = NativePlaybackFeedback()
            probe.update(listener, **body)
            tail = app.state.tts_hls.native_pcm.snapshot(-1, body["epoch"])
            if body["received_seq"] > tail["cursor"]:
                raise HTTPException(409, "PCM playback cursor is ahead of published audio")
            feedback.update(listener, **body)
        except (TypeError, ValueError, KeyError) as exc:
            raise HTTPException(400, "invalid PCM playback feedback") from exc
        return JSONResponse({"ok": True}, headers={"Cache-Control": "no-store"})
