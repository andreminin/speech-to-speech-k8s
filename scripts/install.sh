#!/usr/bin/env bash
# One-shot installer for the current speech-to-speech-k8s setup: applies
# every k8s manifest (via deploy.sh), waits for rollouts, and prints the
# access URLs. This is the "bring the cluster up to match what's documented
# in docs/deployment.md's Status section" script.
#
# Prerequisites this does NOT handle (see docs/deployment.md for each):
#   - Cluster health (kubectl get nodes all Ready) - Phase A0.
#   - local-registry-cred Secret - run scripts/create-registry-secret.sh once.
#   - Application images already built/pushed to local-registry:5000
#     (speech-stt, speech-tts, speech-llm's public image mirrored,
#     speech-gateway, speech-demo) - see scripts/build-and-push.sh and
#     "Prerequisite: upstream checkout" in docs/deployment.md. Model
#     weights pre-downloaded onto each node's /mnt/local-fast (Phases B/C).
#   - Traefik's image mirrored - see the `traefik` entry in
#     scripts/mirror-images.sh.
#   - The self-signed TLS secret for the browser demo (checked below;
#     prints the exact command if missing).
#
# Usage: ./scripts/install.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-speech}"

echo "== checking prerequisites"
if ! kubectl get secret local-registry-cred -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "warning: Secret local-registry-cred not found in namespace '${NAMESPACE}'." >&2
  echo "  Run ./scripts/create-registry-secret.sh first (it also creates the namespace)." >&2
fi

echo "== applying manifests"
"${ROOT_DIR}/scripts/deploy.sh" all

echo
echo "== waiting for rollouts"
kubectl -n "${NAMESPACE}" rollout status deployment/speech-llm --timeout=180s
kubectl -n "${NAMESPACE}" rollout status deployment/speech-stt-tts --timeout=300s
kubectl -n "${NAMESPACE}" rollout status deployment/speech-gateway --timeout=180s
kubectl -n "${NAMESPACE}" rollout status deployment/traefik --timeout=60s
kubectl -n "${NAMESPACE}" rollout status deployment/speech-demo --timeout=60s

echo
if ! kubectl get secret speech-demo-tls -n "${NAMESPACE}" >/dev/null 2>&1; then
  cat <<'EOF'
No speech-demo-tls Secret found - the browser demo needs HTTPS for
microphone access. Generate a self-signed cert (SANs for every node IP
users might browse to) and load it, then re-run this script or just
re-apply the Ingress:

  openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
    -keyout tls.key -out tls.crt -subj "/CN=speech-demo.local" \
    -addext "subjectAltName=IP:192.168.10.30,IP:192.168.10.31,IP:192.168.10.32,IP:192.168.10.33,DNS:speech-demo.local"
  kubectl -n speech create secret tls speech-demo-tls --cert=tls.crt --key=tls.key
  kubectl apply -f k8s/traefik/ingress.yaml

EOF
fi

echo "Done."
echo "  Browser UI:        https://<any-node-ip>:30443/  (accept the self-signed cert warning once per device)"
echo "  CLI / smoke test:  ws://<node1-ip>:30765/v1/realtime"
echo "  Verify:            kubectl -n ${NAMESPACE} get pods -o wide"
