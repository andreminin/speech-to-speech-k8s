# OpenAI-compatible STT wrapper around nano-parakeet (Parakeet-TDT).
# Same CUDA/cuDNN base as upstream speech-to-speech's own Dockerfile, since
# torch/nano-parakeet need cuDNN, not just the bare CUDA runtime.
#
# Build: docker build -t local-registry:5000/speech-stt:<tag> stt/
FROM local-registry:5000/cuda:12.9.1-cudnn-runtime-ubuntu24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY pyproject.toml ./
COPY app ./app
RUN pip3 install --no-cache-dir --break-system-packages .

ENV PYTHONUNBUFFERED=1 \
    STT_MODEL_NAME=nvidia/parakeet-tdt-0.6b-v3 \
    STT_DEVICE=cuda \
    HF_HOME=/mnt/models/parakeet

EXPOSE 8001

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8001"]
