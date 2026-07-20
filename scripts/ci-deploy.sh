#!/usr/bin/env bash
# Host-side CI: pull → docker build (api + web) → push Docker Hub → deploy to k3s
# Called by n8n over SSH. Do NOT put secrets in this file.
set -euo pipefail

# ---------- config (override via env) ----------
REPO_DIR="${REPO_DIR:-/home/yashree/development/fast-api}"
API_DIR="${API_DIR:-${REPO_DIR}/apps/api}"
WEB_DIR="${WEB_DIR:-${REPO_DIR}/apps/web}"
# API image (existing Hub repo)
API_IMAGE_REPO="${API_IMAGE_REPO:-${IMAGE_REPO:-smitambalia/n8n}}"
# Web image
WEB_IMAGE_REPO="${WEB_IMAGE_REPO:-smitambalia/fast-web}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/k3s.yaml}"
K8S_NAMESPACE="${K8S_NAMESPACE:-fast-api}"
BRANCH="${BRANCH:-main}"
GIT_SHA="${GIT_SHA:-}"
NOTIFY_STATUS_FILE="${NOTIFY_STATUS_FILE:-/tmp/fastapi-ci-last.json}"
IMPORT_TO_K3S="${IMPORT_TO_K3S:-1}"
PULL_SECRET_NAME="${PULL_SECRET_NAME:-dockerhub-cred}"
# Deploy both apps (set DEPLOY_WEB=0 to skip frontend)
DEPLOY_API="${DEPLOY_API:-1}"
DEPLOY_WEB="${DEPLOY_WEB:-1}"

log() { echo "[ci-deploy $(date -Is)] $*"; }

cleanup_status() {
  local ok="$1"
  local msg="$2"
  cat >"$NOTIFY_STATUS_FILE" <<EOF
{"ok": ${ok}, "message": $(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), "api_image": "${API_IMAGE_REPO}:${TAG:-unknown}", "web_image": "${WEB_IMAGE_REPO}:${TAG:-unknown}", "time": "$(date -Is)"}
EOF
}

trap 'cleanup_status false "failed at line $LINENO"' ERR

# ---------- resolve tag ----------
if [[ -z "$GIT_SHA" ]]; then
  GIT_SHA="$(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo manual)"
fi
TAG="${GIT_SHA}"

log "Starting CI deploy (api=${DEPLOY_API} web=${DEPLOY_WEB})"
log "REPO_DIR=$REPO_DIR tag=$TAG branch=$BRANCH"

# ---------- git pull ----------
cd "$REPO_DIR"
if [[ -d .git ]]; then
  log "Fetching latest git..."
  git fetch --all --prune
  if git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; then
    git checkout "$BRANCH"
    git pull --ff-only origin "$BRANCH"
  else
    log "Branch origin/${BRANCH} not found; using current HEAD"
  fi
  GIT_SHA="$(git rev-parse --short HEAD)"
  TAG="$GIT_SHA"
fi

API_IMAGE="${API_IMAGE_REPO}:${TAG}"
API_LATEST="${API_IMAGE_REPO}:latest"
WEB_IMAGE="${WEB_IMAGE_REPO}:${TAG}"
WEB_LATEST="${WEB_IMAGE_REPO}:latest"

# ---------- docker login ----------
if [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_PASSWORD:-}" ]]; then
  log "Docker Hub login as ${DOCKERHUB_USERNAME}"
  echo "$DOCKERHUB_PASSWORD" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin
else
  log "DOCKERHUB_* not set — using existing docker login on host (if any)"
fi

# ---------- build & push API ----------
if [[ "$DEPLOY_API" == "1" ]]; then
  if [[ ! -f "${API_DIR}/Dockerfile" ]]; then
    log "ERROR: API Dockerfile not found at ${API_DIR}/Dockerfile"
    exit 1
  fi
  log "Building ${API_IMAGE} from ${API_DIR}"
  docker build -t "$API_IMAGE" -t "$API_LATEST" "$API_DIR"
  log "Pushing ${API_IMAGE} and ${API_LATEST}"
  docker push "$API_IMAGE"
  docker push "$API_LATEST"
fi

