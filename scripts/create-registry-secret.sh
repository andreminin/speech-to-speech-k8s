#!/usr/bin/env bash
# Create the imagePullSecret every pod in the `speech` namespace references
# (`local-registry-cred`). Never hardcode credentials here or anywhere in
# this repo — this script reads them from your shell environment or prompts
# interactively, and nothing it does gets committed.
#
# Usage:
#   REGISTRY_USER=docker-agent REGISTRY_PASSWORD=... ./scripts/create-registry-secret.sh
# or, to be prompted instead of using env vars:
#   ./scripts/create-registry-secret.sh
set -euo pipefail

REGISTRY_HOST="${REGISTRY_HOST:-local-registry:5000}"
NAMESPACE="${NAMESPACE:-speech}"
SECRET_NAME="${SECRET_NAME:-local-registry-cred}"

if [[ -z "${REGISTRY_USER:-}" ]]; then
  read -rp "Registry username: " REGISTRY_USER
fi
if [[ -z "${REGISTRY_PASSWORD:-}" ]]; then
  read -rsp "Registry password: " REGISTRY_PASSWORD
  echo
fi

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret docker-registry "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --docker-server="${REGISTRY_HOST}" \
  --docker-username="${REGISTRY_USER}" \
  --docker-password="${REGISTRY_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

unset REGISTRY_PASSWORD

echo "Secret ${SECRET_NAME} created/updated in namespace ${NAMESPACE}."
