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
Production webhook path:

```text
http://<n8n-url>/webhook/github-fastapi-ci
```

Find your n8n URL (NodePort example):

```bash
export KUBECONFIG=~/.kube/k3s.yaml
kubectl -n aaf-n8n get svc n8n
# NodePort 30678 → http://192.168.1.11:30678
```

If you use Ingress/TLS, use that public HTTPS URL (GitHub prefers HTTPS for webhooks).

### 4. GitHub webhook

In the **GitHub repository** that holds this project:

1. **Settings → Webhooks → Add webhook**
2. **Payload URL**: `https://<n8n-host>/webhook/github-fastapi-ci`
3. **Content type**: `application/json`
4. **Secret**: optional (add validation later in Code node)
5. **Events**: Just the **push** event  
6. Save

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

In n8n, open **GitHub Webhook** → **Listen for test event**, then:

```bash
curl -sS -X POST "http://192.168.1.11:30678/webhook-test/github-fastapi-ci" \
  -H "Content-Type: application/json" \
  -d '{
    "ref": "refs/heads/main",
    "after": "abcdef1234567890",
    "repository": { "full_name": "you/fast-api" },
    "pusher": { "name": "local-test" },
    "commits": [{ "id": "abcdef1234567890", "message": "test" }]
  }'
```

(Use `/webhook/` instead of `/webhook-test/` when the workflow is **Active**.)

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

Private Docker Hub repo pull secret example:

```bash
export KUBECONFIG=~/.kube/k3s.yaml
kubectl -n fast-api create secret docker-registry dockerhub \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username=smitambalia \
  --docker-password='USE_ACCESS_TOKEN_NOT_CHAT_PASSWORD'
# then patch deployment pod spec: imagePullSecrets: [{name: dockerhub}]
```

---

## What we deliberately did **not** do

- Did **not** store your Docker Hub password in the repo or workflow JSON  
- Did **not** mount Docker socket into the n8n pod (high risk)  
- Did **not** run privileged builds inside the n8n container  

This keeps CI practical on your current k3s + host Docker setup.
