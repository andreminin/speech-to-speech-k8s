"""Thin wrapper around nano-parakeet, mirroring how upstream speech-to-speech
itself drives the model (src/speech_to_speech/STT/parakeet_tdt_handler.py):

    from nano_parakeet import from_pretrained
    model = from_pretrained(model_name=..., device=...)
    text = model.transcribe(audio_array).strip()

nano-parakeet is not confirmed thread-safe under concurrent calls, and
upstream only ever calls it from a single pipeline thread — so this wrapper
serializes all inference through one lock rather than assuming safety.
"""
from __future__ import annotations

import io
import logging
import threading

import numpy as np
import soundfile as sf

logger = logging.getLogger("speech-stt")

DEFAULT_MODEL_NAME = "nvidia/parakeet-tdt-0.6b-v3"
TARGET_SAMPLE_RATE = 16_000


class ParakeetSTT:
    def __init__(self, model_name: str = DEFAULT_MODEL_NAME, device: str = "cuda") -> None:
        self.model_name = model_name
        self.device = device
        self._model = None
        self._lock = threading.Lock()

    def load(self) -> None:
        from nano_parakeet import from_pretrained

        logger.info("loading %s on %s", self.model_name, self.device)
        self._model = from_pretrained(model_name=self.model_name, device=self.device)

        # Warm up CUDA kernels / cuDNN autotune before serving real traffic,
        # matching upstream's own _setup_nano_parakeet warm-up pattern.
        dummy_audio = np.zeros(TARGET_SAMPLE_RATE, dtype=np.float32)
        with self._lock:
            self._model.transcribe(dummy_audio)
        logger.info("model warm-up complete")

    @property
    def is_loaded(self) -> bool:
        return self._model is not None

    def decode_wav(self, wav_bytes: bytes) -> np.ndarray:
        audio, sample_rate = sf.read(io.BytesIO(wav_bytes), dtype="float32", always_2d=False)
        if audio.ndim > 1:
            audio = audio.mean(axis=1)
        if sample_rate != TARGET_SAMPLE_RATE:
            # Gateway always sends 16kHz per the contract; resample only
            # defensively if a client ever violates that.
            import librosa

            audio = librosa.resample(audio, orig_sr=sample_rate, target_sr=TARGET_SAMPLE_RATE)
        return audio.astype(np.float32)

    def transcribe(self, audio: np.ndarray) -> str:
        if self._model is None:
            raise RuntimeError("model not loaded")
        with self._lock:
            return self._model.transcribe(audio).strip()
