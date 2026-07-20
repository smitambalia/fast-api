# FastAPI + Next.js monorepo (Docker + k3s)

```text
fast-api/
├── apps/
│   ├── api/          # FastAPI  → image smitambalia/n8n
│   └── web/          # Next.js  → image smitambalia/fast-web
├── k8s/              # namespace, api, web manifests
├── scripts/          # ci-deploy.sh (both apps)
└── package.json
```

## Cluster URLs (NodePort)

| Service | URL |
|---------|-----|
| **Web UI** | http://192.168.1.11:30080 |
| **API** | http://192.168.1.11:30081 |
| Health | http://192.168.1.11:30081/health |
| Swagger | http://192.168.1.11:30081/docs |

The web app calls FastAPI via same-origin **`/backend/*`** (Next.js proxy → `http://fast-api:8001` in-cluster).

## Local development

```bash
# API
cd apps/api && uvicorn main:app --host 0.0.0.0 --port 8001 --reload

# Web (proxies /backend → API_INTERNAL_URL in .env.local)
cd ../..
npm run install:web
npm run dev:web
# http://localhost:3000
```

## Docker build (local)

```bash
docker build -t smitambalia/n8n:local apps/api
docker build -t smitambalia/fast-web:local apps/web
```

### Load into k3s (same machine)

```bash
./scripts/load-images-k3s.sh local
export KUBECONFIG=~/.kube/k3s.yaml
kubectl apply -f k8s/namespace.yaml -f k8s/api.yaml -f k8s/web.yaml
kubectl -n fast-api set image deploy/fast-api fast-api=smitambalia/n8n:local
kubectl -n fast-api set image deploy/fast-web fast-web=smitambalia/fast-web:local
kubectl -n fast-api get pods,svc
```

### Or push to Docker Hub then deploy

```bash
docker tag smitambalia/n8n:local smitambalia/n8n:latest
docker tag smitambalia/fast-web:local smitambalia/fast-web:latest
docker push smitambalia/n8n:latest
docker push smitambalia/fast-web:latest   # create Hub repo "fast-web" first if needed

export KUBECONFIG=~/.kube/k3s.yaml
kubectl apply -k k8s/
kubectl -n fast-api rollout restart deploy/fast-api deploy/fast-web
```

## CI/CD (n8n)

### A) Deploy by GitHub URL + branch (recommended)

Import **`n8n-workflow-deploy-from-github.json`**.

1. Open node **GitHub URL + Branch** → set `github_url` and `branch`
2. Click **Execute workflow**

Host script: `scripts/deploy-from-github.sh`  
Docs: [docs/DEPLOY-FROM-GITHUB.md](docs/DEPLOY-FROM-GITHUB.md)

### B) Deploy fixed local clone (push webhook)

`scripts/ci-deploy.sh` builds both images from the host checkout, pushes, applies k8s, waits for rollouts.  
See [docs/CICD-N8N.md](docs/CICD-N8N.md).

| Variable | Default |
|----------|---------|
| `API_IMAGE_REPO` | `smitambalia/n8n` |
| `WEB_IMAGE_REPO` | `smitambalia/fast-web` |
| `DEPLOY_API` / `DEPLOY_WEB` | `1` |

## Architecture

```text
Browser → :30080 fast-web (Next.js)
              │
              │  /backend/*  (server-side proxy)
              ▼
         fast-api:8001 (in-cluster)  → also NodePort :30081
```
