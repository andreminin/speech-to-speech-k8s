#!/usr/bin/env bash
# Record peak VRAM for a running component, for the benchmark matrix in
# docs/benchmarks.md.
#
# Usage: ./scripts/record-vram.sh <pod-name> [container-name]
set -euo pipefail

NAMESPACE="${NAMESPACE:-speech}"
POD="${1:?usage: record-vram.sh <pod-name> [container-name]}"
CONTAINER="${2:-}"

ARGS=(-n "${NAMESPACE}" exec "${POD}")
if [[ -n "${CONTAINER}" ]]; then
  ARGS+=(-c "${CONTAINER}")
fi
ARGS+=(-- nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv)

kubectl "${ARGS[@]}"
