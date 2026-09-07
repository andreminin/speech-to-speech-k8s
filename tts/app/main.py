"""OpenAI-compatible /v1/audio/speech server, backed by Qwen3-TTS via
faster-qwen3-tts. Matches the client contract in upstream speech-to-speech's
docs/openai-compatible-tts.md so the gateway can point --openai_tts_base_url
at this service directly.

Note: upstream's --openai_tts_stream flag toggles a vLLM-Omni-specific
`stream` request field that this server does NOT implement (see plan doc) —
keep the gateway configured with --openai_tts_stream false. Response bodies
are still delivered as a streamed/chunked HTTP response either way, which is
what actually helps time-to-first-audio.
"""
from __future__ import annotations

import io
import json
import logging
import os
import time
import uuid
import wave
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import StreamingResponse

from .model import DEFAULT_MODEL_NAME, NATIVE_SAMPLE_RATE, Qwen3TTS
from .schemas import HealthResponse, SpeechRequest, VoicesResponse

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger("speech-tts")

MODEL_NAME = os.environ.get("TTS_MODEL_NAME", DEFAULT_MODEL_NAME)
DEVICE = os.environ.get("TTS_DEVICE", "cuda")
BACKEND = os.environ.get("TTS_BACKEND", "ggml")
AVAILABLE_VOICES = os.environ.get("TTS_VOICES", "aiden").split(",")

tts = Qwen3TTS(model_name=MODEL_NAME, device=DEVICE, backend=BACKEND)


@asynccontextmanager
async def lifespan(app: FastAPI):
    tts.load()
    yield


app = FastAPI(title="speech-tts", lifespan=lifespan)


def log_json(**fields) -> None:
    logger.info(json.dumps({"component": "tts", **fields}))


def _wav_header(num_channels=1, sample_rate=NATIVE_SAMPLE_RATE, bits_per_sample=16) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(num_channels)
        w.setsampwidth(bits_per_sample // 8)
        w.setframerate(sample_rate)
        w.writeframes(b"")
    return buf.getvalue()


@app.get("/healthz")
async def healthz():
    if not tts.is_loaded:
        raise HTTPException(status_code=503, detail="model not loaded")
    return HealthResponse(status="ok", model_loaded=True)


@app.get("/v1/audio/voices", response_model=VoicesResponse)
async def voices():
    return VoicesResponse(voices=AVAILABLE_VOICES)


@app.post("/v1/audio/speech")
async def synthesize(body: SpeechRequest, request: Request):
    if body.voice not in AVAILABLE_VOICES:
        raise HTTPException(status_code=400, detail=f"unknown voice '{body.voice}'")

    request_id = request.headers.get("X-Speech-Request-Id", str(uuid.uuid4()))
    start = time.monotonic()

    def gen():
        first_chunk_at = None
        total_bytes = 0
        if body.response_format == "wav":
            yield _wav_header(sample_rate=body.sample_rate)
        for chunk in tts.synthesize_stream(body.input, body.voice):
            if first_chunk_at is None:
                first_chunk_at = time.monotonic()
            total_bytes += len(chunk)
            yield chunk
        duration_ms = (time.monotonic() - start) * 1000
        ttfa_ms = ((first_chunk_at or time.monotonic()) - start) * 1000
        log_json(
            request_id=request_id,
            duration_ms=round(duration_ms, 1),
            ttfa_ms=round(ttfa_ms, 1),
            text_len=len(body.input),
            audio_bytes=total_bytes,
        )

    media_type = "audio/wav" if body.response_format == "wav" else "audio/pcm"
    return StreamingResponse(
        gen(), media_type=media_type, headers={"X-Speech-Request-Id": request_id}
    )
