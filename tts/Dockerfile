# OpenAI-compatible TTS wrapper around faster-qwen3-tts (Qwen3-TTS).
# Same CUDA/cuDNN base as upstream speech-to-speech's own Dockerfile.
#
# Build: docker build -t local-registry:5000/speech-tts:<tag> tts/
FROM nvidia/cuda:12.8.1-cudnn-runtime-ubuntu24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY pyproject.toml ./
COPY app ./app
RUN pip3 install --no-cache-dir --break-system-packages .

ENV PYTHONUNBUFFERED=1 \
    TTS_MODEL_NAME=Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice \
    TTS_DEVICE=cuda \
    TTS_BACKEND=ggml \
    TTS_VOICES=aiden \
    HF_HOME=/mnt/models/qwen3-tts

EXPOSE 8002

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8002"]
