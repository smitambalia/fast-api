# Deploy any GitHub URL + branch → Docker Hub → k3s

## Flow

```text
Execute workflow (manual)
        │
        ▼
  GitHub URL + Branch   ← edit fields in this Set node
        │
        ▼
  Normalize inputs
        │  SSH
        ▼
  deploy-from-github.sh  on host
        │
        ├─ git clone / checkout branch
        ├─ docker build apps/api + apps/web
        ├─ docker push  smitambalia/n8n:<branch>-<sha>
        │               smitambalia/fast-web:<branch>-<sha>
        ├─ (optional) import into k3s containerd
        └─ kubectl set image + rollout
        │
        ▼
  Format Result
```

No webhook required. You type URL + branch in n8n, then click **Execute workflow**.

## Files

| File | Role |
|------|------|
| `scripts/deploy-from-github.sh` | Host pipeline |
| `n8n-workflow-deploy-from-github.json` | Importable n8n workflow |

## n8n setup

1. Import **`n8n-workflow-deploy-from-github.json`** (or re-import to replace the old webhook version)
2. On **SSH: Clone Build Push Deploy** → select your SSH credential  
   (`10.42.0.1`, user `yashree`)
3. Open node **GitHub URL + Branch** and set:
   - `github_url` → e.g. `https://github.com/smitambalia/fast-api`
   - `branch` → e.g. `main`
   - `deploy_api` / `deploy_web` → `true` / `false` as needed
4. Click **Execute workflow** (no need to keep workflow Active)

## Example values (in the Set node)

| Field | Example |
|-------|---------|
| `github_url` | `https://github.com/smitambalia/fast-api` |
| `branch` | `main` or `feature/my-branch` |
| `deploy_api` | `true` |
| `deploy_web` | `true` |

After a successful run, open **Format Result** / **Executions** for summary and image tags.

## Manual host test (no n8n)

```bash
# optional secrets
# source ~/.config/fastapi-ci.env

export GITHUB_URL="https://github.com/smitambalia/fast-api.git"
export BRANCH="main"
./scripts/deploy-from-github.sh
```

## Image tags

| Image | Tag pattern | Example |
|-------|-------------|---------|
| API | `<branch>-<shortsha>` | `smitambalia/n8n:main-9ea2dfb` |
| Web | `<branch>-<shortsha>` | `smitambalia/fast-web:main-9ea2dfb` |

Also pushes `:latest` when `UPDATE_LATEST=1` (default).

## Requirements on the host

- `git`, `docker`, `kubectl`, k3s kubeconfig `~/.kube/k3s.yaml`
- Docker Hub login (or `DOCKERHUB_USERNAME` / `DOCKERHUB_PASSWORD` in `~/.config/fastapi-ci.env`)
- Hub repos: **`smitambalia/n8n`**, **`smitambalia/fast-web`** (public or pull secret)
- Script path: `/home/yashree/development/fast-api/scripts/deploy-from-github.sh`  
  (or set `DEPLOY_SCRIPT` in env)

## Repo layout expected

The target GitHub repo must be this monorepo shape:

```text
apps/api/Dockerfile
apps/web/Dockerfile
k8s/api.yaml
k8s/web.yaml
```

## Cluster URLs after deploy

| App | URL |
|-----|-----|
| Web | http://192.168.1.11:30080 |
| API | http://192.168.1.11:30081 |
