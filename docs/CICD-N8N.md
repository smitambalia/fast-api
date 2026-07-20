# CI/CD with n8n: GitHub → Docker Hub → K3s

## Why this architecture?

Your n8n runs **inside k3s** as a non-root pod **without Docker**.  
It cannot safely `docker build` / `docker push` by itself.

```
Git Push
   │
   ▼
GitHub Webhook  ──────────────────────────────►  n8n (in k3s)
                                                   │
                                                   │  SSH
                                                   ▼
                                            Host machine
                                         (docker + kubectl)
                                                   │
                          ┌────────────────────────┼────────────────────────┐
                          ▼                        ▼                        ▼
                   docker build              docker push              kubectl apply
                   (local Dockerfile)     (Docker Hub)               (k3s deploy)
                          │                        │                        │
                          └────────────────────────┴────────────────────────┘
                                                   │
                                                   ▼
                                          Slack / Teams notify
```

Workflow file: [`n8n-workflow-cicd-fastapi.json`](../n8n-workflow-cicd-fastapi.json)  
Host script: [`scripts/ci-deploy.sh`](../scripts/ci-deploy.sh)

---

## Security first (important)

You pasted a Docker Hub password in chat. Treat it as **compromised**:

1. Docker Hub → Account Settings → **Security** → create an **Access Token**
2. **Revoke / change** the old password if it was only for Docker Hub login
3. Prefer token over account password in CI
4. **Never** put the password in the n8n workflow JSON or git

Store secrets only in:

- host file `~/.config/fastapi-ci.env` (mode `600`), and/or  
- n8n **Credentials** UI (SSH)

---

## One-time host setup

### 1. Docker Hub login on the host

```bash
# Prefer Access Token as password
docker login -u smitambalia
# Image repo you specified:
#   smitambalia/n8n
```

Or create env file (not in git):

```bash
mkdir -p ~/.config
cp /home/yashree/development/fast-api/scripts/ci.env.example ~/.config/fastapi-ci.env
chmod 600 ~/.config/fastapi-ci.env
# edit: set DOCKERHUB_USERNAME + DOCKERHUB_PASSWORD (token)
nano ~/.config/fastapi-ci.env
```

### 2. SSH access for n8n → host

n8n pod must SSH to the host (same as FastAPI reachability):

| Field | Value |
|--------|--------|
| Host | `10.42.0.1` (k3s cni0) or `192.168.1.11` |
| User | `yashree` (user that can run docker + kubectl) |
| Auth | SSH key (recommended) or password |

```bash
# On host: ensure sshd is running
sudo systemctl enable --now ssh

# Optional: dedicated CI key
ssh-keygen -t ed25519 -f ~/.ssh/n8n_ci -N ""
cat ~/.ssh/n8n_ci.pub >> ~/.ssh/authorized_keys
# Import private key ~/.ssh/n8n_ci into n8n credential "SSH Private Key"
```

Test from n8n pod:

```bash
export KUBECONFIG=~/.kube/k3s.yaml
kubectl -n aaf-n8n exec deploy/n8n -- sh -c 'command -v ssh || true'
# Better: from any pod
kubectl run ssh-test --rm -it --restart=Never --image=alpine:3.19 -- \
  sh -c 'apk add --no-cache openssh-client >/dev/null && ssh -o StrictHostKeyChecking=no yashree@10.42.0.1 echo ok'
```

### 3. Script permissions

```bash
chmod +x /home/yashree/development/fast-api/scripts/ci-deploy.sh
```

### 4. Manual dry-run on host (before n8n)

```bash
export GIT_SHA=testmanual
# if using env file:
set -a && source ~/.config/fastapi-ci.env && set +a
/home/yashree/development/fast-api/scripts/ci-deploy.sh
```

This should:

1. Build `smitambalia/n8n:<sha>`
2. Push to Docker Hub
3. Apply `k8s/deployment.yaml`
4. Roll out deployment in namespace `fast-api`

Check:

```bash
export KUBECONFIG=~/.kube/k3s.yaml
kubectl -n fast-api get pods,svc
curl -s http://10.42.0.1:30081/health   # NodePort 30081
```

---

## n8n workflow setup

### 1. Import

