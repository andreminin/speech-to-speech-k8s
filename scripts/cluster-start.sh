#!/usr/bin/env bash
# Bring the cluster back into service after the nodes have rebooted (e.g.
# after ./scripts/cluster-stop.sh --poweroff, or any power cycle). kubelet
# and containerd are systemd-enabled on every node, so the control plane and
# kubelet come back on their own - this script waits for that, then
# uncordons workers, restores every Deployment that cluster-stop.sh scaled
# to 0 (reading back the replica count it saved as an annotation), and waits
# for rollouts.
#
# GPU-requesting Deployments (anything with a nvidia.com/gpu resource
# request, detected automatically - currently speech-llm and
# speech-stt-tts) are held at 0 until the nvidia device plugin reports
# actually healthy on every worker node. This is the other half of what
# prevents the zombie-pod churn seen previously: cluster-stop.sh ensures no
# pod object exists while the nodes are down, and this script makes sure we
# don't recreate GPU pods before the device plugin has re-registered
# healthy devices post-boot - scheduling onto a node whose GPU isn't
# actually ready yet is what produced the "no healthy devices present"
# admission-error storm. Non-GPU Deployments don't need to wait for this and
# are restored right after uncordon.
#
# Usage: ./scripts/cluster-start.sh
#   Run this once all node machines are powered back on and reachable.
set -euo pipefail

NAMESPACE="${NAMESPACE:-speech}"
CONTROL_PLANE="${CONTROL_PLANE:-node0}"
WORKERS=(node1 node2 node3)
ALL_NODES=("${CONTROL_PLANE}" "${WORKERS[@]}")
REPLICAS_ANNOTATION="speech.cluster/prev-replicas"
READY_TIMEOUT=600
GPU_PLUGIN_TIMEOUT=180
GPU_PLUGIN_LABEL="name=nvidia-device-plugin-ds"
GPU_PLUGIN_NAMESPACE="kube-system"

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

echo "== restoring Deployments"
mapfile -t DEPLOYMENTS < <(kubectl -n "${NAMESPACE}" get deployments -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
GPU_DEPLOYMENTS=()
OTHER_DEPLOYMENTS=()
for d in "${DEPLOYMENTS[@]}"; do
  gpu_req="$(kubectl -n "${NAMESPACE}" get deployment "$d" -o jsonpath='{.spec.template.spec.containers[*].resources.requests.nvidia\.com/gpu}')"
  if [[ -n "${gpu_req// }" ]]; then
    GPU_DEPLOYMENTS+=("$d")
  else
    OTHER_DEPLOYMENTS+=("$d")
  fi
done

restore() {
  local d="$1"
  local want
  want="$(kubectl -n "${NAMESPACE}" get deployment "$d" -o jsonpath="{.metadata.annotations['${REPLICAS_ANNOTATION//./\\.}']}" 2>/dev/null || true)"
  want="${want:-1}"
  echo "-- ${d}: restoring to ${want} replica(s)"
  kubectl -n "${NAMESPACE}" scale deployment "$d" --replicas="${want}" >/dev/null
}

if [[ ${#OTHER_DEPLOYMENTS[@]} -gt 0 ]]; then
  echo "-- non-GPU Deployments (restoring now): ${OTHER_DEPLOYMENTS[*]}"
  for d in "${OTHER_DEPLOYMENTS[@]}"; do restore "$d"; done
fi

if [[ ${#GPU_DEPLOYMENTS[@]} -gt 0 ]]; then
  echo "-- GPU Deployments (held at 0 until the device plugin is healthy): ${GPU_DEPLOYMENTS[*]}"
  echo "== waiting up to ${GPU_PLUGIN_TIMEOUT}s for the nvidia device plugin to be Ready on every worker"
  deadline=$(( $(date +%s) + GPU_PLUGIN_TIMEOUT ))
  for n in "${WORKERS[@]}"; do
    while true; do
      ready="$(kubectl -n "${GPU_PLUGIN_NAMESPACE}" get pods -l "${GPU_PLUGIN_LABEL}" \
        --field-selector "spec.nodeName=${n}" \
        -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)"
      gpu_alloc="$(kubectl get node "$n" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)"
      if [[ "${ready}" == "true" && -n "${gpu_alloc}" && "${gpu_alloc}" != "0" ]]; then
        echo "-- ${n}: device plugin Ready, nvidia.com/gpu=${gpu_alloc}"
        break
      fi
      if (( $(date +%s) > deadline )); then
        echo "warning: nvidia device plugin on ${n} not confirmed healthy within ${GPU_PLUGIN_TIMEOUT}s (ready=${ready:-?} gpu=${gpu_alloc:-?}) - restoring GPU Deployments anyway, watch for admission errors" >&2
        break
      fi
      sleep 3
    done
  done
  for d in "${GPU_DEPLOYMENTS[@]}"; do restore "$d"; done
fi

echo "== waiting for '${NAMESPACE}' Deployments to roll out"
for d in "${DEPLOYMENTS[@]}"; do
  kubectl -n "${NAMESPACE}" rollout status "deployment/${d}" --timeout=300s \
    || echo "warning: deployment/${d} did not become ready in time - check it manually" >&2
done

echo "== checking for any unexpected leftover pods (should be none)"
leftover="$(kubectl -n "${NAMESPACE}" get pods --no-headers 2>/dev/null \
  | awk '$3=="ContainerStatusUnknown" || $3=="UnexpectedAdmissionError" || $3=="Unknown" {print $1}')"
if [[ -n "${leftover}" ]]; then
  echo "warning: unexpected zombie pod(s) found, force-deleting:" >&2
  echo "${leftover}" | xargs -r -n 50 kubectl -n "${NAMESPACE}" delete pod --force --grace-period=0 --ignore-not-found=true
else
  echo "  none found"
fi

echo
echo "== final state"
kubectl -n "${NAMESPACE}" get pods -o wide
echo
echo "Done."
echo "  Browser UI:        https://<any-node-ip>:30443/  (accept the self-signed cert warning once per device)"
echo "  CLI / smoke test:  ws://<node1-ip>:30765/v1/realtime"
