#!/usr/bin/env bash
# Clone a GitHub repo/branch → docker build (api+web) → push Docker Hub → deploy k3s.
# Intended for n8n (SSH). Pass:
#   GITHUB_URL  e.g. https://github.com/smitambalia/fast-api.git
#   BRANCH      e.g. main
# Optional: API_IMAGE_REPO, WEB_IMAGE_REPO, WORK_ROOT, KUBECONFIG_PATH, DOCKERHUB_*
set -euo pipefail

GITHUB_URL="${GITHUB_URL:-}"
BRANCH="${BRANCH:-main}"
WORK_ROOT="${WORK_ROOT:-$HOME/.cache/n8n-ci-builds}"
API_IMAGE_REPO="${API_IMAGE_REPO:-smitambalia/n8n}"
WEB_IMAGE_REPO="${WEB_IMAGE_REPO:-smitambalia/fast-web}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/k3s.yaml}"
K8S_NAMESPACE="${K8S_NAMESPACE:-fast-api}"
IMPORT_TO_K3S="${IMPORT_TO_K3S:-1}"
DEPLOY_API="${DEPLOY_API:-1}"
DEPLOY_WEB="${DEPLOY_WEB:-1}"
PULL_SECRET_NAME="${PULL_SECRET_NAME:-dockerhub-cred}"
NOTIFY_STATUS_FILE="${NOTIFY_STATUS_FILE:-/tmp/n8n-github-deploy-last.json}"
# When 1, also retag :latest after branch tag
UPDATE_LATEST="${UPDATE_LATEST:-1}"

log() { echo "[deploy-github $(date -Is)] $*"; }

die() { log "ERROR: $*"; exit 1; }

