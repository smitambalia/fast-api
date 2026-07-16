#!/usr/bin/env bash
# Host-side CI: pull → docker build → push Docker Hub → deploy to k3s
# Called by n8n over SSH. Do NOT put secrets in this file.
set -euo pipefail

# ---------- config (override via env) ----------
REPO_DIR="${REPO_DIR:-/home/yashree/development/fast-api}"
IMAGE_REPO="${IMAGE_REPO:-smitambalia/n8n}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/home/yashree/.kube/k3s.yaml}"
K8S_NAMESPACE="${K8S_NAMESPACE:-fast-api}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-fast-api}"
CONTAINER_NAME="${CONTAINER_NAME:-fast-api}"
BRANCH="${BRANCH:-main}"
GIT_SHA="${GIT_SHA:-}"
NOTIFY_STATUS_FILE="${NOTIFY_STATUS_FILE:-/tmp/fastapi-ci-last.json}"

log() { echo "[ci-deploy $(date -Is)] $*"; }

cleanup_status() {
  local ok="$1"
  local msg="$2"
  cat >"$NOTIFY_STATUS_FILE" <<EOF
{"ok": ${ok}, "message": $(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), "image": "${IMAGE_REPO}:${TAG:-unknown}", "time": "$(date -Is)"}
EOF
}

trap 'cleanup_status false "failed at line $LINENO"' ERR

# ---------- resolve tag ----------
if [[ -z "$GIT_SHA" ]]; then
  GIT_SHA="$(cd "$REPO_DIR" && git rev-parse --short HEAD 2>/dev/null || echo manual)"
fi
TAG="${GIT_SHA}"
FULL_IMAGE="${IMAGE_REPO}:${TAG}"
LATEST_IMAGE="${IMAGE_REPO}:latest"

log "Starting CI deploy"
log "REPO_DIR=$REPO_DIR IMAGE=$FULL_IMAGE branch=$BRANCH"

# ---------- git pull ----------
cd "$REPO_DIR"
if [[ -d .git ]]; then
  log "Fetching latest git..."
  git fetch --all --prune
  # Prefer the branch from the webhook if it exists
  if git show-ref --verify --quiet "refs/remotes/origin/${BRANCH}"; then
    git checkout "$BRANCH"
    git pull --ff-only origin "$BRANCH"
  else
    log "Branch origin/${BRANCH} not found; using current HEAD"
  fi
  GIT_SHA="$(git rev-parse --short HEAD)"
  TAG="$GIT_SHA"
  FULL_IMAGE="${IMAGE_REPO}:${TAG}"
fi

# ---------- docker login (optional env; prefer pre-login on host) ----------
if [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_PASSWORD:-}" ]]; then
  log "Docker Hub login as ${DOCKERHUB_USERNAME}"
  echo "$DOCKERHUB_PASSWORD" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin
else
  log "DOCKERHUB_* not set — using existing docker login on host (if any)"
fi

# ---------- build & push ----------
log "Building ${FULL_IMAGE}"
docker build -t "$FULL_IMAGE" -t "$LATEST_IMAGE" "$REPO_DIR"

log "Pushing ${FULL_IMAGE} and ${LATEST_IMAGE}"
docker push "$FULL_IMAGE"
docker push "$LATEST_IMAGE"

# ---------- deploy k3s ----------
export KUBECONFIG="$KUBECONFIG_PATH"
log "Applying k8s manifests"
kubectl apply -f "${REPO_DIR}/k8s/deployment.yaml"

log "Rolling out image ${FULL_IMAGE}"
kubectl -n "$K8S_NAMESPACE" set image "deployment/${DEPLOYMENT_NAME}" \
  "${CONTAINER_NAME}=${FULL_IMAGE}"

kubectl -n "$K8S_NAMESPACE" rollout status "deployment/${DEPLOYMENT_NAME}" --timeout=180s

# ---------- success ----------
MSG="Deployed ${FULL_IMAGE} to k3s ns/${K8S_NAMESPACE}"
log "$MSG"
cleanup_status true "$MSG"
echo "$MSG"
exit 0
