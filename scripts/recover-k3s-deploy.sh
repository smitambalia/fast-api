#!/usr/bin/env bash
# Recover fast-api deploy when Hub is public but k3s is rate-limited (429).
# Imports the local Docker image into k3s, then restarts the Deployment.
set -euo pipefail

# Force local k3s — do NOT inherit ambient KUBECONFIG (often points at EKS).
# Override only via KUBECONFIG_PATH if you really need another cluster.
K3S_KUBECONFIG="${KUBECONFIG_PATH:-$HOME/.kube/k3s.yaml}"
if [[ ! -f "$K3S_KUBECONFIG" ]]; then
  echo "ERROR: k3s kubeconfig not found at $K3S_KUBECONFIG" >&2
  echo "Create it with: sudo cat /etc/rancher/k3s/k3s.yaml | sed \"s/127.0.0.1/$(hostname -I | awk '{print $1}')/\" > ~/.kube/k3s.yaml" >&2
  exit 1
fi
export KUBECONFIG="$K3S_KUBECONFIG"

IMAGE_REPO="${IMAGE_REPO:-smitambalia/n8n}"
TAG="${1:-ebb8452}"
FULL_IMAGE="${IMAGE_REPO}:${TAG}"
NS=fast-api
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Using kubeconfig: $KUBECONFIG"
if ! kubectl config current-context >/dev/null 2>&1; then
  echo "ERROR: cannot read context from $KUBECONFIG" >&2
  exit 1
fi
# Fail fast if this is not a reachable local cluster
if ! kubectl get nodes --request-timeout=8s >/dev/null 2>&1; then
  echo "ERROR: cannot reach cluster with $KUBECONFIG (is k3s running?)" >&2
  exit 1
fi
echo "==> Cluster nodes:"
kubectl get nodes --request-timeout=8s

echo "==> Import ${FULL_IMAGE} (+ latest) into k3s containerd (needs sudo)"
docker save "${FULL_IMAGE}" "${IMAGE_REPO}:latest" | sudo k3s ctr images import -

echo "==> Scale down / clean stuck pods"
kubectl -n "$NS" scale deployment/fast-api --replicas=0 --request-timeout=15s || true
kubectl -n "$NS" delete pods --all --force --grace-period=0 --request-timeout=15s 2>/dev/null || true
sleep 2

echo "==> Apply manifests and set image"
kubectl apply -f "${ROOT}/k8s/deployment.yaml" --request-timeout=30s
kubectl -n "$NS" set image deployment/fast-api "fast-api=${FULL_IMAGE}" --request-timeout=15s
kubectl -n "$NS" scale deployment/fast-api --replicas=1 --request-timeout=15s
kubectl -n "$NS" rollout status deployment/fast-api --timeout=120s

echo "==> Status"
kubectl -n "$NS" get pods,svc --request-timeout=15s
echo
curl -sS -m 5 "http://10.42.0.1:30081/health" || curl -sS -m 5 "http://127.0.0.1:30081/health" || true
echo
echo "Done."
