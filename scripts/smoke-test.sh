#!/usr/bin/env bash
# Per-service smoke tests for Phases B/C/D. Run via kubectl port-forward so
# it works from outside the cluster too.
#
# Usage: ./scripts/smoke-test.sh <llm|stt|tts> [args]
set -euo pipefail

NAMESPACE="${NAMESPACE:-speech}"
CMD="${1:-}"
shift || true

pf() {
  local svc="$1" local_port="$2" remote_port="$3"
  # Redirect stdout/stderr so this long-running background process doesn't
  # inherit the pipe backing `pid=$(pf ...)` — otherwise that command
  # substitution blocks forever waiting for EOF that never comes.
  kubectl -n "${NAMESPACE}" port-forward "svc/${svc}" "${local_port}:${remote_port}" >/dev/null 2>&1 &
  local pid=$!
  sleep 2
  echo "${pid}"
}

case "${CMD}" in
  llm)
    pid=$(pf speech-llm 18080 8080)
    trap 'kill "${pid}" 2>/dev/null || true' EXIT
    echo "-- /health"
    curl -sf http://localhost:18080/health
    echo
    echo "-- chat completion"
    curl -sf http://localhost:18080/v1/chat/completions \
      -H 'Content-Type: application/json' \
      -d '{"model":"local","messages":[{"role":"user","content":"Say hello in five words."}]}'
    echo
    ;;
  stt)
    wav_file="${1:?usage: smoke-test.sh stt <path-to-16khz-mono-wav>}"
    pid=$(pf speech-stt 18001 8001)
    trap 'kill "${pid}" 2>/dev/null || true' EXIT
    curl -sf -F "file=@${wav_file}" http://localhost:18001/v1/audio/transcriptions
    echo
    ;;
  tts)
    text="${1:-hello from the home lab}"
    out="${2:-/tmp/speech-tts-smoke.pcm}"
    pid=$(pf speech-tts 18002 8002)
    trap 'kill "${pid}" 2>/dev/null || true' EXIT
    curl -sf -X POST http://localhost:18002/v1/audio/speech \
      -H 'Content-Type: application/json' \
      -d "{\"input\": \"${text}\", \"voice\": \"aiden\", \"response_format\": \"wav\"}" \
      --output "${out}"
    echo "wrote ${out} ($(wc -c < "${out}") bytes) — play with: aplay ${out} (or any WAV player)"
    ;;
  *)
    echo "usage: $0 <llm|stt|tts> [args]" >&2
    exit 1
    ;;
esac