write_status() {
  local ok="$1"
  local msg="$2"
  cat >"$NOTIFY_STATUS_FILE" <<EOF
{"ok": ${ok}, "message": $(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), "github_url": $(printf '%s' "${GITHUB_URL}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), "branch": $(printf '%s' "${BRANCH}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'), "api_image": "${API_IMAGE_REPO}:${TAG:-unknown}", "web_image": "${WEB_IMAGE_REPO}:${TAG:-unknown}", "time": "$(date -Is)"}
EOF
}

trap 'write_status false "failed at line $LINENO"' ERR

[[ -n "$GITHUB_URL" ]] || die "GITHUB_URL is required (e.g. https://github.com/org/repo.git)"
[[ -n "$BRANCH" ]] || die "BRANCH is required"

# Normalize URL (allow with or without .git)
if [[ "$GITHUB_URL" != *.git ]]; then
  GITHUB_URL="${GITHUB_URL%.git}.git"
fi
# strip trailing slash before .git mishaps
GITHUB_URL="${GITHUB_URL%/}"
[[ "$GITHUB_URL" == *.git ]] || GITHUB_URL="${GITHUB_URL}.git"

# Docker-safe tag pieces from branch
BRANCH_SAFE="$(printf '%s' "$BRANCH" | sed -E 's#^refs/heads/##' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g' | sed -E 's/^-+|-+$//g')"
[[ -n "$BRANCH_SAFE" ]] || BRANCH_SAFE="branch"

# Workspace folder name from repo
REPO_SLUG="$(printf '%s' "$GITHUB_URL" | sed -E 's#\.git$##' | sed -E 's#.*/##' )"
CLONE_DIR="${WORK_ROOT}/${REPO_SLUG}"

log "GITHUB_URL=$GITHUB_URL BRANCH=$BRANCH"
log "CLONE_DIR=$CLONE_DIR"

mkdir -p "$WORK_ROOT"

# ---------- clone / update ----------
if [[ -d "${CLONE_DIR}/.git" ]]; then
  log "Updating existing clone..."
  cd "$CLONE_DIR"
  git remote set-url origin "$GITHUB_URL" || true
  git fetch --all --prune --depth=50
  git checkout -B "$BRANCH" "origin/${BRANCH}" 2>/dev/null \
    || git checkout "$BRANCH" \
    || die "Cannot checkout branch '$BRANCH'"
  git reset --hard "origin/${BRANCH}" 2>/dev/null \
    || git pull --ff-only origin "$BRANCH" \
    || die "Cannot update branch '$BRANCH'"
else
  log "Cloning (depth=50) branch=$BRANCH ..."
  rm -rf "$CLONE_DIR"
  git clone --depth=50 --branch "$BRANCH" "$GITHUB_URL" "$CLONE_DIR" \
    || die "git clone failed (check URL, branch, and network)"
  cd "$CLONE_DIR"
fi

GIT_SHA="$(git rev-parse --short HEAD)"
# tag: branch-sha (docker-safe, max ~128 chars)
TAG="${BRANCH_SAFE}-${GIT_SHA}"
TAG="$(printf '%s' "$TAG" | cut -c1-120)"

API_DIR="${CLONE_DIR}/apps/api"
WEB_DIR="${CLONE_DIR}/apps/web"
[[ -f "${API_DIR}/Dockerfile" ]] || die "Monorepo API missing: ${API_DIR}/Dockerfile"
[[ -f "${WEB_DIR}/Dockerfile" ]] || die "Monorepo Web missing: ${WEB_DIR}/Dockerfile"
[[ -f "${CLONE_DIR}/k8s/api.yaml" ]] || log "WARN: no k8s/api.yaml in repo — will only set images on existing cluster resources"

API_IMAGE="${API_IMAGE_REPO}:${TAG}"
WEB_IMAGE="${WEB_IMAGE_REPO}:${TAG}"
API_LATEST="${API_IMAGE_REPO}:latest"
WEB_LATEST="${WEB_IMAGE_REPO}:latest"

log "Resolved GIT_SHA=$GIT_SHA TAG=$TAG"
log "API_IMAGE=$API_IMAGE WEB_IMAGE=$WEB_IMAGE"

# ---------- docker login ----------
if [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_PASSWORD:-}" ]]; then
  log "Docker Hub login as ${DOCKERHUB_USERNAME}"
  echo "$DOCKERHUB_PASSWORD" | docker login -u "$DOCKERHUB_USERNAME" --password-stdin
else
  log "DOCKERHUB_* not set — using existing docker login on host (if any)"
fi

# ---------- build & push ----------
if [[ "$DEPLOY_API" == "1" ]]; then
  log "Building API ${API_IMAGE}"
  docker build -t "$API_IMAGE" "$API_DIR"
  if [[ "$UPDATE_LATEST" == "1" ]]; then
    docker tag "$API_IMAGE" "$API_LATEST"
  fi
  log "Pushing ${API_IMAGE}"
  if ! docker push "$API_IMAGE"; then
    log "WARN: docker push API failed (rate limit/auth). Will still try local k3s import."
  fi
  if [[ "$UPDATE_LATEST" == "1" ]]; then
    docker push "$API_LATEST" || log "WARN: push api:latest failed"
  fi
fi

WEB_BUILT=0
if [[ "$DEPLOY_WEB" == "1" ]]; then
  log "Building Web ${WEB_IMAGE}"
  if docker build -t "$WEB_IMAGE" "$WEB_DIR"; then
    WEB_BUILT=1
    if [[ "$UPDATE_LATEST" == "1" ]]; then
      docker tag "$WEB_IMAGE" "$WEB_LATEST"
    fi
    log "Pushing ${WEB_IMAGE}"
    if ! docker push "$WEB_IMAGE"; then
      log "WARN: docker push web failed (rate limit/auth). Will still try local k3s import."
    fi
    if [[ "$UPDATE_LATEST" == "1" ]]; then
      docker push "$WEB_LATEST" || log "WARN: push web:latest failed"
    fi
  else
    log "ERROR: Web docker build failed — continuing with API-only deploy if API succeeded"
    DEPLOY_WEB=0
  fi
fi

# ---------- k3s ----------
export KUBECONFIG="$KUBECONFIG_PATH"
[[ -f "$KUBECONFIG" ]] || die "kubeconfig not found: $KUBECONFIG"
kubectl get nodes --request-timeout=8s >/dev/null 2>&1 \
  || die "cannot reach cluster via $KUBECONFIG (use local k3s kubeconfig, not EKS)"

if [[ "$IMPORT_TO_K3S" == "1" ]] && command -v k3s >/dev/null 2>&1; then
  TO_IMPORT=()
  [[ "$DEPLOY_API" == "1" ]] && TO_IMPORT+=("$API_IMAGE")
  [[ "$DEPLOY_API" == "1" && "$UPDATE_LATEST" == "1" ]] && TO_IMPORT+=("$API_LATEST")
  [[ "$DEPLOY_WEB" == "1" ]] && TO_IMPORT+=("$WEB_IMAGE")
  [[ "$DEPLOY_WEB" == "1" && "$UPDATE_LATEST" == "1" ]] && TO_IMPORT+=("$WEB_LATEST")
  if [[ ${#TO_IMPORT[@]} -gt 0 ]]; then
    log "Importing images into k3s containerd"
    if ! docker save "${TO_IMPORT[@]}" | sudo -n k3s ctr images import - 2>/dev/null; then
      if ! docker save "${TO_IMPORT[@]}" | sudo k3s ctr images import -; then
        log "WARN: k3s import failed — cluster will pull from Docker Hub"
      fi
    fi
  fi
fi

if [[ -n "${DOCKERHUB_USERNAME:-}" && -n "${DOCKERHUB_PASSWORD:-}" ]]; then
  kubectl get ns "$K8S_NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$K8S_NAMESPACE"
  kubectl -n "$K8S_NAMESPACE" create secret docker-registry "$PULL_SECRET_NAME" \
    --docker-server=https://index.docker.io/v1/ \
    --docker-username="$DOCKERHUB_USERNAME" \
    --docker-password="$DOCKERHUB_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

log "Applying k8s manifests from clone (if present)"
if [[ -f "${CLONE_DIR}/k8s/namespace.yaml" ]]; then
  kubectl apply -f "${CLONE_DIR}/k8s/namespace.yaml"
fi
if [[ -f "${CLONE_DIR}/k8s/api.yaml" ]]; then
  kubectl apply -f "${CLONE_DIR}/k8s/api.yaml"
fi
if [[ -f "${CLONE_DIR}/k8s/web.yaml" ]]; then
  kubectl apply -f "${CLONE_DIR}/k8s/web.yaml"
fi

# Force pull of new tags from Hub when not imported
if [[ "$DEPLOY_API" == "1" ]]; then
  log "Deploy API → ${API_IMAGE}"
  kubectl -n "$K8S_NAMESPACE" set image "deployment/fast-api" "fast-api=${API_IMAGE}"
  kubectl -n "$K8S_NAMESPACE" patch deployment fast-api --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]' 2>/dev/null || true
  kubectl -n "$K8S_NAMESPACE" rollout status "deployment/fast-api" --timeout=180s
fi

if [[ "$DEPLOY_WEB" == "1" ]]; then
  log "Deploy Web → ${WEB_IMAGE}"
  kubectl -n "$K8S_NAMESPACE" set image "deployment/fast-web" "fast-web=${WEB_IMAGE}"
  kubectl -n "$K8S_NAMESPACE" patch deployment fast-web --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Always"}]' 2>/dev/null || true
  kubectl -n "$K8S_NAMESPACE" rollout status "deployment/fast-web" --timeout=240s
fi

MSG="Deployed ${GITHUB_URL}@${BRANCH} (${GIT_SHA}) api=${API_IMAGE} web=${WEB_IMAGE}"
log "$MSG"
write_status true "$MSG"
echo "$MSG"
echo "URLs: web=http://192.168.1.11:30080 api=http://192.168.1.11:30081"
exit 0
