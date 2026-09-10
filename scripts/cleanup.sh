#!/usr/bin/env bash
# Tear down everything this project deploys: the `speech` namespace (every
# Deployment/Service/ConfigMap/Secret/Ingress in it - Traefik included,
# since it's deployed into that namespace too, see k8s/traefik/deployment.yaml's
# header comment) plus Traefik's cluster-scoped RBAC and IngressClass, which
# namespace deletion does not remove.
#
# Does NOT touch node-local state: model caches under /mnt/local-fast on
# node1-node3 (hostPath, not a k8s object) survive this, so re-running
# scripts/install.sh afterwards won't need to re-download any models.
#
# Usage: ./scripts/cleanup.sh [--yes]
#   --yes   skip the confirmation prompt (for scripting)
set -euo pipefail

NAMESPACE="${NAMESPACE:-speech}"
CONFIRM="${1:-}"

if [[ "${CONFIRM}" != "--yes" ]]; then
  cat <<EOF
This will delete:
  - the '${NAMESPACE}' namespace, and everything in it (Deployments,
    Services, ConfigMaps, Secrets incl. local-registry-cred and
    speech-demo-tls, the Ingress, Traefik's Deployment)
  - the cluster-scoped 'traefik' ClusterRole, ClusterRoleBinding, and
    IngressClass (namespace deletion doesn't remove these)

NOT touched: node-local model caches under /mnt/local-fast on node1-node3.

EOF
  read -rp "Type 'yes' to continue: " reply
  [[ "${reply}" == "yes" ]] || { echo "Aborted."; exit 1; }
fi

echo "== deleting namespace '${NAMESPACE}' (and everything in it)"
kubectl delete namespace "${NAMESPACE}" --ignore-not-found

echo "== deleting cluster-scoped Traefik resources"
kubectl delete clusterrolebinding traefik --ignore-not-found
kubectl delete clusterrole traefik --ignore-not-found
kubectl delete ingressclass traefik --ignore-not-found

echo
echo "Done. To redeploy: ./scripts/create-registry-secret.sh then ./scripts/install.sh"
