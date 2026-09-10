#!/usr/bin/env bash
# Apply the k8s manifests in the order docs/deployment.md describes.
# Idempotent (kubectl apply) — safe to re-run after edits.
#
# Usage: ./scripts/deploy.sh [phase]
#   phase: all (default) | scaffolding | llm | stt | tts | gateway | traefik | demo | searxng | speech_mcp
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
K8S="${ROOT_DIR}/k8s"
PHASE="${1:-all}"

scaffolding() {
  echo "== namespace + storage + configmaps"
  kubectl apply -f "${K8S}/namespace.yaml"
  kubectl apply -f "${K8S}/storage/storageclass-local.yaml"
  kubectl apply -f "${K8S}/storage/pv-models-node2.yaml"
  kubectl apply -f "${K8S}/storage/pv-models-node3.yaml"
  kubectl apply -f "${K8S}/configmaps/"
  echo "NOTE: run scripts/create-registry-secret.sh separately before this if you haven't yet."
}

llm() {
  echo "== speech-llm"
  kubectl apply -f "${K8S}/llm/deployment.yaml"
  kubectl apply -f "${K8S}/llm/service.yaml"
}

# node3 has one GPU and can't co-schedule two separate GPU-requesting
# Deployments (see docs/architecture.md "GPU scheduling constraint") - the
# actual running setup is the colocated manifest (one Pod, two containers),
# NOT the standalone k8s/stt/deployment.yaml + k8s/tts/deployment.yaml
# (kept in the repo only as a reference/fallback - see that manifest's own
# header comment). `stt` and `tts` are both aliases for the same colocated
# apply so existing muscle-memory/docs referencing either still work.
stt_tts() {
  echo "== speech-stt + speech-tts (colocated on node3)"
  kubectl apply -f "${K8S}/stt/deployment-colocated-with-tts.yaml"
}
stt() { stt_tts; }
tts() { stt_tts; }

gateway() {
  echo "== speech-gateway"
  kubectl apply -f "${K8S}/gateway/deployment.yaml"
  kubectl apply -f "${K8S}/gateway/service.yaml"
  kubectl apply -f "${K8S}/gateway/service-nodeport.yaml"
}

traefik() {
  echo "== traefik (ingress controller)"
  kubectl apply -f "${K8S}/traefik/deployment.yaml"
  kubectl apply -f "${K8S}/traefik/ingress.yaml"
}

demo() {
  echo "== speech-demo (browser voice-chat UI)"
  kubectl apply -f "${K8S}/demo/deployment.yaml"
}

# searxng backs speech-mcp's global_internet_search tool - deploy it
# first so speech-mcp's readiness check has something to find.
searxng() {
  echo "== searxng (self-hosted search backend for speech-mcp)"
  kubectl apply -f "${K8S}/searxng/configmap.yaml"
  kubectl apply -f "${K8S}/searxng/deployment.yaml"
}

speech_mcp() {
  echo "== speech-mcp (experimental MCP server - PoC, not yet gateway-wired)"
  kubectl apply -f "${K8S}/speech-mcp/deployment.yaml"
}

case "${PHASE}" in
  all) scaffolding; llm; stt_tts; gateway; traefik; demo; searxng; speech_mcp ;;
  scaffolding) scaffolding ;;
  llm) llm ;;
  stt|tts|stt_tts) stt_tts ;;
  gateway) gateway ;;
  traefik) traefik ;;
  demo) demo ;;
  searxng) searxng ;;
  speech_mcp|speech-mcp|mcp) speech_mcp ;;
  *) echo "unknown phase: ${PHASE}" >&2; exit 1 ;;
esac
