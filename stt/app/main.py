"""OpenAI-compatible /v1/audio/transcriptions server, backed by Parakeet-TDT
via nano-parakeet. Matches the client contract in upstream speech-to-speech's
docs/openai-compatible-stt.md so the gateway can point --openai_stt_base_url
at this service directly.
"""
from __future__ import annotations

import json
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse

from .model import DEFAULT_MODEL_NAME, ParakeetSTT
from .schemas import HealthResponse, TranscriptionResponse

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger("speech-stt")

MODEL_NAME = os.environ.get("STT_MODEL_NAME", DEFAULT_MODEL_NAME)
DEVICE = os.environ.get("STT_DEVICE", "cuda")

stt = ParakeetSTT(model_name=MODEL_NAME, device=DEVICE)


@asynccontextmanager
async def lifespan(app: FastAPI):
    stt.load()
    yield


app = FastAPI(title="speech-stt", lifespan=lifespan)


def log_json(**fields) -> None:
    logger.info(json.dumps({"component": "stt", **fields}))


@app.get("/healthz")
async def healthz():
    if not stt.is_loaded:
        raise HTTPException(status_code=503, detail="model not loaded")
    return HealthResponse(status="ok", model_loaded=True)


@app.get("/v1/models")
async def list_models():
    return {"data": [{"id": MODEL_NAME, "object": "model"}]}


@app.post("/v1/audio/transcriptions", response_model=TranscriptionResponse)
async def transcribe(
    request: Request,
    file: UploadFile = File(...),
    model: str | None = Form(default=None),
    language: str | None = Form(default=None),
):
    request_id = request.headers.get("X-Speech-Request-Id", str(uuid.uuid4()))
    start = time.monotonic()

    wav_bytes = await file.read()
    try:
        audio = stt.decode_wav(wav_bytes)
    except Exception as exc:  # noqa: BLE001 - surface a clean 400 to the client
        raise HTTPException(status_code=400, detail=f"could not decode audio: {exc}") from exc

    audio_seconds = len(audio) / 16_000
    text = stt.transcribe(audio)
    duration_ms = (time.monotonic() - start) * 1000

    log_json(
        request_id=request_id,
        duration_ms=round(duration_ms, 1),
        audio_seconds=round(audio_seconds, 2),
        text_len=len(text),
    )

    return JSONResponse(
        content={"text": text, "language": language},
        headers={"X-Speech-Request-Id": request_id},
    )
