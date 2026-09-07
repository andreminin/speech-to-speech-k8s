from pydantic import BaseModel


class SpeechRequest(BaseModel):
    model: str | None = None
    input: str
    voice: str = "aiden"
    response_format: str = "pcm"  # "pcm" or "wav"
    sample_rate: int = 24_000
    language: str | None = None


class HealthResponse(BaseModel):
    status: str
    model_loaded: bool


class VoicesResponse(BaseModel):
    voices: list[str]