# ---------- build & push WEB ----------
if [[ "$DEPLOY_WEB" == "1" ]]; then
  if [[ ! -f "${WEB_DIR}/Dockerfile" ]]; then
    log "ERROR: Web Dockerfile not found at ${WEB_DIR}/Dockerfile"
    exit 1
  fi
  log "Building ${WEB_IMAGE} from ${WEB_DIR}"
  docker build -t "$WEB_IMAGE" -t "$WEB_LATEST" "$WEB_DIR"
  log "Pushing ${WEB_IMAGE} and ${WEB_LATEST}"
  docker push "$WEB_IMAGE"
  docker push "$WEB_LATEST"
fi

# ---------- k3s kubeconfig ----------
export KUBECONFIG="$KUBECONFIG_PATH"
if [[ ! -f "$KUBECONFIG" ]]; then
  log "ERROR: kubeconfig not found: $KUBECONFIG"
  exit 1
fi
log "Using kubeconfig: $KUBECONFIG"
if ! kubectl get nodes --request-timeout=8s >/dev/null 2>&1; then
  log "ERROR: cannot reach cluster via $KUBECONFIG (expected local k3s, not EKS)"
  exit 1
fi

# ---------- import into k3s containerd ----------
if [[ "$IMPORT_TO_K3S" == "1" ]] && command -v k3s >/dev/null 2>&1; then
  IMAGES_TO_IMPORT=()
  [[ "$DEPLOY_API" == "1" ]] && IMAGES_TO_IMPORT+=("$API_IMAGE" "$API_LATEST")
  [[ "$DEPLOY_WEB" == "1" ]] && IMAGES_TO_IMPORT+=("$WEB_IMAGE" "$WEB_LATEST")
  if [[ ${#IMAGES_TO_IMPORT[@]} -gt 0 ]]; then
    log "Importing images into k3s containerd: ${IMAGES_TO_IMPORT[*]}"
    if docker save "${IMAGES_TO_IMPORT[@]}" | sudo -n k3s ctr images import - 2>/dev/null; then
      log "Images imported into k3s"
    elif docker save "${IMAGES_TO_IMPORT[@]}" | sudo k3s ctr images import -; then
      log "Images imported into k3s"
    else
      log "WARN: could not import into k3s (sudo/k3s ctr). Relying on Hub pull."
    fi
  fi
fi

# ---------- pull secret (private Hub) ----------
if [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_PASSWORD:-}" ]]; then
  log "Ensuring pull secret ${PULL_SECRET_NAME} in ns/${K8S_NAMESPACE}"
  kubectl get ns "$K8S_NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$K8S_NAMESPACE"
  kubectl -n "$K8S_NAMESPACE" create secret docker-registry "$PULL_SECRET_NAME" \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username="$DOCKERHUB_USERNAME" \
    --docker-password="$DOCKERHUB_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

# ---------- apply manifests ----------
log "Applying k8s manifests"
kubectl apply -f "${REPO_DIR}/k8s/namespace.yaml"
kubectl apply -f "${REPO_DIR}/k8s/api.yaml"
kubectl apply -f "${REPO_DIR}/k8s/web.yaml"

# ---------- roll images ----------
if [[ "$DEPLOY_API" == "1" ]]; then
  log "Rolling out API ${API_IMAGE}"
  kubectl -n "$K8S_NAMESPACE" set image "deployment/fast-api" "fast-api=${API_IMAGE}"
  kubectl -n "$K8S_NAMESPACE" rollout status "deployment/fast-api" --timeout=180s
fi

if [[ "$DEPLOY_WEB" == "1" ]]; then
  log "Rolling out Web ${WEB_IMAGE}"
  kubectl -n "$K8S_NAMESPACE" set image "deployment/fast-web" "fast-web=${WEB_IMAGE}"
  kubectl -n "$K8S_NAMESPACE" rollout status "deployment/fast-web" --timeout=180s
fi

MSG="Deployed api=${API_IMAGE} web=${WEB_IMAGE} to k3s ns/${K8S_NAMESPACE}"
log "$MSG"
cleanup_status true "$MSG"
echo "$MSG"
echo "URLs:"
echo "  Web UI:  http://192.168.1.11:30080"
echo "  API:     http://192.168.1.11:30081"
echo "  Health:  http://192.168.1.11:30081/health"
exit 0
