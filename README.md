# Simple FastAPI Demo

Minimal FastAPI app with a health check and a sample GET response, plus n8n workflows for API tests and CI/CD.

## CI/CD (GitHub → Docker Hub → K3s via n8n)

See **[docs/CICD-N8N.md](docs/CICD-N8N.md)** for the full pipeline:

Git push → GitHub webhook → n8n → SSH to host → `docker build/push` → `kubectl` deploy → Slack/Teams.

- Workflow: `n8n-workflow-cicd-fastapi.json`
- Host script: `scripts/ci-deploy.sh`
- Manifests: `k8s/deployment.yaml`
- Image (Docker Hub): `smitambalia/n8n`

## Endpoints

| Method | Path            | Description                          |
|--------|-----------------|--------------------------------------|
| GET    | `/`             | Root — lists available routes        |
| GET    | `/health`       | Health check                         |
| GET    | `/api/response` | Sample FastAPI JSON response         |
| GET    | `/docs`         | Interactive Swagger UI               |

## Run locally

```bash
# From this directory
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# Bind 0.0.0.0 so n8n in Docker/k3s can reach the host
# Port 8001 — 8000 is often used by other local services
uvicorn main:app --host 0.0.0.0 --port 8001 --reload
```

Quick smoke test:

```bash
curl http://127.0.0.1:8001/health
curl http://127.0.0.1:8001/api/response
```

## n8n workflow

Import `n8n-workflow-test-fastapi.json` in n8n:

1. Open n8n → **Workflows** → **Import from File** (or menu → Import)
2. Select `n8n-workflow-test-fastapi.json`
3. Update the base URL on both HTTP Request nodes if needed (see below)
4. Click **Test workflow**

### Reaching FastAPI from n8n in Docker / k3s

### Reaching FastAPI from n8n in k3s (this machine)

`host.docker.internal` **does not work** in k3s pods. Use one of these instead:

| From n8n (k3s pod) | URL | Notes |
|--------------------|-----|--------|
| **Recommended**    | `http://10.42.0.1:8001` | k3s host on CNI bridge (`cni0`) |
| LAN IP             | `http://192.168.1.11:8001` | Wi‑Fi IP (can change with DHCP) |
| Localhost          | `http://127.0.0.1:8001` | **Only** if n8n runs on the host, not in a pod |

Verified from pod `n8n-56f684f68c-v4xx5` in namespace `aaf-n8n`: both `10.42.0.1` and `192.168.1.11` return `/health` OK.

Keep FastAPI on `--host 0.0.0.0 --port 8001` so pods can reach it.
