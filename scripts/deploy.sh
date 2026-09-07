#!/usr/bin/env bash
# Apply the k8s manifests in the order docs/deployment.md describes.
# Idempotent (kubectl apply) — safe to re-run after edits.
#
# Usage: ./scripts/deploy.sh [phase]
#   phase: all (default) | scaffolding | llm | stt | tts | gateway
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

stt() {
  echo "== speech-stt"
  kubectl apply -f "${K8S}/stt/deployment.yaml"
  kubectl apply -f "${K8S}/stt/service.yaml"
}

tts() {
  echo "== speech-tts"
  kubectl apply -f "${K8S}/tts/deployment.yaml"
  kubectl apply -f "${K8S}/tts/service.yaml"
}

gateway() {
  echo "== speech-gateway"
  kubectl apply -f "${K8S}/gateway/deployment.yaml"
  kubectl apply -f "${K8S}/gateway/service.yaml"
  kubectl apply -f "${K8S}/gateway/service-nodeport.yaml"
}

case "${PHASE}" in
  all) scaffolding; llm; stt; tts; gateway ;;
  scaffolding) scaffolding ;;
  llm) llm ;;
  stt) stt ;;
  tts) tts ;;
  gateway) gateway ;;
  *) echo "unknown phase: ${PHASE}" >&2; exit 1 ;;
esac
