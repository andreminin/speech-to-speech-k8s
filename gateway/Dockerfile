# Packages upstream huggingface/speech-to-speech as-is. No pipeline code of
# our own here — this container just runs `speech-to-speech serve` pointed
# at the remote speech-stt / speech-llm / speech-tts services via upstream's
# own OpenAI-compatible client flags (see k8s/gateway/deployment.yaml).
#
# Build context must be a checkout of https://github.com/huggingface/speech-to-speech
# at the revision you want to pin, e.g.:
#   docker build -f gateway/Dockerfile -t local-registry:5000/speech-gateway:<tag> \
#     /path/to/speech-to-speech-checkout
FROM local-registry:5000/cuda:12.9.1-cudnn-runtime-ubuntu24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git libportaudio2 libsndfile1 \
    python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --break-system-packages uv

WORKDIR /app
COPY pyproject.toml README.md LICENSE MANIFEST.in ./
RUN uv sync --python /usr/bin/python3 --no-install-project --no-dev
COPY . .
RUN uv sync --python /usr/bin/python3 --no-dev
RUN /app/.venv/bin/python -c "import nltk; nltk.download('punkt_tab'); nltk.download('averaged_perceptron_tagger_eng')"

ENV PATH="/app/.venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1

EXPOSE 8765

ENTRYPOINT ["speech-to-speech"]
CMD ["serve", "--host", "0.0.0.0", "--port", "8765"]