n8n → **Workflows** → **Import from File** →  
`n8n-workflow-cicd-fastapi.json`

### 2. Attach SSH credential

Open node **SSH: Build Push Deploy**:

1. Credentials → **Create new** → SSH Password **or** SSH Private Key  
2. Host: `10.42.0.1`  
3. Port: `22`  
4. User: your host user  
5. Save and select it on the node  

### 3. Activate workflow

Toggle **Active**.

#### Public webhook (VS Code Dev Tunnel) — current setup

Port-forward n8n NodePort **30678** via VS Code / dev tunnels, then use:

| Mode | URL |
|------|-----|
| **Production (Active)** | `https://kk01hvzx-30678.inc1.devtunnels.ms/webhook/github-fastapi-ci` |
| **Test (Listen once)** | `https://kk01hvzx-30678.inc1.devtunnels.ms/webhook-test/github-fastapi-ci` |

**Important:** the tunnel must stay running or GitHub deliveries will fail (timeouts / 502).

#### Why n8n UI may show `http://127.0.0.1:30678/...`

The Webhook node **Test URL / Production URL** is built from the n8n env var **`WEBHOOK_URL`**, not from the workflow JSON notes.

Cluster setting (namespace `aaf-n8n`, ConfigMap `n8n-config`):

```bash
export KUBECONFIG=~/.kube/k3s.yaml
kubectl -n aaf-n8n get configmap n8n-config -o yaml | grep -E 'WEBHOOK|EDITOR|HOST|PROTOCOL'

# Point n8n at the public tunnel:
kubectl -n aaf-n8n patch configmap n8n-config --type merge -p '{
  "data": {
    "WEBHOOK_URL": "https://kk01hvzx-30678.inc1.devtunnels.ms/",
    "N8N_EDITOR_BASE_URL": "https://kk01hvzx-30678.inc1.devtunnels.ms/",
    "N8N_HOST": "kk01hvzx-30678.inc1.devtunnels.ms",
    "N8N_PROTOCOL": "https",
    "N8N_SECURE_COOKIE": "true",
    "N8N_PROXY_HOPS": "1"
  }
}'
kubectl -n aaf-n8n rollout restart deployment/n8n
```

Then hard-refresh the n8n UI. The webhook panel should show the tunnel host.  
If the tunnel subdomain changes later, update `WEBHOOK_URL` again.

#### Local fallback (LAN only — GitHub cannot reach this)

```text
http://192.168.1.11:30678/webhook/github-fastapi-ci
```

```bash
export KUBECONFIG=~/.kube/k3s.yaml
kubectl -n aaf-n8n get svc n8n
# NodePort 30678
```

### 4. GitHub webhook

In the **GitHub repository** that holds this project (`smitambalia/fast-api`):

1. **Settings → Webhooks → Add webhook**
2. **Payload URL**:
   ```text
   https://kk01hvzx-30678.inc1.devtunnels.ms/webhook/github-fastapi-ci
   ```
3. **Content type**: `application/json`
4. **Secret**: optional (add validation later in Code node)
5. **Events**: Just the **push** event  
6. Save  
7. Confirm workflow is **Active** and the **dev tunnel is up**

### 5. Slack / Teams (optional)

| Node | What to set |
|------|-------------|
| **Notify Slack** | Incoming Webhook URL, or n8n env `SLACK_WEBHOOK_URL` |
| **Notify Teams** | Incoming Webhook URL, or n8n env `TEAMS_WEBHOOK_URL` |

If you do not use one of them: **disable** that node so a bad URL does not fail the run.

To set env on n8n Deployment:

```bash
export KUBECONFIG=~/.kube/k3s.yaml
kubectl -n aaf-n8n edit configmap n8n-config
# add SLACK_WEBHOOK_URL / TEAMS_WEBHOOK_URL if your chart maps them to env
kubectl -n aaf-n8n rollout restart deploy/n8n
```

---

## End-to-end test

### A. Test webhook without GitHub

**Active workflow + public tunnel:**

