#!/usr/bin/env bash
# Mirror public images this project depends on into the home-lab's private
# registry (local-registry:5000), so node1-node3 never need direct internet
# egress to pull them.
#
# Usage: ./scripts/mirror-images.sh [registry-host:port]
#
# Requires: docker (or podman) logged in to the private registry already
# (`docker login local-registry:5000`), and outbound internet access from
# THIS host (not from the cluster nodes) to pull the public images.
set -euo pipefail

REGISTRY="${1:-local-registry:5000}"

# name -> public image
declare -A IMAGES=(
  #[cuda-cudnn-runtime]="nvidia/cuda:12.9.1-cudnn-runtime-ubuntu24.04"
  #[cuda-base]="nvidia/cuda:12.9.1-base-ubuntu24.04"
  [llama-cpp-server-cuda]="ghcr.io/ggml-org/llama.cpp:server-cuda"
)

for local_name in "${!IMAGES[@]}"; do
  src="${IMAGES[$local_name]}"
  tag="${src##*:}"
  dest="${REGISTRY}/${local_name}:${tag}"
  echo "== ${src} -> ${dest}"
  docker pull "${src}"
  docker tag "${src}" "${dest}"
  docker push "${dest}"
done

echo
echo "Done. Update image references in gateway/, stt/, tts/ Dockerfiles and"
echo "k8s/llm/deployment.yaml to use these ${REGISTRY}/... tags if node1-node3"
echo "cannot reach the public internet directly."
