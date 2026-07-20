# apps/api — FastAPI

Python FastAPI service with `/health` and `/api/response`.

## Run locally

```bash
cd apps/api
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --host 0.0.0.0 --port 8001 --reload
```

## Docker / k3s

```bash
# from monorepo root
docker build -t smitambalia/n8n:local apps/api
```

CI builds from this directory via `scripts/ci-deploy.sh` (`API_DIR=apps/api`).

Default k3s base URL: `http://192.168.1.11:30081`
