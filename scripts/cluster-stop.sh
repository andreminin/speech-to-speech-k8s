#!/usr/bin/env bash
# Safely quiesce the cluster before powering the nodes off (planned reboot,
# maintenance, etc). Cordons + drains every worker so Deployments scale down
# cleanly instead of being force-evicted later by NodeNotReady taints -
# that's what caused the zombie-pod pile-up in the `speech` namespace
# (500+ ContainerStatusUnknown pods, nvidia.com/gpu "no healthy devices"
# storm) after a previous ungraceful node loss. Draining first avoids that.
#
# By default this only cordons/drains - it does NOT power anything off.
# Pass --poweroff to also run `sudo shutdown -h now` over SSH on every node
# (workers first, control-plane last). None of the nodes have passwordless
# sudo configured, so you'll be prompted for the sudo password per node.
#
# Usage: ./scripts/cluster-stop.sh [--poweroff] [--yes] [--skip-snapshot]
#   --poweroff       also power off every node via SSH once drained
#   --yes            skip the confirmation prompt (only relevant with --poweroff)
#   --skip-snapshot  skip the best-effort etcd snapshot on the control-plane node
set -euo pipefail

NAMESPACE="${NAMESPACE:-speech}"
CONTROL_PLANE="${CONTROL_PLANE:-node0}"
WORKERS=(node1 node2 node3)

POWEROFF=false
CONFIRM=false
SKIP_SNAPSHOT=false

for arg in "$@"; do
  case "$arg" in
    --poweroff) POWEROFF=true ;;
    --yes) CONFIRM=true ;;
    --skip-snapshot) SKIP_SNAPSHOT=true ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if ! $SKIP_SNAPSHOT; then
  echo "== best-effort etcd snapshot on ${CONTROL_PLANE} (you may be prompted for the sudo password)"
  ts="$(date +%F-%H%M%S)"
  ssh -t "${CONTROL_PLANE}" "sudo ETCDCTL_API=3 etcdctl snapshot save /var/backups/etcd-snapshot-${ts}.db \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key" \
    || echo "warning: etcd snapshot failed or was skipped - continuing anyway" >&2
fi

echo "== cordoning workers"
for n in "${WORKERS[@]}"; do
  kubectl cordon "$n"
done

echo "== draining workers"
for n in "${WORKERS[@]}"; do
  echo "-- draining $n"
  kubectl drain "$n" --ignore-daemonsets --delete-emptydir-data --force --timeout=180s
done

echo
echo "== drained. Current '${NAMESPACE}' namespace state:"
kubectl -n "${NAMESPACE}" get pods -o wide

if ! $POWEROFF; then
  cat <<EOF

Nodes are cordoned + drained but still powered on. Power the machines off
yourself now, or re-run this script with --poweroff to do it from here.
EOF
  exit 0
fi

if ! $CONFIRM; then
  cat <<EOF

This will run 'sudo shutdown -h now' over SSH on: ${WORKERS[*]}, then ${CONTROL_PLANE}.
You'll be prompted for the sudo password on each node.
EOF
  read -rp "Type 'yes' to continue: " reply
  [[ "${reply}" == "yes" ]] || { echo "Aborted (nodes remain drained, not powered off)."; exit 1; }
fi

echo "== powering off workers"
for n in "${WORKERS[@]}"; do
  echo "-- $n"
  ssh -t "$n" 'sudo shutdown -h now' || echo "warning: could not confirm shutdown on $n" >&2
done

echo "== powering off control-plane (${CONTROL_PLANE}) last"
ssh -t "${CONTROL_PLANE}" 'sudo shutdown -h now' || echo "warning: could not confirm shutdown on ${CONTROL_PLANE}" >&2

echo "Done. All nodes told to power off. Use ./scripts/cluster-start.sh once they're back up."
