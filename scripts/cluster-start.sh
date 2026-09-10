#!/usr/bin/env bash
# Bring the cluster back into service after the nodes have rebooted (e.g.
# after ./scripts/cluster-stop.sh --poweroff, or any power cycle). kubelet
# and containerd are systemd-enabled on every node, so the control plane and
# kubelet come back on their own - this script waits for that, then
# uncordons workers, gives the nvidia device plugin a moment to re-probe the
# GPUs (skipping this is what caused the "no healthy devices" admission
# storm last time), sweeps up any zombie pods, and waits for the `speech`
# namespace Deployments to report healthy again.
#
# Usage: ./scripts/cluster-start.sh
#   Run this once all node machines are powered back on and reachable.
set -euo pipefail

NAMESPACE="${NAMESPACE:-speech}"
CONTROL_PLANE="${CONTROL_PLANE:-node0}"
WORKERS=(node1 node2 node3)
ALL_NODES=("${CONTROL_PLANE}" "${WORKERS[@]}")
READY_TIMEOUT=600
GPU_GRACE_SECONDS=30

echo "== waiting up to ${READY_TIMEOUT}s for all nodes to report Ready"
deadline=$(( $(date +%s) + READY_TIMEOUT ))
for n in "${ALL_NODES[@]}"; do
  until kubectl get node "$n" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
    if (( $(date +%s) > deadline )); then
      echo "error: node $n did not become Ready within ${READY_TIMEOUT}s" >&2
      exit 1
    fi
    echo "-- waiting on $n ..."
    sleep 5
  done
  echo "-- $n Ready"
done

echo "== uncordoning workers"
for n in "${WORKERS[@]}"; do
  kubectl uncordon "$n"
done

echo "== giving the nvidia device plugin ${GPU_GRACE_SECONDS}s to re-probe GPUs before anything schedules on them"
sleep "${GPU_GRACE_SECONDS}"
for n in "${WORKERS[@]}"; do
  gpu="$(kubectl get node "$n" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
  if [[ -z "$gpu" || "$gpu" == "0" ]]; then
    echo "warning: node $n reports no allocatable nvidia.com/gpu yet - GPU pods may fail to schedule. Check the device plugin pod on that node." >&2
  else
    echo "-- $n: nvidia.com/gpu=${gpu}"
  fi
done

echo "== sweeping up any zombie pods left over from the restart"
kubectl -n "${NAMESPACE}" get pods --no-headers 2>/dev/null \
  | awk '$3=="ContainerStatusUnknown" || $3=="UnexpectedAdmissionError" || $3=="Unknown" {print $1}' \
  | xargs -r -n 50 kubectl -n "${NAMESPACE}" delete pod --force --grace-period=0 --ignore-not-found=true

echo "== waiting for '${NAMESPACE}' Deployments to roll out"
for d in speech-llm speech-stt-tts speech-gateway speech-mcp searxng traefik speech-demo; do
  if kubectl -n "${NAMESPACE}" get deployment "$d" >/dev/null 2>&1; then
    kubectl -n "${NAMESPACE}" rollout status "deployment/${d}" --timeout=300s \
      || echo "warning: deployment/${d} did not become ready in time - check it manually" >&2
  fi
done

echo
echo "== final state"
kubectl -n "${NAMESPACE}" get pods -o wide
echo
echo "Done."
echo "  Browser UI:        https://<any-node-ip>:30443/  (accept the self-signed cert warning once per device)"
echo "  CLI / smoke test:  ws://<node1-ip>:30765/v1/realtime"
