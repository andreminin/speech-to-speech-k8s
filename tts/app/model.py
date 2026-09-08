"""Thin wrapper around faster-qwen3-tts, mirroring how upstream
speech-to-speech itself drives the model (src/speech_to_speech/TTS/qwen3_tts_handler.py):

    from faster_qwen3_tts import FasterQwen3TTS
    model = FasterQwen3TTS.from_pretrained(model_name, device=..., backend="ggml", ...)
    for chunk in model.generate_custom_voice_streaming(text, voice=..., chunk_size=..., max_new_tokens=...):
        ...

Preset/custom voices (e.g. "aiden") map to generate_custom_voice_streaming;
voice cloning and voice-design are separate upstream entry points
(generate_voice_clone_streaming / generate_voice_design_streaming) that this
wrapper does not expose yet.

NOTE: the exact per-chunk return type of generate_custom_voice_streaming
(raw numpy samples vs. already-encoded bytes) should be confirmed against
the installed faster-qwen3-tts version before relying on this in production
— see docs/troubleshooting.md. This wrapper normalizes whatever comes back
into int16 PCM bytes.
"""
from __future__ import annotations

import logging
import threading
from typing import Iterator

import numpy as np

logger = logging.getLogger("speech-tts")

DEFAULT_MODEL_NAME = "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"
DEFAULT_LANGUAGE = "English"
NATIVE_SAMPLE_RATE = 24_000
DEFAULT_CHUNK_SIZE = 512
DEFAULT_MAX_NEW_TOKENS = 2048


def _to_pcm16_bytes(chunk) -> bytes:
    """Normalize a generated audio chunk (numpy float32 in [-1, 1], or
    already-int16 samples) into little-endian int16 PCM bytes."""
    arr = np.asarray(chunk)
    if arr.dtype != np.int16:
        arr = np.clip(arr, -1.0, 1.0)
        arr = (arr * 32767.0).astype(np.int16)
    return arr.tobytes()


class Qwen3TTS:
    def __init__(
        self,
        model_name: str = DEFAULT_MODEL_NAME,
        device: str = "cuda",
        backend: str = "ggml",
    ) -> None:
        self.model_name = model_name
        self.device = device
        self.backend = backend
        self._model = None
        self._lock = threading.Lock()

    def load(self) -> None:
        from faster_qwen3_tts import FasterQwen3TTS

        logger.info("loading %s on %s (backend=%s)", self.model_name, self.device, self.backend)
        self._model = FasterQwen3TTS.from_pretrained(
            self.model_name, device=self.device, backend=self.backend
        )

        with self._lock:
            for _ in self._model.generate_custom_voice_streaming(
                "warm up",
                speaker="aiden",
                language=DEFAULT_LANGUAGE,
                chunk_size=DEFAULT_CHUNK_SIZE,
                max_new_tokens=64,
            ):
                pass
        logger.info("model warm-up complete")

    @property
    def is_loaded(self) -> bool:
        return self._model is not None

    def synthesize_stream(self, text: str, voice: str, language: str | None = None) -> Iterator[bytes]:
        if self._model is None:
            raise RuntimeError("model not loaded")
        with self._lock:
            for chunk, _sr, _timing in self._model.generate_custom_voice_streaming(
                text,
                speaker=voice,
                language=language or DEFAULT_LANGUAGE,
                chunk_size=DEFAULT_CHUNK_SIZE,
                max_new_tokens=DEFAULT_MAX_NEW_TOKENS,
            ):
                yield _to_pcm16_bytes(chunk)

    def synthesize(self, text: str, voice: str, language: str | None = None) -> bytes:
        return b"".join(self.synthesize_stream(text, voice, language))
