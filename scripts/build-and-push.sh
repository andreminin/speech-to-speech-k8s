#!/usr/bin/env bash
# Build and push speech-gateway, speech-stt, speech-tts to the private
# registry. speech-llm has no custom image — see llm/README.md and
# scripts/mirror-images.sh instead.
#
# Usage:
#   ./scripts/build-and-push.sh <tag> [path-to-speech-to-speech-checkout]
#
# The gateway image builds FROM a checkout of huggingface/speech-to-speech
# (defaults to ../speech-to-speech, matching this repo's
# usual sibling layout) since it just packages upstream's own Dockerfile
# context — no code of ours goes into that image.
set -euo pipefail

TAG="${1:?usage: build-and-push.sh <tag> [speech-to-speech-checkout-path]}"
UPSTREAM_CHECKOUT="${2:-../speech-to-speech}"
REGISTRY="${REGISTRY:-local-registry:5000}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== speech-stt"
docker build -t "${REGISTRY}/speech-stt:${TAG}" "${ROOT_DIR}/stt"
docker push "${REGISTRY}/speech-stt:${TAG}"

echo "== speech-tts"
docker build -t "${REGISTRY}/speech-tts:${TAG}" "${ROOT_DIR}/tts"
docker push "${REGISTRY}/speech-tts:${TAG}"

echo "== speech-mcp"
docker build -t "${REGISTRY}/speech-mcp:${TAG}" "${ROOT_DIR}/speech-mcp"
docker push "${REGISTRY}/speech-mcp:${TAG}"

echo "== speech-gateway (build context: ${UPSTREAM_CHECKOUT})"
if [[ ! -d "${UPSTREAM_CHECKOUT}" ]]; then
  echo "error: ${UPSTREAM_CHECKOUT} not found — pass the path to a" >&2
  echo "checkout of https://github.com/andreminin/speech-to-speech as the" >&2
  echo "second argument." >&2
  exit 1
fi
docker build -f "${ROOT_DIR}/gateway/Dockerfile" -t "${REGISTRY}/speech-gateway:${TAG}" "${UPSTREAM_CHECKOUT}"
docker push "${REGISTRY}/speech-gateway:${TAG}"

echo "== speech-demo (build context: ${UPSTREAM_CHECKOUT}/demo)"
if [[ ! -d "${UPSTREAM_CHECKOUT}/demo" ]]; then
  echo "error: ${UPSTREAM_CHECKOUT}/demo not found — pass the path to a" >&2
  echo "checkout of https://github.com/andreminin/speech-to-speech as the" >&2
  echo "second argument." >&2
  exit 1
fi
# demo/Dockerfile here is a patched copy of upstream's own (see the file's
# header comment) — main context is still the checkout's demo/ dir, not
# vendored; server.py/main.js are overridden from this repo's own vendored,
# patched copies (the /api/mcp/call proxy) via a second, named build context.
docker build -f "${ROOT_DIR}/demo/Dockerfile" -t "${REGISTRY}/speech-demo:${TAG}" \
  --build-context "patches=${ROOT_DIR}/demo" \
  "${UPSTREAM_CHECKOUT}/demo"
docker push "${REGISTRY}/speech-demo:${TAG}"

echo
echo "Pushed ${REGISTRY}/{speech-stt,speech-tts,speech-mcp,speech-gateway,speech-demo}:${TAG}"
echo "Update the image: tags in k8s/*/deployment.yaml to match if not using 'latest'."
echo "(searxng is a third-party image - see scripts/mirror-images.sh instead.)"
