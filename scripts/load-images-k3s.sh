#!/usr/bin/env bash
# Load local Docker images into k3s containerd (requires sudo).
set -euo pipefail
TAG="${1:-local}"
API_IMAGE_REPO="${API_IMAGE_REPO:-smitambalia/n8n}"
WEB_IMAGE_REPO="${WEB_IMAGE_REPO:-smitambalia/fast-web}"

images=(
  "${API_IMAGE_REPO}:${TAG}"
  "${API_IMAGE_REPO}:latest"
  "${WEB_IMAGE_REPO}:${TAG}"
  "${WEB_IMAGE_REPO}:latest"
)

echo "Importing: ${images[*]}"
docker save "${images[@]}" | sudo k3s ctr images import -
echo "Done. Restart deployments if needed:"
echo "  export KUBECONFIG=~/.kube/k3s.yaml"
echo "  kubectl -n fast-api rollout restart deploy/fast-api deploy/fast-web"
