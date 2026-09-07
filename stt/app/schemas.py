from pydantic import BaseModel


class TranscriptionResponse(BaseModel):
    text: str
    language: str | None = None


class HealthResponse(BaseModel):
    status: str
    model_loaded: bool
