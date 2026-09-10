# syntax=docker/dockerfile:1.7
# Browser voice-chat UI - patched copy of upstream huggingface/speech-to-speech's
# own demo/Dockerfile (not our code; see k8s/demo/deployment.yaml). Only this
# Dockerfile is vendored here, not the rest of demo/ (JS/Python/HTML app
# code stays in the upstream checkout, fetched fresh each build) - matches
# the same "thin wrapper, build context is the upstream checkout" pattern
# as gateway/Dockerfile, just pointed at the demo/ subfolder instead of the
# checkout root:
#   docker build -f demo/Dockerfile -t local-registry:5000/speech-demo:<tag> \
#     --build-context patches=demo /path/to/speech-to-speech-checkout/demo
#
# Two changes from upstream's own Dockerfile:
#   1. The original never copies .npmrc before `npm ci`, so it falls back to
#      the lockfile's `resolved` URLs, which point at an HF-internal npm
#      mirror (npm.registries.huggingface.tech) unreachable outside HF's own
#      build infra. .npmrc's own `replace-registry-host=always` is the
#      intended fix for exactly this - it just needs to actually be present
#      during `npm ci`. Filed upstream as something to fix there too; this
#      local patch unblocks building it here in the meantime.
#   2. server.py/main.js are overridden from this repo's own vendored,
#      patched copies (the /api/mcp/call proxy - see their header comments)
#      via a second, named build context ("patches", passed with
#      --build-context above and pointed at this repo's demo/ dir by
#      scripts/build-and-push.sh) rather than the main context (the upstream
#      checkout), which still supplies every other app file unmodified.
FROM local-registry:5000/node:24-slim AS agents-sdk

WORKDIR /sdk
COPY package.json package-lock.json .npmrc ./
RUN npm ci --omit=dev

# Single runtime container: serves the static front-end AND API proxies.
# HF Spaces (sdk: docker) routes traffic to $PORT, default 7860.
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
COPY --from=agents-sdk /sdk/node_modules/@openai/agents-realtime/dist/bundle/openai-realtime-agents.umd.js /app/vendor/openai-realtime-agents.umd.js
COPY --from=patches server.py main.js ./

EXPOSE 7860

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "7860"]