```bash
curl -sS -X POST "https://kk01hvzx-30678.inc1.devtunnels.ms/webhook/github-fastapi-ci" \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: push" \
  -d '{
    "ref": "refs/heads/main",
    "after": "abcdef1234567890",
    "repository": { "full_name": "smitambalia/fast-api" },
    "pusher": { "name": "local-test" },
    "commits": [{ "id": "abcdef1234567890", "message": "test" }]
  }'
```

Or in n8n: **GitHub Webhook** → **Listen for test event**, then POST to  
`https://kk01hvzx-30678.inc1.devtunnels.ms/webhook-test/github-fastapi-ci`.

### B. Real push

```bash
git add .
git commit -m "ci: trigger pipeline"
git push origin main
```

Watch: n8n **Executions** → host `docker` / `kubectl` → Slack/Teams.

---

## Workflow map (nodes)

| Step | Node | Role |
|------|------|------|
| 1 | **GitHub Webhook** | Receives push payload |
| 2 | **Parse GitHub Payload** | branch, sha, repo, pusher |
| 3 | **Is main/master?** | Only deploy protected branches |
| 4 | **SSH: Build Push Deploy** | Runs `scripts/ci-deploy.sh` on host |
| 5 | **Format Result** | Success/failure summary |
| 6 | **Notify Slack** / **Notify Teams** | Chat alerts |
| 7 | **Respond OK** / **Respond Skipped** | HTTP response to GitHub |

Shell work inside the script:

1. `git pull` (on host clone)
2. `docker build` → `smitambalia/n8n:<sha>`
3. `docker push`
4. `kubectl apply` + `kubectl set image` + rollout status

---

## Image name

Configured as you specified: **`smitambalia/n8n`**.

If you prefer a dedicated app image later:

```bash
# in ~/.config/fastapi-ci.env
IMAGE_REPO=smitambalia/fast-api
```

And update `k8s/deployment.yaml` image field.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Webhook 404 | Workflow **Active**? path `github-fastapi-ci`? |
| SSH connection refused | `sshd` on host; host `10.42.0.1`; firewall |
| docker: permission denied | user in `docker` group; re-login |
| push denied Docker Hub | `docker login`; access token; repo exists & is writable |
| ImagePullBackOff in k3s | private repo needs `imagePullSecrets`; or make Hub repo public |
| n8n cannot resolve Slack URL | disable node or set real webhook URL |
| Wrong git revision | host `REPO_DIR` must be this project clone with remotes |

### Private Docker Hub + rollout timeout (`ErrImagePull` / 401)

Push can succeed (your laptop is logged in) while **k3s fails to pull** the same private image:

```text
ErrImagePull … 401 Unauthorized
```

**Fix A — pull secret (recommended for private repos)**

```bash
export KUBECONFIG=~/.kube/k3s.yaml

# Use a Docker Hub Access Token with Read (+ Write if you also push)
kubectl -n fast-api create secret docker-registry dockerhub-cred \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=smitambalia \
  --docker-password='YOUR_ACCESS_TOKEN' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n fast-api apply -f k8s/deployment.yaml
kubectl -n fast-api set image deployment/fast-api fast-api=smitambalia/n8n:ebb8452
kubectl -n fast-api rollout restart deployment/fast-api
kubectl -n fast-api rollout status deployment/fast-api
```

Or put `DOCKERHUB_USERNAME` / `DOCKERHUB_PASSWORD` in `~/.config/fastapi-ci.env` and re-run `scripts/ci-deploy.sh` (it creates `dockerhub-cred` automatically).

**Fix B — import local image into k3s** (same machine that built the image):

```bash
docker save smitambalia/n8n:ebb8452 smitambalia/n8n:latest | sudo k3s ctr images import -
export KUBECONFIG=~/.kube/k3s.yaml
kubectl -n fast-api rollout restart deployment/fast-api
```

Manifest uses `imagePullPolicy: IfNotPresent`, so a node-local image can start without Hub.

**Fix C — make the Hub repo public** (simplest): Docker Hub → `smitambalia/n8n` → Settings → Public.

---

## What we deliberately did **not** do

- Did **not** store your Docker Hub password in the repo or workflow JSON  
- Did **not** mount Docker socket into the n8n pod (high risk)  
- Did **not** run privileged builds inside the n8n container  

This keeps CI practical on your current k3s + host Docker setup.
